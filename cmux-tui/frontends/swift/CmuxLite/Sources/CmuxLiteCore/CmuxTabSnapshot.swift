import Foundation

/// An immutable tab entry rendered in the selected pane's tab strip.
public struct CmuxTabSnapshot: Sendable, Equatable {
    /// The server-owned surface identifier.
    public let surface: UInt64

    /// The server-provided tab name or title, when non-empty.
    public let label: String?

    /// Creates a tab snapshot.
    /// - Parameters:
    ///   - surface: The server-owned surface identifier.
    ///   - label: The preferred display name, when available.
    public init(surface: UInt64, label: String?) {
        self.surface = surface
        self.label = label
    }
}
