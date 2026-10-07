import Foundation

/// The status glyph color of a placeholder row.
public enum PlaceholderStatus: Hashable, Sendable {
    case running
    case waiting
    case failed
    case idle
}
