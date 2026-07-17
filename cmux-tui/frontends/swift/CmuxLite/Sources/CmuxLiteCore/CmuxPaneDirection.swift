import Foundation

/// A local directional focus or resize intent.
public enum CmuxPaneDirection: Sendable, Equatable, Hashable {
    /// Move or resize toward the left edge.
    case left

    /// Move or resize toward the right edge.
    case right

    /// Move or resize toward the top edge.
    case up

    /// Move or resize toward the bottom edge.
    case down

    /// The split axis addressed by this direction.
    public var splitDirection: CmuxSplitDirection {
        switch self {
        case .left, .right: .right
        case .up, .down: .down
        }
    }

    /// The signed ratio delta associated with the direction.
    public var ratioSign: Double {
        switch self {
        case .left, .up: -1
        case .right, .down: 1
        }
    }
}
