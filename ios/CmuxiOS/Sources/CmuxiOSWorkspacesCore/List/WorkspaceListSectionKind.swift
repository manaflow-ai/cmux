import Foundation

/// What a section's title says.
public enum WorkspaceListSectionKind: Hashable, Sendable {
    case pinned
    /// A sidebar group of the machine (its owner id and name).
    case group(id: String, name: String)
    /// The machine's remaining (ungrouped) workspaces.
    case workspaces
    /// A machine with nothing to list (no workspaces, or none match).
    case empty
    case flat

    /// The group placement a drop into this section means; nil where a
    /// workspace cannot be dropped (Pinned, empty, flat).
    public var dropPlacement: WorkspaceDropTarget? {
        switch self {
        case .group(let id, _): .group(id)
        case .workspaces: .ungrouped
        case .pinned, .empty, .flat: nil
        }
    }
}
