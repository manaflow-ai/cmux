public import Foundation

/// A workspace row: identity, title, arrangement and the status the
/// switcher shows.
public struct WorkspaceSummary: Identifiable, Hashable, Sendable {
    /// The daemon public id (`ws_...`).
    public var id: String
    public var hostID: HostID
    public var title: String
    /// Rolled up over the surfaces by severity.
    public var status: WorkspaceStatus
    public var paneCount: Int
    public var unreadCount: Int
    public var lastActivity: Date?
    public var panes: [WorkspacePane]
    /// The preview line of the most relevant surface.
    public var preview: String?
    public var isPinned: Bool
    public var group: WorkspaceGroup?
    /// The workspace color as `#RRGGBB`, when set on the Mac.
    public var color: String?
    /// The owner's order within the host.
    public var order: Int

    public init(
        id: String, hostID: HostID, title: String, status: WorkspaceStatus,
        paneCount: Int, unreadCount: Int = 0, lastActivity: Date? = nil,
        panes: [WorkspacePane] = [], preview: String? = nil, isPinned: Bool = false,
        group: WorkspaceGroup? = nil, color: String? = nil, order: Int = 0
    ) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.status = status
        self.paneCount = paneCount
        self.unreadCount = unreadCount
        self.lastActivity = lastActivity
        self.panes = panes
        self.preview = preview
        self.isPinned = isPinned
        self.group = group
        self.color = color
        self.order = order
    }
}
