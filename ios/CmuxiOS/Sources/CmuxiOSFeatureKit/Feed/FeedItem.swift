public import Foundation

/// One respondable agent event in the feed.
public struct FeedItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: FeedItemKind
    public var hostID: HostID
    public var workspaceID: WorkspaceSummary.ID?
    /// Short source label, for example the agent and workspace name.
    public var source: String
    public var title: String
    public var body: String
    public var createdAt: Date
    public var isRead: Bool
    /// The answer once the owner has recorded one; nil while open.
    public var resolution: FeedReply?

    public init(
        id: String, kind: FeedItemKind, hostID: HostID, workspaceID: WorkspaceSummary.ID? = nil,
        source: String, title: String, body: String, createdAt: Date, isRead: Bool = false,
        resolution: FeedReply? = nil
    ) {
        self.id = id
        self.kind = kind
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.source = source
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.resolution = resolution
    }
}
