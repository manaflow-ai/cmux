import Foundation

/// Why the list shows no rows.
public enum WorkspaceListEmptyState: Hashable, Sendable {
    case loading
    case noMachines
    /// Machines exist but the user hid all of them.
    case allHidden
    case noWorkspaces
    case filterEmpty(WorkspaceListFilter)
}
