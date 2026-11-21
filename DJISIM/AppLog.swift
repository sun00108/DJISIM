import Foundation
import Combine
import OSLog

@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var entries: [String] = []

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ca.tgs4.utility.DJISIM",
        category: "runtime"
    )
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    var text: String {
        entries.joined(separator: "\n")
    }

    func append(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        entries.append(line)
        if entries.count > 300 {
            entries.removeFirst(entries.count - 300)
        }
        logger.info("\(message, privacy: .public)")
    }

    func clear() {
        entries.removeAll()
        logger.info("运行日志已清除")
    }
}
