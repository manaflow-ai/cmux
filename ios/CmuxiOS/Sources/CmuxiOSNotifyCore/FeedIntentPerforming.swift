public import CmuxiOSFeatureKit

/// Sends one feed intent to its owner and returns the owner's settlement.
/// `CloudFeedSource` does this over the feed socket; banner actions use
/// `OpsFeedIntentPerformer`, one request that fits the background budget.
public protocol FeedIntentPerforming: Sendable {
    func perform(_ intent: FeedIntent, key: IntentKey) async throws -> IntentReceipt
}
