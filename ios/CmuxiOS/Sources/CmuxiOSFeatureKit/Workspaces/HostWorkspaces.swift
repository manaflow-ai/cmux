import Foundation

/// The workspaces of one host, in the host's order.
public struct HostWorkspaces: Identifiable, Hashable, Sendable {
    public var id: HostID { hostID }
    public var hostID: HostID
    public var hostName: String
    public var isReachable: Bool
    public var workspaces: [WorkspaceSummary]

    public init(hostID: HostID, hostName: String, isReachable: Bool, workspaces: [WorkspaceSummary]) {
        self.hostID = hostID
        self.hostName = hostName
        self.isReachable = isReachable
        self.workspaces = workspaces
    }
}
