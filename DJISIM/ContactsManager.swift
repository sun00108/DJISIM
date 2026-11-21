import Contacts
import Combine

@MainActor
final class ContactsManager: ObservableObject {
    static let shared = ContactsManager()

    @Published private(set) var authorizationStatus: CNAuthorizationStatus =
        CNContactStore.authorizationStatus(for: .contacts)
    @Published private(set) var errorMessage: String?
    private var nameCache: [String: String] = [:]

    var hasContactAccess: Bool {
        if authorizationStatus == .authorized { return true }
#if os(iOS) || os(visionOS)
        if authorizationStatus == .limited { return true }
#endif
        return false
    }

    var authorizationDescription: String {
        switch authorizationStatus {
        case .notDetermined: "尚未申请"
        case .restricted: "受系统限制"
        case .denied: "已拒绝"
        case .authorized: "已允许全部联系人"
#if os(iOS) || os(visionOS)
        case .limited: "已允许部分联系人"
#endif
        @unknown default: "未知"
        }
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        nameCache.removeAll()
    }

    func requestAuthorization() async {
        do {
            let granted = try await CNContactStore().requestAccess(for: .contacts)
            refreshAuthorizationStatus()
            errorMessage = granted ? nil : "未授予通讯录访问权限。"
            AppLog.shared.append("通讯录权限请求完成，granted=\(granted)，status=\(authorizationDescription)")
        } catch {
            refreshAuthorizationStatus()
            errorMessage = "通讯录权限请求失败：\(error.localizedDescription)"
            AppLog.shared.append("❌ \(errorMessage ?? "通讯录权限请求失败")")
        }
    }

    func displayName(for phoneNumber: String) -> String {
        let fallback = phoneNumber.isEmpty ? "未知号码" : phoneNumber
        guard hasContactAccess, !phoneNumber.isEmpty else { return fallback }
        let key = StoredSMS.normalizedConversationKey(phoneNumber)
        if let cached = nameCache[key] { return cached }

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        if let contacts = try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phoneNumber)),
            keysToFetch: keys
        ), let name = contacts.compactMap({ CNContactFormatter.string(from: $0, style: .fullName) }).first {
            nameCache[key] = name
            return name
        }

        guard key.count >= 7 else { return fallback }
        var result: String?
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, stop in
            for number in contact.phoneNumbers {
                let candidate = StoredSMS.normalizedConversationKey(number.value.stringValue)
                let length = min(key.count, candidate.count, 10)
                if length >= 7, key.suffix(length) == candidate.suffix(length) {
                    result = CNContactFormatter.string(from: contact, style: .fullName)
                    stop.pointee = true
                    return
                }
            }
        }
        let name = result ?? fallback
        nameCache[key] = name
        return name
    }

    func displayNameAsync(for phoneNumber: String) async -> String {
        let fallback = phoneNumber.isEmpty ? "未知号码" : phoneNumber
        guard hasContactAccess, !phoneNumber.isEmpty else { return fallback }
        let key = StoredSMS.normalizedConversationKey(phoneNumber)
        if let cached = nameCache[key] { return cached }

        let name = await Task.detached(priority: .userInitiated) {
            Self.lookupDisplayName(for: phoneNumber, normalizedKey: key)
        }.value ?? fallback
        nameCache[key] = name
        return name
    }

    private nonisolated static func lookupDisplayName(
        for phoneNumber: String,
        normalizedKey key: String
    ) -> String? {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        if let contacts = try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(
                matching: CNPhoneNumber(stringValue: phoneNumber)
            ),
            keysToFetch: keys
        ), let name = contacts.compactMap({
            CNContactFormatter.string(from: $0, style: .fullName)
        }).first {
            return name
        }

        guard key.count >= 7 else { return nil }
        var result: String?
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, stop in
            for number in contact.phoneNumbers {
                let candidate = StoredSMS.normalizedConversationKey(number.value.stringValue)
                let length = min(key.count, candidate.count, 10)
                if length >= 7, key.suffix(length) == candidate.suffix(length) {
                    result = CNContactFormatter.string(from: contact, style: .fullName)
                    stop.pointee = true
                    return
                }
            }
        }
        return result
    }
}
