import Foundation

/// One scrubbed line of the diagnostic log.
public struct DiagnosticLine: Sendable, Equatable {
    public var date: Date
    public var level: DiagnosticLevel
    /// Short subsystem name, for example "router" or "auth".
    public var category: String
    /// Already scrubbed of secrets, emails and home paths.
    public var message: String

    public init(date: Date, level: DiagnosticLevel, category: String, message: String) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    /// One line of the exported file: ISO 8601 time, level, category, message.
    public var rendered: String {
        let time = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let flat = message.replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(time) [\(level.rawValue)] \(category): \(flat)"
    }
}
