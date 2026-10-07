import Foundation

/// Severity of one diagnostic line.
public enum DiagnosticLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool { lhs.rank < rhs.rank }
}
