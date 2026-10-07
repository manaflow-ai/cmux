import Foundation

/// The workspaces of one host, in the host's order.
public struct HostWorkspaces: Identifiable, Hashable, Sendable {
    public var id: HostID { hostID }
    public var hostID: HostID
    public var hostName: String
    public var isReachable: Bool
    public var workspaces: [WorkspaceSummary]
    public var kind: WorkspaceHostKind
    /// Changes this host's owner accepts right now.
    public var capabilities: WorkspaceCapabilities
    /// Why the host is unreachable ("Asleep", "Control plane unavailable").
    public var offlineReason: String?
    /// True while the mirror waits for a snapshot after a revision gap; the
    /// rows show the last confirmed state.
    public var isResyncing: Bool

    public init(
        hostID: HostID, hostName: String, isReachable: Bool, workspaces: [WorkspaceSummary],
        kind: WorkspaceHostKind = .mac, capabilities: WorkspaceCapabilities = .all,
        offlineReason: String? = nil, isResyncing: Bool = false
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.isReachable = isReachable
        self.workspaces = workspaces
        self.kind = kind
        self.capabilities = capabilities
        self.offlineReason = offlineReason
        self.isResyncing = isResyncing
    }
}
