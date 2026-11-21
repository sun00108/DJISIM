///* Copyright Yahagi Networks and Contributors */

import SwiftData
import SwiftUI

struct ComposeMessageView: View {
    @ObservedObject var model: SMSViewModel
    @ObservedObject private var contacts = ContactsManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var recipient = ""
    @State private var text = ""
    @FocusState private var focusedField: Field?
    #if os(iOS)
    @AppStorage(DialingPreferences.storageKey) private var defaultDialingCode = "+1"
    #endif

    private enum Field: Hashable {
        case recipient
        case message
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("收件人：")
                            .foregroundStyle(.secondary)
                        TextField("电话号码", text: $recipient)
                            .focused($focusedField, equals: .recipient)
                            .textContentType(.telephoneNumber)
                            #if os(iOS)
                            .keyboardType(.phonePad)
                            #endif
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .glassEffect(.regular.interactive(), in: .capsule)

                    if let contactName {
                        Label(contactName, systemImage: "person.crop.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer(minLength: 16)
            }
            .navigationTitle("新信息")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composeBar
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        .onAppear {
            if recipient.isEmpty {
                #if os(iOS)
                recipient = DialingPreferences.effectiveCode(defaultDialingCode)
                #else
                recipient = "+1"
                #endif
            }
            focusedField = .recipient
        }
    }

    private var contactName: String? {
        let number = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard contacts.hasContactAccess,
              number.filter(\.isNumber).count >= 7 else { return nil }
        let name = contacts.displayName(for: number)
        return name == number ? nil : name
    }

    private var composeBar: some View {
        VStack(spacing: 7) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .center, spacing: 9) {
                TextField("短信", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focusedField, equals: .message)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(
                        .regular.interactive(),
                        in: .rect(cornerRadius: 20)
                    )

                Button(action: send) {
                    Group {
                        if model.isSending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(canSend ? Color.green : Color.secondary.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送短信")
            }

            if text.count > 3800 {
                Text("\(text.count) / 4096")
                    .font(.caption2)
                    .foregroundStyle(text.count > 4096 ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    private var canSend: Bool {
        !model.isSending
            && model.hasConfiguration
            && !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= 4096
    }

    private func send() {
        guard canSend else { return }
        let destination = recipient
        let message = text
        Task {
            if await model.send(to: destination, text: message, in: modelContext) {
                focusedField = nil
                dismiss()
            }
        }
    }
}

#Preview {
    ComposeMessageView(model: SMSViewModel())
}
