import Foundation

/// Identifies the older or newer edge of a scrollback window.
public enum CmuxScrollbackDirection: Sendable, Equatable {
    /// The older, top edge.
    case previous

    /// The newer, bottom edge.
    case next
}
