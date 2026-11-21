///* Copyright Yahagi Networks and Contributors */

import SwiftUI
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @ObservedObject var model: SMSViewModel
    @ObservedObject private var push = PushNotificationManager.shared
    @ObservedObject private var contacts = ContactsManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingLogs = false
    #if os(iOS)
    @AppStorage(DialingPreferences.storageKey) private var defaultDialingCode = "+1"
    #endif

    var body: some View {
        Form {
            Section("网关") {
                TextField("服务器地址", text: $model.serverAddress)
                    .textContentType(.URL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("Bearer Token", text: $model.token)
                Button("保存并重新连接") {
                    Task { if await model.connect() { dismiss() } }
                }
                .disabled(model.isLoading || model.serverAddress.isEmpty || model.token.isEmpty)

                NavigationLink {
                    GatewayMessagesView(model: model)
                } label: {
                    Label("查看网关保存的最近所有短信", systemImage: "message")
                }
            }

            #if os(iOS)
            Section {
                TextField("+1", text: Binding(
                    get: { defaultDialingCode },
                    set: { defaultDialingCode = DialingPreferences.sanitizedCode($0) }
                ))
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            } header: {
                Text("默认拨出区号")
            } footer: {
                if DialingPreferences.isValidCountryCallingCode(defaultDialingCode) {
                    Text("拨号盘会自动把这个国家或地区呼叫代码放在号码前；默认值为 +1。")
                } else {
                    Text("请输入有效的 1–3 位国家或地区呼叫代码，例如 +1 或 +86。")
                        .foregroundStyle(.red)
                }
            }
            #endif

            Section {
                Toggle("关闭推送", isOn: Binding(
                    get: { push.pushDisabled },
                    set: { push.setPushDisabled($0) }
                ))
                Button("允许通知") {
                    Task { await push.requestAuthorization() }
                }
                .disabled(push.authorizationStatus != .notDetermined)
                LabeledContent("权限", value: push.authorizationDescription)
                LabeledContent(
                    "普通推送注册",
                    value: push.pushDisabled
                        ? "已关闭"
                        : push.isDeviceTokenRegistered ? "已注册" : "未完成"
                )
                #if os(iOS)
                LabeledContent(
                    "VoIP 推送注册",
                    value: push.pushDisabled
                        ? "已关闭"
                        : push.isVoIPTokenRegistered ? "已注册" : "未完成"
                )
                #endif
                if let deviceToken = push.deviceToken {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("APNs Device Token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(deviceToken)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        #if os(iOS)
                        Button("复制 Token") { UIPasteboard.general.string = deviceToken }
                        #elseif os(macOS)
                        Button("复制 Token") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deviceToken, forType: .string)
                        }
                        #endif
                    }
                } else {
                    Text("必须在已签名的真机 App 中运行，Apple 才会返回设备 Token。")
                        .foregroundStyle(.secondary)
                }
                #if os(iOS)
                if let voIPToken = push.voIPToken {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PushKit VoIP Token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(voIPToken)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("复制 VoIP Token") { UIPasteboard.general.string = voIPToken }
                    }
                }
                #endif
                if let registrationError = push.registrationError {
                    Text(registrationError).foregroundStyle(.red)
                }
            } header: {
                Text("推送通知")
            } footer: {
                Text("关闭后会从网关删除此设备的 installation，不再注册普通 APNs 或 VoIP Token；重新开启会自动注册当前 Token。")
            }

            Section {
                Button("允许访问通讯录") {
                    Task { await contacts.requestAuthorization() }
                }
                .disabled(contacts.hasContactAccess)

                LabeledContent("权限", value: contacts.authorizationDescription)
                if let errorMessage = contacts.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            } header: {
                Text("联系人姓名")
            } footer: {
                Text("允许后，通知扩展会用通知标题中的电话号码匹配联系人；未匹配时仍显示原号码。")
            }

            Section("诊断") {
                Button("查看运行日志") { showingLogs = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            await push.refreshAuthorizationStatus()
            contacts.refreshAuthorizationStatus()
        }
        .sheet(isPresented: $showingLogs) {
            NavigationStack { RuntimeLogView() }
        }
    }
}
