import Foundation
import Security
import Combine
import SwiftData

struct SMSMessage: Decodable, Identifiable, Sendable {
    let id: String
    let sender: String
    let body: String
    let timestamp: String
    let isRead: Bool

    enum CodingKeys: String, CodingKey {
        case id, sender, body, timestamp
        case isRead = "is_read"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sender = try container.decode(String.self, forKey: .sender)
        body = try container.decode(String.self, forKey: .body)
        timestamp = try container.decode(String.self, forKey: .timestamp)

        // SQLite INTEGER 会由当前后端序列化成 0/1；同时兼容未来的 JSON Bool。
        if let value = try? container.decode(Bool.self, forKey: .isRead) {
            isRead = value
        } else if let value = try? container.decode(Int.self, forKey: .isRead) {
            isRead = value != 0
        } else if let value = try? container.decode(String.self, forKey: .isRead) {
            isRead = ["1", "true", "yes"].contains(value.lowercased())
        } else {
            isRead = false
        }
    }

    var date: Date? {
        Self.fractionalDateFormatter.date(from: timestamp) ?? Self.dateFormatter.date(from: timestamp)
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let dateFormatter = ISO8601DateFormatter()
}

private struct SMSListResponse: Decodable {
    let items: [SMSMessage]
}

private struct SendRequest: Encodable {
    let to: String
    let text: String
    let clientMessageID: String

    enum CodingKeys: String, CodingKey {
        case to, text
        case clientMessageID = "client_message_id"
    }
}

enum PushTokenMutation: Sendable {
    case unchanged
    case set(String)
    case remove
}

struct SendResponse: Decodable, Sendable {
    let queued: Bool
    let result: SendResult?
}

struct SendResult: Decodable, Sendable {
    let segments: Int?
}

struct ModuleStatus: Decodable, Sendable {
    let connected: Bool
    let identity: String?
    let bus: Int?
    let address: Int?
    let phoneNumber: String?
    let `operator`: ModuleOperator?
    let signal: ModuleSignal?
    let warnings: [String]?
    let error: String?
    let networkMeasuredAt: String?

    enum CodingKeys: String, CodingKey {
        case connected, identity, bus, address, `operator`, signal, warnings, error
        case phoneNumber = "phone_number"
        case networkMeasuredAt = "network_measured_at"
    }
}

struct ModuleOperator: Decodable, Sendable {
    let available: Bool?
    let name: String?
    let radio: String?
    let accessTechnology: Int?

    enum CodingKeys: String, CodingKey {
        case available, name, radio
        case accessTechnology = "access_technology"
    }
}

struct ModuleSignal: Decodable, Sendable {
    let available: Bool?
    let rssi: Int?
    let dbm: Int?
    let bars: Int?
    let ber: Int?
    let error: String?
}

enum SMSClientError: LocalizedError {
    case invalidServerAddress
    case invalidResponse
    case decoding(String)
    case server(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            return "服务器地址无效，请输入 http:// 或 https:// 开头的完整地址。"
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case let .decoding(detail):
            return "短信数据格式无法解析：\(detail)"
        case let .server(status, detail):
            if status == 401 { return "Token 无效或已失效。" }
            if status == 429 { return "鉴权失败次数过多，服务器已暂时限制请求。" }
            return "服务器错误（HTTP \(status)）：\(detail)"
        }
    }
}

struct SMSClient: Sendable {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    init(serverAddress: String, token: String, session: URLSession = .shared) throws {
        let trimmed = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              ["http", "https"].contains(components.scheme?.lowercased()),
              components.host != nil else {
            throw SMSClientError.invalidServerAddress
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = components.url else { throw SMSClientError.invalidServerAddress }
        self.baseURL = url
        self.token = token
        self.session = session
    }

    func list(limit: Int = 100) async throws -> [SMSMessage] {
        let data = try await request(path: "/api/v1/sms?limit=\(limit)", method: "GET")
        do {
            let items = try JSONDecoder().decode(SMSListResponse.self, from: data).items
            AppLog.shared.append("✅ 短信列表解析成功，items=\(items.count)")
            return items
        } catch let error as DecodingError {
            let detail = Self.describeDecodingError(error)
            AppLog.shared.append("❌ 短信列表解析失败：\(detail)")
            throw SMSClientError.decoding(detail)
        }
    }

