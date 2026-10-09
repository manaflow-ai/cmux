import CmuxiOSFeatureKit
import Foundation

/// The card's callbacks into the screen (main actor).
@MainActor
struct FeedCardActions {
    var answer: (FeedItem.ID, FeedReply) -> Void
    var compose: (FeedComposeRequest) -> Void
    var toggleChoice: (FeedItem.ID, FeedChoiceQuestion, FeedChoiceOption.ID) -> Void
    var decline: (FeedItem.ID) -> Void
}
