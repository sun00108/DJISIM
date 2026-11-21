///* Copyright Yahagi Networks and Contributors */

import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RuntimeLogView: View {
    @ObservedObject private var log = AppLog.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if log.entries.isEmpty {
                ContentUnavailableView("暂无日志", systemImage: "doc.text.magnifyingglass")
            } else {
                ScrollView {
                    Text(log.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle("运行日志")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("清除") { log.clear() }
                    .disabled(log.entries.isEmpty)
                Button("复制") { copy(log.text) }
                    .disabled(log.entries.isEmpty)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
