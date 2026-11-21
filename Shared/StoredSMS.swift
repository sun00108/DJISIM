///* Copyright Yahagi Networks and Contributors */

import Foundation
import OSLog
import Security
import SwiftData

enum SMSDirection: String, Codable {
    case incoming
    case outgoing
}

enum SMSDeliveryState: String, Codable {
    case received
    case sending
    case sent
    case failed
}

enum SMSAcknowledgementState: String, Codable {
    case notRequired
    case pending
    case acknowledged
    case authenticationFailed
}

@Model
final class StoredSMS {
    @Attribute(.unique) var smsID: String
    var timestamp: Date
    /// Original APNs title (the sender number), or the recipient entered by the user.
    var title: String
    var body: String
    var conversationKey: String
    var directionRawValue: String
    var deliveryStateRawValue: String
    var failureDescription: String?
    var deliveryMayBeUncertain: Bool
    var sendAttempts: Int
    // Existing records predate ACK retention, so their migration default is notRequired.
    var acknowledgementStateRawValue: String = SMSAcknowledgementState.notRequired.rawValue
    var acknowledgementAttempts: Int = 0
    var nextAcknowledgementAttemptAt: Date?
    var lastAcknowledgementError: String?

    init(
        smsID: String,
        timestamp: Date,
        title: String,
        body: String,
        direction: SMSDirection,
        deliveryState: SMSDeliveryState,
        failureDescription: String? = nil,
        deliveryMayBeUncertain: Bool = false,
        sendAttempts: Int = 0
    ) {
        self.smsID = smsID
        self.timestamp = timestamp
        self.title = title
        self.body = body
        conversationKey = Self.normalizedConversationKey(title)
        directionRawValue = direction.rawValue
        deliveryStateRawValue = deliveryState.rawValue
        self.failureDescription = failureDescription
        self.deliveryMayBeUncertain = deliveryMayBeUncertain
        self.sendAttempts = sendAttempts
        acknowledgementStateRawValue = SMSAcknowledgementState.notRequired.rawValue
        acknowledgementAttempts = 0
    }

    var direction: SMSDirection {
        get { SMSDirection(rawValue: directionRawValue) ?? .incoming }
        set { directionRawValue = newValue.rawValue }
    }

    var deliveryState: SMSDeliveryState {
        get { SMSDeliveryState(rawValue: deliveryStateRawValue) ?? .received }
        set { deliveryStateRawValue = newValue.rawValue }
    }

    var acknowledgementState: SMSAcknowledgementState {
        get { SMSAcknowledgementState(rawValue: acknowledgementStateRawValue) ?? .notRequired }
        set { acknowledgementStateRawValue = newValue.rawValue }
    }

    static func normalizedConversationKey(_ value: String) -> String {
        let digits = value.unicodeScalars.filter(CharacterSet.decimalDigits.contains)
        let normalized = String(String.UnicodeScalarView(digits))
        return normalized.isEmpty
            ? value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : normalized
    }
}

@MainActor
final class SMSPersistence {
    static let appGroupID = "group.ca.tgs4.utility.DJISIM"
    static let shared = SMSPersistence()

    let container: ModelContainer

    private init() {
        do {
            let schema = Schema([StoredSMS.self])
            let configuration = ModelConfiguration(
                "DJISIMMessages",
                schema: schema,
                groupContainer: .identifier(Self.appGroupID),
                cloudKitDatabase: .none
            )
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Unable to create shared SMS SwiftData container: \(error)")
        }
    }

    @discardableResult
    func storeIncoming(
        smsID: String,
        timestamp: Date,
        title: String,
        body: String,
        requiresAcknowledgement: Bool = false
    ) throws -> Bool {
        let context = container.mainContext
        let id = smsID
        var descriptor = FetchDescriptor<StoredSMS>(predicate: #Predicate { $0.smsID == id })
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.timestamp = timestamp
            existing.title = title
            existing.body = body
            existing.conversationKey = StoredSMS.normalizedConversationKey(title)
            existing.direction = .incoming
            existing.deliveryState = .received
            if requiresAcknowledgement {
                existing.acknowledgementState = .pending
                existing.nextAcknowledgementAttemptAt = nil
                existing.lastAcknowledgementError = nil
            }
            try context.save()
            return false
        }

        let message = StoredSMS(
            smsID: smsID,
            timestamp: timestamp,
            title: title,
            body: body,
            direction: .incoming,
            deliveryState: .received
        )
        if requiresAcknowledgement { message.acknowledgementState = .pending }
        context.insert(message)
        try context.save()
        return true
    }

