import Foundation

/// Changes a phone may ask a host's workspace store for. Opening or focusing
/// a workspace, and collapsing a group on this phone, are client view state
/// and never intents.
public enum WorkspaceIntent: Hashable, Sendable {
    case create(hostID: HostID, title: String?)
    case rename(workspaceID: WorkspaceSummary.ID, title: String)
    case close(workspaceID: WorkspaceSummary.ID)
    /// Clears unread on every surface of the workspace.
    case markRead(workspaceID: WorkspaceSummary.ID)
    /// Files the workspace in `group` at `index` among that section's other
    /// members (a drag reorder or Move to Group).
    case move(workspaceID: WorkspaceSummary.ID, group: WorkspaceGroupPlacement, index: Int)
    case renameGroup(hostID: HostID, groupID: WorkspaceGroup.ID, name: String)
    /// Sets or clears the workspace's color and icon (the customize sheet).
    case customize(workspaceID: WorkspaceSummary.ID, color: WorkspaceLookChange, icon: WorkspaceLookChange)
}
