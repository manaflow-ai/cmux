#if canImport(UIKit) && DEBUG
import Foundation
import UIKit

/// In-app ring buffer of recent debug log lines (DEV builds only).
///
/// On iOS a dogfooder can't easily read the unified log off the device, so we
/// keep the last `capacity` debug lines in memory and expose a "Copy Debug
/// Logs" action that drops them on the clipboard to paste back into a bug
/// report. `liveAnchormuxLog` feeds this buffer in addition to `NSLog`.
final class MobileDebugLog: @unchecked Sendable {
    static let shared = MobileDebugLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 4000
    private let startedAt = Date()

    private init() {}

    /// Append one timestamped line (seconds since the buffer was created).
    func append(_ message: String) {
        let elapsed = String(format: "%9.3f", Date().timeIntervalSince(startedAt))
        lock.lock()
        lines.append("[\(elapsed)] \(message)")
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        lock.unlock()
    }

    /// The full buffer as newline-joined text, newest last.
    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Copy the buffer to the system pasteboard, optionally prefixed with a
    /// section (e.g. the visible terminal text). Returns the line count copied.
    @MainActor
    @discardableResult
    func copyToPasteboard(prepending: String? = nil) -> Int {
        lock.lock()
        let count = lines.count
        let header = "cmux iOS debug log — \(count) lines\n" + String(repeating: "=", count: 40) + "\n"
        let body = lines.joined(separator: "\n")
        lock.unlock()
        var out = ""
        if let prepending, !prepending.isEmpty {
            out += prepending + "\n\n"
        }
        out += header + body
        UIPasteboard.general.string = out
        return count
    }
}
#endif
