public import CmuxiOSFeatureKit

/// The terminal surface the user opened from a workspace.
public struct WorkspaceTerminalTarget: Hashable, Sendable {
    public var hostID: HostID
    public var hostName: String
    public var workspaceID: WorkspaceSummary.ID
    /// The tab (`tab_...`).
    public var surfaceID: WorkspaceSurface.ID
    /// The session host's terminal (`term_...`).
    public var terminalID: String
    public var title: String

    public init(hostID: HostID, hostName: String, workspaceID: WorkspaceSummary.ID,
                surfaceID: WorkspaceSurface.ID, terminalID: String, title: String) {
        self.hostID = hostID
        self.hostName = hostName
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.terminalID = terminalID
        self.title = title
    }
}
