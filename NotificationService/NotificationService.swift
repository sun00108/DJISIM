import Contacts
import OSLog
import UserNotifications

@MainActor
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let logger = Logger(subsystem: "ca.tgs4.utility.DJISIM", category: "notification-service")
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var processingTask: Task<Void, Never>?

    nonisolated override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        Task { @MainActor in
            processingTask = Task { @MainActor in
                await process(request, contentHandler: contentHandler)
            }
        }
    }

    private func process(
        _ request: UNNotificationRequest,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) async {
        logger.notice("[DJISIM-NSE] Extension 已收到通知，requestID=\(request.identifier, privacy: .public)")
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent else {
            logger.error("[DJISIM-NSE] 无法创建可修改的通知内容")
            contentHandler(request.content)
            return
        }

        // 当前约定：APNs alert.title 是发信号码，alert.body 是短信正文。
        // 不依赖任何自定义 payload 字段。
        let sender = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let payload = APNSMessagePayload(
            userInfo: content.userInfo,
            fallbackTitle: sender,
            fallbackBody: content.body
        ) {
            do {
                let inserted = try SMSPersistence.shared.storeIncoming(
                    smsID: payload.smsID,
                    timestamp: payload.timestamp,
                    title: payload.title,
                    body: payload.body,
                    requiresAcknowledgement: true
                )
                logger.notice("[DJISIM-NSE] SwiftData 写入完成，inserted=\(inserted)")
                await SMSAcknowledgementManager.shared.acknowledge(smsID: payload.smsID)
            } catch {
                logger.error("[DJISIM-NSE] SwiftData 写入失败：\(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.error("[DJISIM-NSE] payload 缺少 sms_id/title/body，未写入 SwiftData")
        }

        let status = CNContactStore.authorizationStatus(for: .contacts)
        logger.notice(
            "[DJISIM-NSE] 开始联系人匹配，sender=\(sender, privacy: .public)，authorizationStatus=\(status.rawValue)，bodyLength=\(content.body.count)"
        )
        if let contactName = contactName(matching: sender) {
            content.title = contactName
            logger.notice(
                "[DJISIM-NSE] 匹配成功，sender=\(sender, privacy: .public)，contactName=\(contactName, privacy: .public)"
            )
        } else {
            logger.notice("[DJISIM-NSE] 未匹配联系人，保留 sender=\(sender, privacy: .public)")
        }
        content.threadIdentifier = sender
        logger.notice("[DJISIM-NSE] 提交通知，finalTitle=\(content.title, privacy: .public)")
        guard self.contentHandler != nil else { return }
        self.contentHandler = nil
        processingTask = nil
        contentHandler(content)
    }

    nonisolated override func serviceExtensionTimeWillExpire() {
        Task { @MainActor in
            guard let contentHandler, let bestAttemptContent else { return }
            logger.error("[DJISIM-NSE] Extension 即将超时，提交当前内容")
            processingTask?.cancel()
            processingTask = nil
            self.contentHandler = nil
            contentHandler(bestAttemptContent)
        }
    }

    private func contactName(matching phoneNumber: String) -> String? {
        guard !phoneNumber.isEmpty else { return nil }

        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard hasContactAccess(status) else {
            logger.error("[DJISIM-NSE] Extension 没有通讯录权限，authorizationStatus=\(status.rawValue)")
            return nil
        }

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        // 1) 先用系统号码谓词（快）。它依赖 Contacts 内部索引，在扩展进程里常常返回空，
        //    因此仅作为快速路径，失败再走遍历。
        do {
            let predicate = CNContact.predicateForContacts(
                matching: CNPhoneNumber(stringValue: phoneNumber)
            )
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            logger.notice(
                "[DJISIM-NSE] 谓词查询完成，phone=\(phoneNumber, privacy: .public)，matchCount=\(contacts.count)"
            )
            if let name = contacts.lazy
                .compactMap({ CNContactFormatter.string(from: $0, style: .fullName) })
                .first {
                return name
            }
        } catch {
            logger.error("[DJISIM-NSE] 谓词查询失败：\(error.localizedDescription, privacy: .public)")
        }

        // 2) 回退：遍历通讯录，按“仅数字、末尾若干位”做后缀匹配。
        let target = Self.digits(from: phoneNumber)
        guard target.count >= 7 else {
            logger.notice("[DJISIM-NSE] 号码位数不足，跳过遍历匹配，digits=\(target, privacy: .public)")
            return nil
        }

        var matchedName: String?
        let request = CNContactFetchRequest(keysToFetch: keys)
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                for phone in contact.phoneNumbers {
                    let candidate = Self.digits(from: phone.value.stringValue)
                    guard candidate.count >= 7 else { continue }
                    let n = min(target.count, candidate.count, 10)
                    if target.suffix(n) == candidate.suffix(n) {
                        matchedName = CNContactFormatter.string(from: contact, style: .fullName)
                        stop.pointee = true
                        return
                    }
                }
            }
        } catch {
            logger.error("[DJISIM-NSE] 遍历联系人失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }

        logger.notice(
            "[DJISIM-NSE] 遍历匹配结束，digits=\(target, privacy: .public)，matched=\(matchedName ?? "-", privacy: .public)"
        )
        return matchedName
    }

    private static func digits(from string: String) -> String {
        String(string.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    private func hasContactAccess(_ status: CNAuthorizationStatus) -> Bool {
        if status == .authorized { return true }
#if os(iOS)
        if status == .limited { return true }
#endif
        return false
    }
}