    func send(to: String, text: String, clientMessageID: String) async throws -> SendResponse {
        let body = try JSONEncoder().encode(SendRequest(
            to: to,
            text: text,
            clientMessageID: clientMessageID
        ))
        let data = try await request(path: "/api/v1/sms/send", method: "POST", body: body)
        do {
            return try JSONDecoder().decode(SendResponse.self, from: data)
        } catch let error as DecodingError {
            let detail = Self.describeDecodingError(error)
            AppLog.shared.append("❌ 发送结果解析失败：\(detail)")
            throw SMSClientError.decoding(detail)
        }
    }

    func moduleStatus() async throws -> ModuleStatus {
        let data = try await request(path: "/api/v1/module", method: "GET")
        do {
            let status = try JSONDecoder().decode(ModuleStatus.self, from: data)
            AppLog.shared.append("✅ 模块状态解析成功，connected=\(status.connected)")
            return status
        } catch let error as DecodingError {
            let detail = Self.describeDecodingError(error)
            AppLog.shared.append("❌ 模块状态解析失败：\(detail)")
            throw SMSClientError.decoding(detail)
        }
    }

    func registerPushDevice(
        installationID: UUID,
        deviceToken: PushTokenMutation = .unchanged,
        voIPToken: PushTokenMutation = .unchanged
    ) async throws {
        var payload: [String: Any] = [:]
        switch deviceToken {
        case .unchanged: break
        case let .set(token): payload["device_token"] = token
        case .remove: payload["device_token"] = NSNull()
        }
        switch voIPToken {
        case .unchanged: break
        case let .set(token): payload["voip_token"] = token
        case .remove: payload["voip_token"] = NSNull()
        }
        guard !payload.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request(
            path: "/api/v1/push/devices/\(installationID.uuidString.lowercased())",
            method: "PUT",
            body: body
        )
    }

    func deletePushDevice(installationID: UUID) async throws {
        _ = try await request(
            path: "/api/v1/push/devices/\(installationID.uuidString.lowercased())",
            method: "DELETE"
        )
    }

    private func request(path: String, method: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SMSClientError.invalidServerAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let target = url.path + (url.query.map { "?\($0)" } ?? "")
        AppLog.shared.append("➡️ \(method) \(target) host=\(url.host ?? "-")")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.shared.append("❌ 网络请求失败 \(method) \(target)：\(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw SMSClientError.invalidResponse }
        AppLog.shared.append("⬅️ HTTP \(http.statusCode) \(method) \(target)，bytes=\(data.count)")
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(APIErrorBody.self, from: data).detail)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            AppLog.shared.append("❌ API 错误 HTTP \(http.statusCode)：\(detail)")
            throw SMSClientError.server(status: http.statusCode, detail: detail)
        }
        return data
    }

    private static func describeDecodingError(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case let .typeMismatch(_, value), let .valueNotFound(_, value),
             let .keyNotFound(_, value), let .dataCorrupted(value):
            context = value
        @unknown default:
            return error.localizedDescription
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return "字段 \(path.isEmpty ? "<root>" : path)：\(context.debugDescription)"
    }
}

private struct APIErrorBody: Decodable {
    let detail: String
}

