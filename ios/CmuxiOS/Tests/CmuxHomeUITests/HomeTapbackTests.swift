import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
import UIKit
@testable import CmuxHomeUI

/// The iOS tapback picker over the shared reaction model: one button per
/// tapback in the shared order, with the shared names, my tapbacks selected,
/// and no target (so no picker) for a message without the owner's id. The
/// target rules themselves are tested in CmuxHomeRender (ReactionTargetTests).
@MainActor
@Suite struct HomeTapbackTests {
    let me = ParticipantID("user_me")
    let leo = ParticipantID("user_leo")
    let conversation = ConversationID("conv_group")
    let style = HomeReactionStyle()

    func item(messageID: MessageID? = MessageID("msg_7"), reactions: [Reaction] = []) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey("key_7"), seq: 7, author: leo, parts: [.text("Ship it.")],
                       createdAt: Date(timeIntervalSince1970: 1_800_000_000), delivery: .committed,
                       reactions: reactions, isRetracted: false, messageID: messageID)
    }

    func target(_ item: TranscriptItem) -> HomeReactionTarget? {
        HomeReactionTarget(item: item, partIndex: 0, conversation: conversation, me: me, isOnline: true)
    }

    @Test func buttonsFollowTheSharedOrderAndNames() throws {
        let picker = HomeTapbackPicker(target: try #require(target(item())))
        #expect(picker.buttons.map(\.accessibilityLabel) == style.tapbacks.map { style.accessibilityName($0) })
        #expect(picker.accessibilityLabel == style.pickerLabel)
        #expect(picker.intrinsicContentSize.width
            == CGFloat(style.tapbacks.count) * HomeTapbackPicker.buttonSize + 2 * HomeTapbackPicker.padding)
    }

    @Test func myTapbackIsSelected() throws {
        let reactions = [
            Reaction(author: me, partIndex: 0, kind: .tapback(.like)),
            Reaction(author: leo, partIndex: 0, kind: .tapback(.love)),
        ]
        let picker = HomeTapbackPicker(target: try #require(target(item(reactions: reactions))))
        let selected = zip(style.tapbacks, picker.buttons).filter { $0.1.accessibilityTraits.contains(.selected) }.map(\.0)
        #expect(selected == [.like])
    }

    @Test func aChoiceReachesOnChoose() throws {
        let picker = HomeTapbackPicker(target: try #require(target(item())))
        var chosen: [Reaction.Tapback] = []
        picker.onChoose = { chosen.append($0) }
        let index = try #require(style.tapbacks.firstIndex(of: .laugh))
        picker.buttons[index].sendActions(for: .primaryActionTriggered)
        #expect(chosen == [.laugh])
    }

    @Test func noTargetWithoutAMessageId() {
        #expect(target(item(messageID: nil)) == nil)
    }
}
