import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxHomeUI

/// When the tapback picker may open, and the op a choice sends.
@Suite struct HomeTapbackTests {
    let me = ParticipantID("user_me")
    let leo = ParticipantID("user_leo")
    let conversation = ConversationID("conv_group")

    func item(messageID: MessageID? = MessageID("msg_7"), delivery: TranscriptItem.Delivery = .committed,
              retracted: Bool = false, reactions: [Reaction] = []) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey("key_7"), seq: 7, author: leo, parts: [.text("Ship it."), .text("Now.")],
                       createdAt: Date(timeIntervalSince1970: 1_800_000_000), delivery: delivery,
                       reactions: reactions, isRetracted: retracted, messageID: messageID)
    }

    func target(_ item: TranscriptItem, part: Int = 0, online: Bool = true) -> HomeTapbackTarget? {
        HomeTapbackTarget(item: item, partIndex: part, conversation: conversation, me: me, isOnline: online)
    }

    @Test func committedMessageWithAnIdBuildsTheAddReactionOp() throws {
        let target = try #require(target(item(), part: 1))
        #expect(target.op(.love) == .addReaction(message: MessageID("msg_7"), conversation: conversation,
                                                 reaction: .tapback(.love), partIndex: 1))
        #expect(target.op(.love)?.stream == .conversation(conversation))
    }

    @Test func noPickerWithoutAMessageId() {
        #expect(target(item(messageID: nil)) == nil)
        #expect(!HomeTapbackTarget.accepts(item(messageID: nil)))
    }

    @Test func noPickerForPendingRefusedOrRetractedMessages() {
        #expect(target(item(delivery: .sending)) == nil)
        #expect(target(item(delivery: .notDelivered(.notAuthorized))) == nil)
        #expect(target(item(retracted: true)) == nil)
    }

    @Test func noPickerOfflineOrForAMissingPart() {
        #expect(target(item(), online: false) == nil)
        #expect(target(item(), part: 2) == nil)
    }

    @Test func myTapbackOnThisPartIsChosenAndSendsNothing() throws {
        let reactions = [
            Reaction(author: me, partIndex: 0, kind: .tapback(.like)),
            Reaction(author: me, partIndex: 1, kind: .tapback(.laugh)),
            Reaction(author: leo, partIndex: 0, kind: .tapback(.love)),
            Reaction(author: me, partIndex: 0, kind: .emoji("🎉")),
        ]
        let target = try #require(target(item(reactions: reactions)))
        #expect(target.chosen == [.like])
        #expect(target.op(.like) == nil)
        #expect(target.op(.love) != nil)
    }
}
