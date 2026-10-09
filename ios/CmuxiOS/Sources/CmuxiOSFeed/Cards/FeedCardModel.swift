import CmuxiOSFeatureKit
import Foundation

/// Everything one card renders; equal models render the same card.
struct FeedCardModel: Equatable {
    var item: FeedItem
    var isPending: Bool
    var isLive: Bool
    var choiceDraft: [String: FeedChoiceSelection]
    /// The detail screen shows the full body and checklist.
    var expanded: Bool

    /// Controls are enabled only for an open request while the owner is
    /// reachable and nothing is in flight for it.
    var canAnswer: Bool { item.needsInput && isLive && !isPending }
    var canDecline: Bool { item.isOpenRequest && isLive && !isPending }
}
