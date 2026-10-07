public import CmuxiOSFeatureKit
public import Foundation

/// One workspace row as the list renders it.
public struct WorkspaceListRow: Identifiable, Hashable, Sendable {
    /// Unique across machines: `<host>/<workspace>`.
    public var id: String
    public var hostID: HostID
    public var workspaceID: WorkspaceSummary.ID
    public var title: String
    public var preview: String?
    public var status: WorkspaceStatus
    public var unreadCount: Int
    public var machineName: String
    public var machineColor: MachineColor
    public var isReachable: Bool
    public var isPinned: Bool
    public var lastActivity: Date?
    public var capabilities: WorkspaceCapabilities
    public var paneCount: Int
}