    func pendingAcknowledgementIDs(now: Date = .now) throws -> [String] {
        let context = container.mainContext
        let pending = SMSAcknowledgementState.pending.rawValue
        let descriptor = FetchDescriptor<StoredSMS>(
            predicate: #Predicate { $0.acknowledgementStateRawValue == pending },
            sortBy: [SortDescriptor(\StoredSMS.timestamp)]
        )
        return try context.fetch(descriptor)
            .filter { $0.nextAcknowledgementAttemptAt.map { $0 <= now } ?? true }
            .map(\.smsID)
    }

    func resetAuthenticationFailedAcknowledgements() throws {
        let context = container.mainContext
        let failed = SMSAcknowledgementState.authenticationFailed.rawValue
        let descriptor = FetchDescriptor<StoredSMS>(
            predicate: #Predicate { $0.acknowledgementStateRawValue == failed }
        )
        for message in try context.fetch(descriptor) {
            message.acknowledgementState = .pending
            message.nextAcknowledgementAttemptAt = nil
            message.lastAcknowledgementError = nil
        }
        try context.save()
    }

    func recordAcknowledgementSuccess(smsID: String) throws {
        guard let message = try message(smsID: smsID) else { return }
        message.acknowledgementState = .acknowledged
        message.nextAcknowledgementAttemptAt = nil
        message.lastAcknowledgementError = nil
        try container.mainContext.save()
    }

    func recordAcknowledgementFailure(
        smsID: String,
        authenticationFailed: Bool,
        retryAfter: TimeInterval?,
        description: String
    ) throws {
        guard let message = try message(smsID: smsID) else { return }
        message.acknowledgementAttempts += 1
        message.acknowledgementState = authenticationFailed ? .authenticationFailed : .pending
        message.lastAcknowledgementError = description
        if authenticationFailed {
            message.nextAcknowledgementAttemptAt = nil
        } else {
            let exponent = min(message.acknowledgementAttempts - 1, 10)
            let backoff = min(5 * pow(2, Double(exponent)), 3_600)
            message.nextAcknowledgementAttemptAt = .now.addingTimeInterval(retryAfter ?? backoff)
        }
        try container.mainContext.save()
    }

    private func message(smsID: String) throws -> StoredSMS? {
        let id = smsID
        var descriptor = FetchDescriptor<StoredSMS>(predicate: #Predicate { $0.smsID == id })
        descriptor.fetchLimit = 1
        return try container.mainContext.fetch(descriptor).first
    }

    func makeOutgoing(title: String, body: String, in context: ModelContext) throws -> StoredSMS {
        let message = StoredSMS(
            smsID: "outgoing-\(UUID().uuidString.lowercased())",
            timestamp: .now,
            title: title,
            body: body,
            direction: .outgoing,
            deliveryState: .sending,
            sendAttempts: 1
        )
        context.insert(message)
        try context.save()
        return message
    }
}

enum SharedGatewayConfiguration {
    static let appGroupID = "group.ca.tgs4.utility.DJISIM"
    private static let serverKey = "DJISIM.serverAddress"
    private static let tokenAccount = "gateway-bearer-token"
    private static let keychainService = "ca.tgs4.utility.DJISIM.gateway"
    private static let keychainAccessGroup = "2UL623W9M5.ca.tgs4.utility.DJISIM.shared"

    static var serverAddress: String {
        UserDefaults(suiteName: appGroupID)?.string(forKey: serverKey) ?? ""
    }

    static var token: String {
        readToken(service: keychainService, accessGroup: keychainAccessGroup) ?? ""
    }

    static func save(serverAddress: String, token: String) throws {
        UserDefaults(suiteName: appGroupID)?.set(serverAddress, forKey: serverKey)
        try saveToken(token)
    }

