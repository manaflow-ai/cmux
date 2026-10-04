import CmuxHomeCore
import Testing
@testable import CmuxHomeUI

/// The conversation screen's alert for a refused op (HomeStoreBinding.onRefusal).
@Suite struct HomeRefusalAlertTests {
    let conversation = ConversationID("conv_group")

    @Test func aRefusedReactionSaysSoAndWhy() {
        let intent = HomeIntent(op: .addReaction(message: MessageID("msg_7"), conversation: conversation,
                                                 reaction: .tapback(.love), partIndex: 0))
        let alert = HomeRefusalAlert(intent: intent, rejection: .notAuthorized)
        #expect(alert.title == HomeText.tapbackFailedTitle)
        #expect(alert.message == HomeText.explanation(for: .notAuthorized))
        #expect(alert.title == "Couldn't Add the Reaction")
    }

    @Test func otherRefusedOpsUseTheGeneralTitle() {
        let intent = HomeIntent(op: .setMuted(conversation: conversation, muted: true))
        let alert = HomeRefusalAlert(intent: intent, rejection: .ownerUnreachable)
        #expect(alert.title == HomeText.actionFailedTitle)
        #expect(alert.message == HomeText.explanation(for: .ownerUnreachable))
    }
}
