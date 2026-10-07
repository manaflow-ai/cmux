import Foundation

/// The picker's answer: a workspace on a host, or a new workspace there
/// (`workspaceID == nil`).
public struct WorkspaceSelection: Hashable, Sendable {
    public var hostID: HostID
    public var workspaceID: WorkspaceSummary.ID?

    public init(hostID: HostID, workspaceID: WorkspaceSummary.ID?) {
        self.hostID = hostID
        self.workspaceID = workspaceID
    }
}