    private static func saveToken(_ value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount,
            kSecAttrAccessGroup as String: keychainAccessGroup,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    private static func readToken(service: String, accessGroup: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func migrateLegacyConfigurationIfNeeded() throws {
        let sharedDefaults = UserDefaults(suiteName: appGroupID)
        if sharedDefaults?.string(forKey: serverKey) == nil,
           let legacyAddress = UserDefaults.standard.string(forKey: serverKey) {
            sharedDefaults?.set(legacyAddress, forKey: serverKey)
        }
        guard token.isEmpty,
              let legacyToken = readToken(service: "ca.tgs4.utility.DJISIM", accessGroup: nil),
              !legacyToken.isEmpty else { return }
        try saveToken(legacyToken)
    }
}

private enum AcknowledgementRequestError: LocalizedError {
    case invalidServerAddress
    case invalidResponse
    case http(status: Int, retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress: "ACK 服务器地址无效"
        case .invalidResponse: "ACK 响应无效"
        case let .http(status, _): "ACK 返回 HTTP \(status)"
        }
    }
}

@MainActor
final class SMSAcknowledgementManager {
    static let shared = SMSAcknowledgementManager()
    private let logger = Logger(subsystem: "ca.tgs4.utility.DJISIM", category: "sms-ack")
    private var retryTask: Task<Void, Never>?

    func acknowledge(smsID: String) async {
        let address = SharedGatewayConfiguration.serverAddress
        let token = SharedGatewayConfiguration.token
        guard !address.isEmpty, !token.isEmpty else {
            logger.error("ACK 配置不可用，保留待确认记录，sms_id=\(smsID, privacy: .public)")
            return
        }
        do {
            try await Self.send(smsID: smsID, serverAddress: address, token: token)
            try SMSPersistence.shared.recordAcknowledgementSuccess(smsID: smsID)
            logger.notice("短信 ACK 成功，sms_id=\(smsID, privacy: .public)")
        } catch {
            let requestError = error as? AcknowledgementRequestError
            let authenticationFailed: Bool
            let retryAfter: TimeInterval?
            if case let .http(status, value) = requestError {
                authenticationFailed = status == 401
                retryAfter = value
            } else {
                authenticationFailed = false
                retryAfter = nil
            }
            do {
                try SMSPersistence.shared.recordAcknowledgementFailure(
                    smsID: smsID,
                    authenticationFailed: authenticationFailed,
                    retryAfter: retryAfter,
                    description: error.localizedDescription
                )
            } catch {
                logger.error("保存 ACK 失败状态失败：\(error.localizedDescription, privacy: .public)")
            }
            logger.error("短信 ACK 失败，sms_id=\(smsID, privacy: .public)：\(error.localizedDescription, privacy: .public)")
        }
    }

    func retryPending() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            defer { self?.retryTask = nil }
            do {
                for smsID in try SMSPersistence.shared.pendingAcknowledgementIDs() {
                    guard !Task.isCancelled else { return }
                    await self?.acknowledge(smsID: smsID)
                }
            } catch {
                self?.logger.error("读取待确认短信失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func configurationDidChange() {
        do {
            try SMSPersistence.shared.resetAuthenticationFailedAcknowledgements()
        } catch {
            logger.error("恢复鉴权失败 ACK 任务失败：\(error.localizedDescription, privacy: .public)")
        }
        retryPending()
    }

    private nonisolated static func send(smsID: String, serverAddress: String, token: String) async throws {
        let trimmed = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              ["http", "https"].contains(components.scheme?.lowercased()),
              components.host != nil else { throw AcknowledgementRequestError.invalidServerAddress }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = components.url else { throw AcknowledgementRequestError.invalidServerAddress }
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("sms")
            .appendingPathComponent(smsID)
            .appendingPathComponent("ack")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AcknowledgementRequestError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AcknowledgementRequestError.http(status: http.statusCode, retryAfter: retryAfter)
        }
    }
}

struct APNSMessagePayload {
    let smsID: String
    let timestamp: Date
    let title: String
    let body: String

    init?(userInfo: [AnyHashable: Any], fallbackTitle: String? = nil, fallbackBody: String? = nil) {
        guard let smsID = userInfo["sms_id"] as? String, !smsID.isEmpty else { return nil }
        let aps = userInfo["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: Any]
        guard let title = (alert?["title"] as? String) ?? fallbackTitle,
              let body = (alert?["body"] as? String) ?? fallbackBody else { return nil }

        self.smsID = smsID
        self.title = title
        self.body = body
        timestamp = Self.parseTimestamp(userInfo["timestamp"]) ?? .now
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
        guard let string = value as? String else { return nil }
        if let seconds = TimeInterval(string) { return Date(timeIntervalSince1970: seconds) }
        if let date = fractionalFormatter.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
