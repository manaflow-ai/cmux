import Foundation

/// The server-defined axis along which a pane layout is split.
public enum CmuxSplitDirection: String, Codable, Sendable, Equatable, Hashable {
    /// Places the second child to the right of the first child.
    case right

    /// Places the second child below the first child.
    case down
}
