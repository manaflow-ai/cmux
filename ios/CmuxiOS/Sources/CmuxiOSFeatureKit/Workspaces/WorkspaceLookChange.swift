import Foundation

/// One look field of a customize intent: leave it, clear it, or set it
/// (a color token or `#RRGGBB`; an SF Symbol name).
public enum WorkspaceLookChange: Hashable, Sendable {
    case unchanged
    case clear
    case set(String)

    /// The field after the change.
    public func applied(to value: String?) -> String? {
        switch self {
        case .unchanged: value
        case .clear: nil
        case .set(let new): new
        }
    }
}
