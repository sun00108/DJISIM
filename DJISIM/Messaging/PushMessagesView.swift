///* Copyright Yahagi Networks and Contributors */

import SwiftData
import SwiftUI

struct PushMessagesView: View {
    @ObservedObject var model: SMSViewModel
    let composeTransitionNamespace: Namespace.ID
    let composeTransitionID: String
    let compose: () -> Void
    @Query(sort: \StoredSMS.timestamp, order: .reverse) private var messages: [StoredSMS]

    private var conversations: [SMSConversation] {
        Dictionary(grouping: messages, by: \.conversationKey)
            .compactMap { key, messages in
                guard let latest = messages.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
                return SMSConversation(
                    id: key,
                    originalTitle: latest.title,
                    messages: messages.sorted(by: { $0.timestamp < $1.timestamp })
                )
            }
            .sorted { $0.latest.timestamp > $1.latest.timestamp }
    }

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "暂无推送短信",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("收到的 APNs 短信和从 App 发出的短信会显示在这里。")
                    )
                } else {
                    List(conversations) { conversation in
                        NavigationLink {
                            ConversationView(conversation: conversation, model: model)
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("推送短信")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: compose) {
                        Image(systemName: "square.and.pencil")
                    }
                    #if os(iOS)
                    .matchedTransitionSource(
                        id: composeTransitionID,
                        in: composeTransitionNamespace
                    )
                    #endif
                    .disabled(!model.hasConfiguration)
                }
            }
        }
    }
}

struct SMSConversation: Identifiable {
    let id: String
    let originalTitle: String
    let messages: [StoredSMS]

    var latest: StoredSMS { messages[messages.count - 1] }
}

private struct ConversationRow: View {
    let conversation: SMSConversation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ContactNameText(phoneNumber: conversation.originalTitle)
                        .font(.headline)
                    Spacer()
                    Text(conversation.latest.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    if conversation.latest.direction == .outgoing {
                        Text("你：")
                    }
                    Text(conversation.latest.body)
                        .lineLimit(1)
                    if conversation.latest.deliveryState == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
