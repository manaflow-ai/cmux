public import Foundation

/// A typed user intent for the feed owner (feed.md section 6). The caller
/// pairs it with an `IntentKey`; a resend after a reconnect reuses the key.
public enum FeedIntent: Hashable, Sendable {
    case answer(itemID: FeedItem.ID, reply: FeedReply)
    /// `feed.cancel` with reason `declined`.
    case decline(itemID: FeedItem.ID)
    case read(itemIDs: [FeedItem.ID])
    /// Reads every unread item the owner holds at commit.
    case readAll
    /// The items were shown in an open feed surface (no push for them).
    case seen(itemIDs: [FeedItem.ID])
    case archive(itemIDs: [FeedItem.ID])

    /// The catalog op.
    public var op: String {
        switch self {
        case .answer: "feed.answer"
        case .decline: "feed.cancel"
        case .read, .readAll: "feed.read"
        case .seen: "feed.seen"
        case .archive: "feed.archive"
        }
    }

    /// The visible effect on a mirror (pure). Mirrors the owner's rules
    /// (feed.md 3.6): answers and declines apply only to open requests, so a
    /// request that closed elsewhere keeps its closed state; open requests
    /// are never archived.
    public func apply(to items: inout [FeedItem], at date: Date, device: String?) {
        func update(_ ids: Set<FeedItem.ID>, _ change: (inout FeedItem) -> Void) {
            for index in items.indices where ids.contains(items[index].id) { change(&items[index]) }
        }
        switch self {
        case .answer(let id, let reply):
            update([id]) { item in
                guard item.isOpenRequest else { return }
                item.state = .answered
                item.answer = FeedAnswerRecord(reply: reply, device: device, at: date)
                item.readAt = item.readAt ?? date
            }
        case .decline(let id):
            update([id]) { item in
                guard item.isOpenRequest else { return }
                item.state = .cancelled
                item.cancelReason = .declined
                item.readAt = item.readAt ?? date
            }
        case .read(let ids):
            update(Set(ids)) { item in item.readAt = item.readAt ?? date }
        case .readAll:
            for index in items.indices where items[index].readAt == nil { items[index].readAt = date }
        case .seen(let ids):
            update(Set(ids)) { item in item.seenAt = item.seenAt ?? date }
        case .archive(let ids):
            update(Set(ids)) { item in
                guard !item.isOpenRequest, item.archivedAt == nil else { return }
                item.archivedAt = date
                item.readAt = item.readAt ?? date
            }
        }
    }
}
