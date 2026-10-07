import CmuxiOSFeatureKit
import Foundation

/// What the text composer is answering.
enum FeedComposeRequest: Equatable {
    case questionReply(itemID: FeedItem.ID, prompt: String)
    case choiceOther(itemID: FeedItem.ID, question: FeedChoiceQuestion)
    case planChanges(itemID: FeedItem.ID)

    var itemID: FeedItem.ID {
        switch self {
        case .questionReply(let id, _), .choiceOther(let id, _), .planChanges(let id): id
        }
    }
}
