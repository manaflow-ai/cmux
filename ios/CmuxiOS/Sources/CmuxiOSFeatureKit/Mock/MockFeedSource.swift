import Foundation

/// A `FeedSource` over sample items that applies the owner's rules at once:
/// answers and declines close open requests, a closed request refuses
/// ("answered elsewhere"), open requests cannot be archived.
public final class MockFeedSource: FeedSource {
    public let hub: MockSnapshotHub<[FeedItem]>
    /// The device name stamped on answers.
    private let device: String

    public init(items: [FeedItem] = MockFixtures.feedItems(), device: String = "iPhone") {
        hub = MockSnapshotHub(items)
        self.device = device
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[FeedItem]>> {
        await hub.stream()
    }

    public func perform(_ intent: FeedIntent, key: IntentKey) async throws -> IntentReceipt {
        let device = device
        let now = Date()
        return try await hub.receipt(for: key) { items in
            try Self.validate(intent, items)
            intent.apply(to: &items, at: now, device: device)
        }
    }

    /// The owner's refusals (feed.md 3.6) for the mock.
    private static func validate(_ intent: FeedIntent, _ items: [FeedItem]) throws {
        func item(_ id: FeedItem.ID) throws -> FeedItem {
            guard let item = items.first(where: { $0.id == id }) else { throw MockRefusal("Unknown item") }
            return item
        }
        switch intent {
        case .answer(let id, let reply):
            let target = try item(id)
            guard target.isOpenRequest else { throw MockRefusal("feed.closed") }
            guard reply.fits(target.kind) else { throw MockRefusal("validation.invalid") }
        case .decline(let id):
            guard try item(id).isOpenRequest else { throw MockRefusal("feed.closed") }
        case .archive(let ids):
            for id in ids where try item(id).isOpenRequest { throw MockRefusal("feed.open_request") }
        case .read(let ids), .seen(let ids):
            for id in ids { _ = try item(id) }
        case .readAll:
            break
        }
    }
}
