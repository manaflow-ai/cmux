public import Foundation

/// One feed item as the phone mirrors it from `FeedDO` (plans/cmux-next/feed.md
/// 3.1). Every field is owner-written; the phone changes items only through
/// `FeedIntent`s.
public struct FeedItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: FeedItemKind
    public var state: FeedItemState
    public var priority: FeedPriority
    /// `context.host`: the machine the item is about, when it names one.
    public var hostID: HostID?
    /// `context.workspace`.
    public var workspaceID: WorkspaceSummary.ID?
    /// The poster's display label, for example "Claude Code · cmux".
    public var source: String
    /// The poster's harness or agent (`claude`, `codex`), for grouping.
    public var agent: String?
    public var title: String
    /// Markdown, at most 4 KiB. For a `.done` notice this is the summary.
    public var body: String
    public var createdAt: Date
    public var expiresAt: Date?
    public var readAt: Date?
    public var seenAt: Date?
    public var archivedAt: Date?
    /// Set while the user snoozed the item; the owner clears it on wake.
    public var snoozedUntil: Date?
    public var answer: FeedAnswerRecord?
    public var cancelReason: FeedCancelReason?
    /// Per item, bumped by the owner on every change.
    public var revision: Int

    public init(
        id: String, kind: FeedItemKind, state: FeedItemState = .open, priority: FeedPriority = .normal,
        hostID: HostID? = nil, workspaceID: WorkspaceSummary.ID? = nil, source: String, agent: String? = nil,
        title: String, body: String = "", createdAt: Date, expiresAt: Date? = nil, readAt: Date? = nil,
        seenAt: Date? = nil, archivedAt: Date? = nil, snoozedUntil: Date? = nil, answer: FeedAnswerRecord? = nil,
        cancelReason: FeedCancelReason? = nil, revision: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.priority = priority
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.source = source
        self.agent = agent
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.readAt = readAt
        self.seenAt = seenAt
        self.archivedAt = archivedAt
        self.snoozedUntil = snoozedUntil
        self.answer = answer
        self.cancelReason = cancelReason
        self.revision = revision
    }

    /// A request needs exactly one answer (feed.md 3.3); a notice never does.
    public var isRequest: Bool { kind.isRequest }
    /// An open request: the user can answer or decline it.
    public var isOpenRequest: Bool { isRequest && state == .open }
    /// Open and answerable from the phone (not a Mac-only kind).
    public var needsInput: Bool { isOpenRequest && kind.isAnswerableOnPhone }
    public var isRead: Bool { readAt != nil }
    public var isArchived: Bool { archivedAt != nil }
    public var isSnoozed: Bool { snoozedUntil != nil }
}
