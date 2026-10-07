import Foundation

/// Changes a phone may ask a host's workspace store for. Opening or focusing
/// a workspace is client view state and never an intent.
public enum WorkspaceIntent: Hashable, Sendable {
    case create(hostID: HostID, title: String?)
    case rename(workspaceID: WorkspaceSummary.ID, title: String)
    case close(workspaceID: WorkspaceSummary.ID)
}
