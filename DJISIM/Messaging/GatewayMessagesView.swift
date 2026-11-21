///* Copyright Yahagi Networks and Contributors */

import SwiftUI

struct GatewayMessagesView: View {
    @ObservedObject var model: SMSViewModel
    @State private var showingComposer = false
    @Namespace private var composeTransitionNamespace

    var body: some View {
        Group {
            if !model.hasConfiguration {
                ConnectionView(model: model)
            } else if model.messages.isEmpty && model.isLoading {
                ProgressView("正在连接网关…")
            } else if model.messages.isEmpty {
                ContentUnavailableView(
                    "暂无短信",
                    systemImage: "message",
                    description: Text("下拉刷新，或检查服务器连接。")
                )
            } else {
                List(model.messages) { message in
                    MessageRow(message: message)
                }
                .listStyle(.inset)
                .refreshable { await model.refresh() }
            }
        }
        .navigationTitle("DJI SIM 短信")
        .toolbar {
            if model.hasConfiguration {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)

                    Button {
                        showingComposer = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    #if os(iOS)
                    .matchedTransitionSource(
                        id: "gateway-messages-compose",
                        in: composeTransitionNamespace
                    )
                    #endif
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
                    .padding()
            }
        }
        .sheet(isPresented: $showingComposer) {
            ComposeMessageView(model: model)
                #if os(iOS)
                .navigationTransition(
                    .zoom(
                        sourceID: "gateway-messages-compose",
                        in: composeTransitionNamespace
                    )
                )
                #endif
        }
        .task {
            guard model.hasConfiguration else { return }
            await model.refresh()
        }
    }
}


private struct MessageRow: View {
    let message: SMSMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.sender.isEmpty ? "未知号码" : message.sender)
                    .font(.headline)
                Spacer()
                if let date = message.date {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(message.body)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(message.isRead ? .secondary : .primary)
                .lineLimit(5)
        }
        .padding(.vertical, 5)
    }
}

private struct ConnectionView: View {
    @ObservedObject var model: SMSViewModel

    var body: some View {
        Form {
            Section {
                TextField("https://gateway.example.com:8765", text: $model.serverAddress)
                    .textContentType(.URL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("Bearer Token", text: $model.token)
            } header: {
                Text("网关连接")
            } footer: {
                Text("地址可以包含端口，但不要包含 /api/v1。Token 会安全保存在系统 Keychain。")
            }

            Button {
                Task { await model.connect() }
            } label: {
                HStack {
                    Spacer()
                    if model.isLoading { ProgressView() } else { Text("连接并获取短信") }
                    Spacer()
                }
            }
            .disabled(model.isLoading || model.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.token.isEmpty)
        }
        .formStyle(.grouped)
    }
}
