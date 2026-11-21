import SwiftUI
import UserNotifications
import Combine

extension Notification.Name {
    static let didReceiveDJISIMRemoteNotification = Notification.Name("DJISIM.didReceiveRemoteNotification")
}

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class PushNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var deviceToken: String?
    @Published private(set) var voIPToken: String?
    @Published private(set) var isDeviceTokenRegistered = false
    @Published private(set) var isVoIPTokenRegistered = false
    @Published private(set) var pushDisabled = UserDefaults.standard.bool(
        forKey: PushNotificationManager.pushDisabledKey
    )
    @Published private(set) var registrationError: String?

    private static let installationIDKey = "DJISIM.pushInstallationID"
    private static let pushDisabledKey = "DJISIM.pushDisabled"
    private var serverAddress = ""
    private var bearerToken = ""
    private var registrationTask: Task<Void, Never>?

    let installationID: UUID = PushNotificationManager.loadInstallationID()

    var allRequiredTokensRegistered: Bool {
        #if os(iOS)
        deviceToken != nil && voIPToken != nil
            && isDeviceTokenRegistered && isVoIPTokenRegistered
        #else
        deviceToken != nil && isDeviceTokenRegistered
        #endif
    }

    private static func loadInstallationID() -> UUID {
        if let value = UserDefaults.standard.string(forKey: installationIDKey),
           let uuid = UUID(uuidString: value) {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString.lowercased(), forKey: installationIDKey)
        return uuid
    }

    var authorizationDescription: String {
        switch authorizationStatus {
        case .notDetermined: "尚未申请"
        case .denied: "已拒绝"
        case .authorized: "已允许"
        case .provisional: "临时允许"
        case .ephemeral: "本次允许"
        @unknown default: "未知"
        }
    }

    func configure() {
        do {
            try SharedGatewayConfiguration.migrateLegacyConfigurationIfNeeded()
        } catch {
            AppLog.shared.append("❌ 迁移共享网关配置失败：\(error.localizedDescription)")
        }
        UNUserNotificationCenter.current().delegate = self
        updateBackendConfiguration(
            serverAddress: AppConfiguration.serverAddress,
            token: AppConfiguration.token
        )
        AppLog.shared.append("APNs 通知代理已配置")
        Task {
            await refreshAuthorizationStatus()
            // Apple 建议 App 每次启动都向 APNs 注册；这也能及时取得变化后的 token。
            registerForRemoteNotifications()
            SMSAcknowledgementManager.shared.retryPending()
        }
    }

    func updateBackendConfiguration(serverAddress: String, token: String) {
        self.serverAddress = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        bearerToken = token
        isDeviceTokenRegistered = false
        isVoIPTokenRegistered = false
        if pushDisabled {
            deleteDeviceFromBackendIfPossible()
        } else {
            registerDeviceWithBackendIfPossible()
        }
    }

    func setPushDisabled(_ disabled: Bool) {
        guard pushDisabled != disabled else { return }
        pushDisabled = disabled
        UserDefaults.standard.set(disabled, forKey: Self.pushDisabledKey)
        registrationTask?.cancel()
        registrationTask = nil

        if disabled {
            isDeviceTokenRegistered = false
            isVoIPTokenRegistered = false
            AppLog.shared.append("推送已由用户关闭，准备删除后端 installation")
            deleteDeviceFromBackendIfPossible()
        } else {
            AppLog.shared.append("推送已由用户开启，准备重新注册设备 Token")
            registerDeviceWithBackendIfPossible()
        }
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            AppLog.shared.append("通知权限请求完成，granted=\(granted)")
            guard granted else { return }
            registerForRemoteNotifications()
        } catch {
            registrationError = error.localizedDescription
            AppLog.shared.append("❌ 通知权限请求失败：\(error.localizedDescription)")
        }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func registerForRemoteNotifications() {
        AppLog.shared.append("正在向 APNs 注册远程通知")
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func didRegister(deviceToken data: Data) {
        let updatedToken = data.map { String(format: "%02x", $0) }.joined()
        if deviceToken != updatedToken {
            isDeviceTokenRegistered = false
        }
        deviceToken = updatedToken
        if !pushDisabled { registrationError = nil }
        AppLog.shared.append("✅ APNs Device Token 获取成功，长度=\(deviceToken?.count ?? 0)")
        registerDeviceWithBackendIfPossible()
    }

    func didRegister(voIPToken data: Data) {
        let updatedToken = data.map { String(format: "%02x", $0) }.joined()
        if voIPToken != updatedToken {
            isVoIPTokenRegistered = false
        }
        voIPToken = updatedToken
        if !pushDisabled { registrationError = nil }
        AppLog.shared.append("✅ PushKit VoIP Token 获取成功，长度=\(updatedToken.count)")
        registerDeviceWithBackendIfPossible()
    }

    func didInvalidateVoIPToken() {
        voIPToken = nil
        isVoIPTokenRegistered = false
        registerDeviceWithBackendIfPossible(clearVoIPToken: true)
    }

    private func registerDeviceWithBackendIfPossible(clearVoIPToken: Bool = false) {
        guard !pushDisabled else {
            AppLog.shared.append("⏸️ 暂不注册推送设备：用户已关闭推送")
            return
        }
        // APNs 回调可能发生在 SwiftUI 内容初始化或配置加载之前，发送前再读取一次持久化配置。
        if serverAddress.isEmpty {
            serverAddress = AppConfiguration.serverAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if bearerToken.isEmpty {
            bearerToken = AppConfiguration.token
        }

        guard deviceToken != nil || voIPToken != nil || clearVoIPToken else {
            AppLog.shared.append("⏸️ 暂不注册推送设备：尚未获得任何推送 Token")
            return
        }
        guard !serverAddress.isEmpty else {
            AppLog.shared.append("⏸️ 暂不注册推送设备：尚未保存网关地址")
            return
        }
        guard !bearerToken.isEmpty else {
            AppLog.shared.append("⏸️ 暂不注册推送设备：Keychain 中没有 Bearer Token")
            return
        }

        let serverAddress = serverAddress
        let bearerToken = bearerToken
        let installationID = installationID
        let registeredDeviceToken = deviceToken
        let registeredVoIPToken = voIPToken
        AppLog.shared.append(
            "准备注册推送设备，installation_id=\(installationID.uuidString.lowercased())"
        )
        registrationTask?.cancel()
        registrationTask = Task {
            do {
                let client = try SMSClient(serverAddress: serverAddress, token: bearerToken)
                try await client.registerPushDevice(
                    installationID: installationID,
                    deviceToken: registeredDeviceToken.map(PushTokenMutation.set) ?? .unchanged,
                    voIPToken: clearVoIPToken
                        ? .remove
                        : registeredVoIPToken.map(PushTokenMutation.set) ?? .unchanged
                )
                guard !Task.isCancelled else { return }
                if registeredDeviceToken == deviceToken, registeredDeviceToken != nil {
                    isDeviceTokenRegistered = true
                }
                if clearVoIPToken {
                    isVoIPTokenRegistered = false
                } else if registeredVoIPToken == voIPToken, registeredVoIPToken != nil {
                    isVoIPTokenRegistered = true
                }
                registrationError = nil
                AppLog.shared.append(
                    "✅ 推送设备注册成功，installation_id=\(installationID.uuidString.lowercased())"
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if registeredDeviceToken != nil { isDeviceTokenRegistered = false }
                if registeredVoIPToken != nil || clearVoIPToken { isVoIPTokenRegistered = false }
                registrationError = "推送设备注册失败：\(error.localizedDescription)"
                AppLog.shared.append("❌ \(registrationError ?? "推送设备注册失败")")
            }
        }
    }

    private func deleteDeviceFromBackendIfPossible() {
        if serverAddress.isEmpty {
            serverAddress = AppConfiguration.serverAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if bearerToken.isEmpty {
            bearerToken = AppConfiguration.token
        }

        guard !serverAddress.isEmpty else {
            registrationError = "无法关闭推送：尚未保存网关地址"
            AppLog.shared.append("⏸️ \(registrationError ?? "无法关闭推送")")
            return
        }
        guard !bearerToken.isEmpty else {
            registrationError = "无法关闭推送：Keychain 中没有 Bearer Token"
            AppLog.shared.append("⏸️ \(registrationError ?? "无法关闭推送")")
            return
        }

        let serverAddress = serverAddress
        let bearerToken = bearerToken
        let installationID = installationID
        registrationTask?.cancel()
        registrationTask = Task {
            do {
                let client = try SMSClient(serverAddress: serverAddress, token: bearerToken)
                try await client.deletePushDevice(installationID: installationID)
                guard !Task.isCancelled, pushDisabled else { return }
                isDeviceTokenRegistered = false
                isVoIPTokenRegistered = false
                registrationError = nil
                AppLog.shared.append(
                    "✅ 后端推送设备已删除，installation_id=\(installationID.uuidString.lowercased())"
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, pushDisabled else { return }
                registrationError = "关闭推送失败：\(error.localizedDescription)"
                AppLog.shared.append("❌ \(registrationError ?? "关闭推送失败")")
            }
        }
    }

    func didFailToRegister(_ error: Error) {
        isDeviceTokenRegistered = false
        registrationError = "APNs 注册失败：\(error.localizedDescription)"
        AppLog.shared.append("❌ \(registrationError ?? "APNs 注册失败")")
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any], source: String) {
        let payload = APNSMessagePayload(userInfo: userInfo)
        let smsID = payload?.smsID
        let fields = userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ",")
        AppLog.shared.append(
            "📨 收到 APNs 推送，source=\(source)，sms_id=\(smsID ?? "-")，fields=[\(fields)]"
        )
        if let payload {
            do {
                let inserted = try SMSPersistence.shared.storeIncoming(
                    smsID: payload.smsID,
                    timestamp: payload.timestamp,
                    title: payload.title,
                    body: payload.body,
                    requiresAcknowledgement: true
                )
                AppLog.shared.append("✅ APNs 短信已写入 SwiftData，inserted=\(inserted)")
                Task { await SMSAcknowledgementManager.shared.acknowledge(smsID: payload.smsID) }
            } catch {
                AppLog.shared.append("❌ APNs 短信写入 SwiftData 失败：\(error.localizedDescription)")
            }
        } else {
            AppLog.shared.append("⚠️ APNs payload 缺少 sms_id 或 aps.alert.title/body")
        }
        NotificationCenter.default.post(name: .didReceiveDJISIMRemoteNotification, object: nil)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await handleRemoteNotification(notification.request.content.userInfo, source: "foreground")
        return [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handleRemoteNotification(response.notification.request.content.userInfo, source: "notification-tap")
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            PushNotificationManager.shared.configure()
            CallManager.shared.configure()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushNotificationManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushNotificationManager.shared.didFailToRegister(error) }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            PushNotificationManager.shared.handleRemoteNotification(userInfo, source: "background")
            completionHandler(.newData)
        }
    }
}
#elseif os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in PushNotificationManager.shared.configure() }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushNotificationManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushNotificationManager.shared.didFailToRegister(error) }
    }
}
#endif
