public import CmuxFeedPushCore
public import CmuxiOSFeatureKit

extension FeedPushIntent {
    /// The C6 intent this banner action stands for (c6-feed.md section 3).
    public var feedIntent: FeedIntent {
        switch change {
        case .read: .read(itemIDs: [item])
        case .answer(let answer): .answer(itemID: item, reply: answer.feedReply)
        }
    }

    /// The idempotency key, stable per (item, action, text).
    public var intentKey: IntentKey { IntentKey(rawValue: idempotencyKey) }
}

extension FeedAnswer {
    /// The same answer in C6's reply shape, so the banner and the Feed tab
    /// encode it once (`FeedIntent.wireParams`).
    public var feedReply: FeedReply {
        switch self {
        case .decision(let allow, let scope):
            .permission(allow: allow, scope: allow ? scope.flatMap(FeedPermissionScope.init(rawValue:)) : nil)
        case .confirmed(let value): .confirm(value)
        case .text(let text): .text(text)
        case .verdict(let approve, let comment): .plan(approved: approve, comment: comment)
        }
    }
}
