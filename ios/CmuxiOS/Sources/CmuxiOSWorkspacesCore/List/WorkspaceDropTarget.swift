import Foundation

/// The section a reordered row lands in.
public enum WorkspaceDropTarget: Hashable, Sendable {
    case ungrouped
    case group(String)
}
