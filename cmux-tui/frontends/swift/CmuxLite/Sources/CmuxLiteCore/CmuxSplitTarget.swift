import Foundation

/// A pane and axis pair that addresses one server split through `set-ratio`.
public struct CmuxSplitTarget: Sendable, Equatable, Hashable {
    /// A pane whose deepest matching ancestor is the intended split.
    public let pane: UInt64

    /// The intended split axis.
    public let direction: CmuxSplitDirection

    /// Creates a split target.
    /// - Parameters:
    ///   - pane: A pane below the intended split without a nearer same-axis split.
    ///   - direction: The intended split axis.
    public init(pane: UInt64, direction: CmuxSplitDirection) {
        self.pane = pane
        self.direction = direction
    }
}
