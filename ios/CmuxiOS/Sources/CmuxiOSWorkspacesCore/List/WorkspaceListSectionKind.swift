import Foundation

/// What a section's title says.
public enum WorkspaceListSectionKind: Hashable, Sendable {
    case pinned
    case group(String)
    /// The machine's remaining workspaces.
    case workspaces
    /// A machine with nothing to list (no workspaces, or none match).
    case empty
    case flat
}
