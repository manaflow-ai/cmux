import Foundation

/// A pane split ratio clamped to the server-supported interval.
public struct CmuxSplitRatio: Sendable, Equatable {
    /// The minimum ratio accepted by the server.
    public static let minimum = 0.05

    /// The maximum ratio accepted by the server.
    public static let maximum = 0.95

    /// The clamped fractional size of the first child.
    public let value: Double

    /// Creates a clamped ratio.
    /// - Parameter value: An unclamped fractional first-child size.
    public init(clamping value: Double) {
        self.value = min(Self.maximum, max(Self.minimum, value))
    }

    /// Creates a ratio from a pointer offset within a split container.
    /// - Parameters:
    ///   - offset: The pointer distance from the first edge.
    ///   - extent: The container width or height.
    public init?(offset: Double, extent: Double) {
        guard extent > 0, offset.isFinite, extent.isFinite else { return nil }
        self.init(clamping: offset / extent)
    }

    /// Returns a changed ratio suitable for one server commit.
    /// - Parameter previous: The authoritative ratio at drag start.
    /// - Returns: The clamped value, or `nil` when it is unchanged.
    public func commit(comparedWith previous: Double) -> Double? {
        abs(value - CmuxSplitRatio(clamping: previous).value) <= 0.000_001 ? nil : value
    }
}
