///* Copyright Yahagi Networks and Contributors */

import SwiftUI

struct ContactNameText: View {
    let phoneNumber: String
    @State private var displayName: String

    init(phoneNumber: String) {
        self.phoneNumber = phoneNumber
        _displayName = State(initialValue: phoneNumber.isEmpty ? "未知号码" : phoneNumber)
    }

    var body: some View {
        Text(displayName)
            .task(id: phoneNumber) {
                displayName = ContactsManager.shared.displayName(for: phoneNumber)
            }
    }
}

#Preview {
    ContactNameText(
        phoneNumber: "+12265071582"
    )
    .padding()
}
