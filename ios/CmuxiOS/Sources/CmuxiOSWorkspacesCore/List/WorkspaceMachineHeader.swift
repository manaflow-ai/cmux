public import CmuxiOSFeatureKit

/// A machine's header in the list.
public struct WorkspaceMachineHeader: Hashable, Sendable {
    public var hostID: HostID
    public var name: String
    public var kind: WorkspaceHostKind
    public var color: MachineColor
    public var isReachable: Bool
    public var offlineReason: String?
    public var isResyncing: Bool
    public var workspaceCount: Int
    public var unreadCount: Int
}
