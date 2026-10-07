import Foundation

/// One task on a Mac as its runner reports it (`task:<host>`).
public struct TaskRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var hostID: HostID
    public var workspaceID: WorkspaceSummary.ID?
    public var tabID: String?
    public var agentID: String
    public var state: TaskState
    public var title: String?
    public var createdAt: Date

    public init(id: String, hostID: HostID, workspaceID: WorkspaceSummary.ID? = nil, tabID: String? = nil,
                agentID: String, state: TaskState, title: String? = nil, createdAt: Date) {
        self.id = id
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.agentID = agentID
        self.state = state
        self.title = title
        self.createdAt = createdAt
    }
}
