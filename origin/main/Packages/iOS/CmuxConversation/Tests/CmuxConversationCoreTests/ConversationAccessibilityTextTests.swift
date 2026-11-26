import Foundation
import Testing
@testable import CmuxConversationCore

/// Bubble phrasing follows Messages' VoiceOver order: who, content, tapbacks, time.
@Suite struct ConversationAccessibilityTextTests {
    private func message(_ text: String, reactions: [ConversationReactionMark] = [], images: Int = 0) -> ConversationMessage {
        ConversationMessage(
            id: "m1", seq: 1, clientMessageID: nil, senderID: "ana", sentAt: Date(timeIntervalSince1970: 0), text: text,
            reactions: reactions,
            attachments: (0..<images).map { ConversationAttachment(id: "a\($0)", kind: .image, width: 4, height: 3, url: nil) }
        )
    }

    private let names = ["ana": "Ana", "bo": "Bo"]

    @Test func outgoingSpeaksYourMessageTextAndTime() {
        let label = ConversationAccessibilityText.messageLabel(message("I can book the table"), isOutgoing: true, senderName: "Me", reactorName: { _ in nil }, time: "3:14 AM")
        #expect(label == "Your message, I can book the table, 3:14 AM")
    }

    @Test func incomingLeadsWithTheSender() {
        let label = ConversationAccessibilityText.messageLabel(message("On my way"), isOutgoing: false, senderName: "Ana", reactorName: { names[$0] }, time: "9:41 PM")
        #expect(label == "Ana, On my way, 9:41 PM")
    }

    @Test func tapbacksComeAfterTheTextAndBeforeTheTime() {
        let marks = [ConversationReactionMark(participantID: "me", reaction: .heart), ConversationReactionMark(participantID: "bo", reaction: .haha)]
        let label = ConversationAccessibilityText.messageLabel(message("Dinner?", reactions: marks), isOutgoing: true, senderName: nil, reactorName: { names[$0] }, time: "3:14 AM")
        #expect(label == "Your message, Dinner?, You loved this, Bo laughed at this, 3:14 AM")
    }

    @Test func photosAreNamedBeforeTheCaption() {
        let one = ConversationAccessibilityText.messageLabel(message("", images: 1), isOutgoing: false, senderName: "Ana", reactorName: { _ in nil }, time: "1:00 PM")
        #expect(one == "Ana, Photo, 1:00 PM")
        let two = ConversationAccessibilityText.messageLabel(message("Look", images: 2), isOutgoing: false, senderName: "Ana", reactorName: { _ in nil }, time: "1:00 PM")
        #expect(two == "Ana, 2 photos, Look, 1:00 PM")
    }

    @Test func everyTapbackHasADistinctSpokenNameAndPhrase() {
        let names = Set(ConversationReaction.allCases.map(ConversationAccessibilityText.tapbackName))
        #expect(names.count == ConversationReaction.allCases.count)
        #expect(!names.contains { ConversationReaction(rawValue: $0) != nil })
        #expect(ConversationAccessibilityText.reactionPhrase(.thumbsup, by: "Bo") == "Bo liked this")
        #expect(ConversationAccessibilityText.reactionPhrase(.exclamation, by: nil) == "You emphasized this")
    }

    @Test func arrivalAnnouncementNamesSenderAndText() {
        #expect(ConversationAccessibilityText.receivedAnnouncement(senderName: "Ana", text: "Hi") == "Message received: Ana, Hi")
    }
}
