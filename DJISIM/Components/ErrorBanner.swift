///* Copyright Yahagi Networks and Contributors */

import SwiftUI

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.callout)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ErrorBanner(
        message: "发送失败，请检查网络连接后重试。",
        dismiss: {}
    )
    .padding()
}
