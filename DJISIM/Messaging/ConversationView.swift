///* Copyright Yahagi Networks and Contributors */

import SwiftData
import SwiftUI

struct ConversationView: View {
    let conversation: SMSConversation
    @ObservedObject var model: SMSViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredSMS.timestamp, order: .forward) private var allMessages: [StoredSMS]
    @State private var pendingRetry: StoredSMS?
    @State private var replyText = ""
    @FocusState private var replyIsFocused: Bool
    private let bottomAnchor = "conversation-bottom"

    private var messages: [StoredSMS] {
        allMessages.filter { $0.conversationKey == conversation.id }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { message in
                        MessageBubble(message: message) {
                            pendingRetry = message
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                replyBar
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }

            .onChange(of: messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                ContactNameText(phoneNumber: conversation.originalTitle)
                    .font(.headline)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .alert("重新发送短信？", isPresented: Binding(
            get: { pendingRetry != nil },
            set: { if !$0 { pendingRetry = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRetry = nil }
            Button("重新发送") {
                guard let message = pendingRetry else { return }
                pendingRetry = nil
                Task {
                    _ = await model.send(
                        to: message.title,
                        text: message.body,
                        in: modelContext,
                        retrying: message
                    )
                }
            }
        } message: {
            if pendingRetry?.deliveryMayBeUncertain == true {
                Text("上次请求的结果无法确认，对方可能已经收到；重新发送可能产生重复短信。")
            } else {
                Text("将使用相同的收件号码和正文再次发送。")
            }
        }
    }

    private var replyBar: some View {
        VStack(spacing: 7) {
            if let error = model.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        model.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭错误提示")
                }
            }

            HStack(alignment: .center, spacing: 9) {
                TextField("短信", text: $replyText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($replyIsFocused)
                    .submitLabel(.send)
                    .onSubmit(sendReply)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(
                        .regular.interactive(),
                        in: .rect(cornerRadius: 20)
                    )

                Button(action: sendReply) {
                    Group {
                        if model.isSending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(canSendReply ? Color.blue : Color.secondary.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSendReply)
                .accessibilityLabel("发送给 \(conversation.originalTitle)")
            }

            if replyText.count > 3800 {
                Text("\(replyText.count) / 4096")
                    .font(.caption2)
                    .foregroundStyle(replyText.count > 4096 ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    private var canSendReply: Bool {
        !model.isSending
            && model.hasConfiguration
            && !conversation.originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && replyText.count <= 4096
    }

    private func sendReply() {
        guard canSendReply else { return }
        let text = replyText
        replyText = ""
        replyIsFocused = false
        Task {
            _ = await model.send(
                to: conversation.originalTitle,
                text: text,
                in: modelContext
            )
        }
    }
}

private struct MessageBubble: View {
    let message: StoredSMS
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if message.direction == .outgoing { Spacer(minLength: 48) }
            if message.direction == .outgoing && message.deliveryState == .failed {
                Button(action: retry) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("发送失败，点按重试")
            }
            VStack(alignment: message.direction == .outgoing ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        message.direction == .outgoing ? Color.accentColor : Color.secondary.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 17)
                    )
                    .foregroundStyle(message.direction == .outgoing ? .white : .primary)
                HStack(spacing: 5) {
                    Text(message.timestamp, format: .dateTime.month().day().hour().minute())
                    if message.deliveryState == .sending {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if message.direction == .incoming { Spacer(minLength: 48) }
        }
    }
}
