import Foundation

/// A `FeedSource` over sample items: replies resolve the item, read marks
/// clear its unread state, both committed at once.
public final class MockFeedSource: FeedSource {
    public let hub: MockSnapshotHub<[FeedItem]>

    public init(items: [FeedItem] = MockFixtures.feedItems()) {
        hub = MockSnapshotHub(items)
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[FeedItem]>> {
        await hub.stream()
    }

    public func reply(_ reply: FeedReply, to itemID: FeedItem.ID, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { items in
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw MockRefusal("Unknown item") }
            guard items[index].resolution == nil, items[index].kind != .done else { throw MockRefusal("Item is closed") }
            items[index].resolution = reply
            items[index].isRead = true
        }
    }

    public func markRead(_ itemID: FeedItem.ID, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { items in
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw MockRefusal("Unknown item") }
            items[index].isRead = true
        }
    }
}
