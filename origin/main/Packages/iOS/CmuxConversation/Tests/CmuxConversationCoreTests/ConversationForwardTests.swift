import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationForwardDraftTests {
    func message(_ id: String, _ text: String, unsent: Bool = false, photos: Int = 0) -> ConversationMessage {
        var message = ConversationMessage(
            id: id, seq: Int(id.dropFirst()), clientMessageID: nil, senderID: "me",
            sentAt: Date(timeIntervalSince1970: 0), text: text,
            unsentAt: unsent ? Date(timeIntervalSince1970: 1) : nil
        )
        message.attachments = (0..<photos).map { index in
            ConversationAttachment(id: "\(id)-p\(index)", kind: .image, width: 10, height: 10, url: URL(string: "https://example.com/\(id)/\(index).jpg"))
        }
        return message
    }

    @Test func keepsTranscriptOrderRegardlessOfSelectionOrder() {
        let transcript = [message("m1", "first"), message("m2", "second"), message("m3", "third")]
        let draft = ConversationForwardDraft(transcript: transcript, selectedIDs: ["m3", "m1"])
        #expect(draft.messages.map(\.id) == ["m1", "m3"])
        #expect(draft.draftText == "first\nthird")
    }

    @Test func dropsUnsentMessagesAndEmptyTexts() {
        let transcript = [message("m1", "", photos: 2), message("m2", "gone", unsent: true), message("m3", "kept")]
        let draft = ConversationForwardDraft(transcript: transcript, selectedIDs: ["m1", "m2", "m3"])
        #expect(draft.messages.map(\.id) == ["m1", "m3"])
        #expect(draft.draftText == "kept")
        #expect(draft.attachments.map(\.id) == ["m1-p0", "m1-p1"])
        #expect(!draft.isEmpty)
    }

    @Test func emptySelectionIsEmpty() {
        let draft = ConversationForwardDraft(transcript: [message("m1", "hi")], selectedIDs: [])
        #expect(draft.isEmpty)
        #expect(draft.draftText.isEmpty)
    }
}
