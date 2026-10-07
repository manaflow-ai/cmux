import Foundation

/// Seam for lane C6 (feed). The owner is `FeedDO`; the phone holds a mirror.
///
/// `updates()` yields the current snapshot first, then one snapshot per change
/// batch. Replies and read marks are intents with idempotency keys; the
/// visible feed reflects them once the owner echoes them.
public protocol FeedSource: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<[FeedItem]>>
    func reply(_ reply: FeedReply, to itemID: FeedItem.ID, key: IntentKey) async throws -> IntentReceipt
    func markRead(_ itemID: FeedItem.ID, key: IntentKey) async throws -> IntentReceipt
}
