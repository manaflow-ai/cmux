import Foundation

/// Seam for lane C6 (feed). The owner is `FeedDO`; the phone holds a mirror.
///
/// `updates()` yields the confirmed mirror first, then one snapshot per
/// change batch (newest only). It never includes pending intents: the
/// screen's store overlays its own intent log (OWNERSHIP-PRINCIPLES "Clients
/// are projections"). `perform` answers once the owner settles the intent:
/// committed at a revision (the mirror is current once it reaches it) or
/// refused. While the connection is not live it throws
/// `FeatureSourceError.offline` and nothing queues.
public protocol FeedSource: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<[FeedItem]>>
    func perform(_ intent: FeedIntent, key: IntentKey) async throws -> IntentReceipt
}