@MainActor
final class SMSViewModel: ObservableObject {
    @Published var serverAddress: String
    @Published var token: String
    @Published private(set) var messages: [SMSMessage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var moduleStatus: ModuleStatus?
    @Published private(set) var isLoadingModule = false
    @Published var errorMessage: String?

    init() {
        do {
            try SharedGatewayConfiguration.migrateLegacyConfigurationIfNeeded()
        } catch {
            AppLog.shared.append("❌ 迁移共享网关配置失败：\(error.localizedDescription)")
        }
        serverAddress = AppConfiguration.serverAddress
        token = AppConfiguration.token
        AppLog.shared.append(
            "读取网关配置：address=\(serverAddress.isEmpty ? "missing" : "present")，token=\(token.isEmpty ? "missing" : "present")"
        )
    }

    var hasConfiguration: Bool {
        !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !token.isEmpty
    }

    @discardableResult
    func connect() async -> Bool {
        do {
            try saveConfiguration()
            AppLog.shared.append("连接配置已持久化，准备验证网关")
        } catch {
            errorMessage = "无法保存连接配置：\(error.localizedDescription)"
            AppLog.shared.append("❌ \(errorMessage ?? "连接配置保存失败")")
            return false
        }
        return await refresh()
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        AppLog.shared.append("开始刷新短信")
        defer { isLoading = false }
        do {
            let client = try SMSClient(serverAddress: serverAddress, token: token)
            messages = try await client.list()
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.describe(error)
            AppLog.shared.append("❌ 刷新失败：\(errorMessage ?? error.localizedDescription)")
            return false
        }
    }

    func send(
        to recipient: String,
        text: String,
        in context: ModelContext,
        retrying existingMessage: StoredSMS? = nil
    ) async -> Bool {
        guard !isSending else { return false }
        let recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: StoredSMS
        do {
            if let existingMessage {
                message = existingMessage
                message.deliveryState = .sending
                message.failureDescription = nil
                message.deliveryMayBeUncertain = false
                message.sendAttempts += 1
                try context.save()
            } else {
                message = try SMSPersistence.shared.makeOutgoing(
                    title: recipient,
                    body: text,
                    in: context
                )
            }
        } catch {
            errorMessage = "无法保存待发送短信：\(error.localizedDescription)"
            return false
        }

        isSending = true
        AppLog.shared.append("开始发送短信，recipient=\(Self.mask(recipient))，characters=\(text.count)")
        defer { isSending = false }
        do {
            let client = try SMSClient(serverAddress: serverAddress, token: token)
            _ = try await client.send(
                to: recipient,
                text: text,
                clientMessageID: message.smsID
            )
            message.deliveryState = .sent
            message.failureDescription = nil
            message.deliveryMayBeUncertain = false
            try context.save()
            errorMessage = nil
            AppLog.shared.append("✅ 网关已接受发送请求")
            await refresh()
            return true
        } catch {
            message.deliveryState = .failed
            message.failureDescription = Self.describe(error)
            message.deliveryMayBeUncertain = Self.deliveryMayBeUncertain(after: error)
            do {
                try context.save()
            } catch {
                AppLog.shared.append("❌ 无法保存短信失败状态：\(error.localizedDescription)")
            }
            errorMessage = Self.describe(error)
            AppLog.shared.append("❌ 发送失败：\(errorMessage ?? error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func refreshModuleStatus() async -> Bool {
        guard hasConfiguration, !isLoadingModule else { return false }
        isLoadingModule = true
        AppLog.shared.append("开始刷新模块状态")
        defer { isLoadingModule = false }
        do {
            let client = try SMSClient(serverAddress: serverAddress, token: token)
            moduleStatus = try await client.moduleStatus()
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.describe(error)
            AppLog.shared.append("❌ 模块状态刷新失败：\(errorMessage ?? error.localizedDescription)")
            return false
        }
    }

    private func saveConfiguration() throws {
        serverAddress = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        try AppConfiguration.save(serverAddress: serverAddress, token: token)
        AppLog.shared.append("网关配置保存成功：address=present，token=present")
        PushNotificationManager.shared.updateBackendConfiguration(
            serverAddress: serverAddress,
            token: token
        )
        #if os(iOS)
        CallManager.shared.configurationDidChange()
        #endif
        SMSAcknowledgementManager.shared.configurationDidChange()
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "无法连接服务器：\(urlError.localizedDescription)"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func deliveryMayBeUncertain(after error: Error) -> Bool {
        if case SMSClientError.decoding = error { return true }
        guard let urlError = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotParseResponse].contains(urlError.code)
    }

    private static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4 else { return "****" }
        return "***" + trimmed.suffix(4)
    }
}

enum AppConfiguration {
    static var serverAddress: String {
        SharedGatewayConfiguration.serverAddress
    }

    static var token: String {
        SharedGatewayConfiguration.token
    }

    static func save(serverAddress: String, token: String) throws {
        try SharedGatewayConfiguration.save(serverAddress: serverAddress, token: token)
    }
}
