public import Foundation

/// A workspace row: identity, title and the status the switcher shows.
public struct WorkspaceSummary: Identifiable, Hashable, Sendable {
    /// The daemon public id (`ws_...`).
    public var id: String
    public var hostID: HostID
    public var title: String
    public var status: WorkspaceStatus
    public var paneCount: Int
    public var unreadCount: Int
    public var lastActivity: Date?

    public init(
        id: String, hostID: HostID, title: String, status: WorkspaceStatus,
        paneCount: Int, unreadCount: Int = 0, lastActivity: Date? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.status = status
        self.paneCount = paneCount
        self.unreadCount = unreadCount
        self.lastActivity = lastActivity
    }
}
