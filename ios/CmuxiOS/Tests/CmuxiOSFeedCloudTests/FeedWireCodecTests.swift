@testable import CmuxiOSFeedCloud
import CmuxiOSFeatureKit
import Foundation
import Testing

@Suite struct FeedWireCodecTests {
    @Test func decodesEveryAnswerableKind() throws {
        let approve = try #require(FeedWireDecode.item(OwnerJSON.item("fi_1")))
        #expect(approve.kind == .permission(FeedPermission(actionType: .command, summary: "Run tests", command: "swift test", scopes: [.once, .session])))
        #expect(approve.hostID == HostID("mac-studio"))
        #expect(approve.workspaceID == "ws_1")
        #expect(approve.agent == "claude")
        #expect(approve.createdAt == Date(timeIntervalSince1970: 1_700_000_000))

        let choice = try #require(FeedWireDecode.item(OwnerJSON.item("fi_2", kind: "choice", extra: ["prompt": [
            "questions": [["id": "q", "question": "Pick", "options": [["id": "a", "label": "A", "description": "first"], ["id": "b", "label": "B"]],
                           "multi": true, "allow_other": true]]]])))
        guard case .choice(let parsed) = choice.kind else { Issue.record("\(choice.kind)"); return }
        #expect(parsed.questions.first?.options.first?.detail == "first")
        #expect(parsed.questions.first?.multi == true)

        let plan = try #require(FeedWireDecode.item(OwnerJSON.item("fi_3", kind: "review", extra: ["prompt": ["subject": "plan", "ref": "p.md", "checklist": ["x"]]])))
        #expect(plan.kind == .planApproval(FeedPlan(ref: "p.md", checklist: ["x"])))
        let pr = try #require(FeedWireDecode.item(OwnerJSON.item("fi_4", kind: "review", extra: ["prompt": ["subject": "pr", "ref": "1"]])))
        #expect(pr.kind == .unsupported(kind: "review", needsMac: false))
        let passkey = try #require(FeedWireDecode.item(OwnerJSON.item("fi_5", kind: "passkey")))
        #expect(passkey.kind == .unsupported(kind: "passkey", needsMac: true))
        let notice = try #require(FeedWireDecode.item(OwnerJSON.item("fi_6", kind: "notice", type: "notice")))
        #expect(notice.kind == .done)
        #expect(!notice.isRequest)
    }

    @Test func decodesTheAnswerRecordAndCancelReason() throws {
        let answered = try #require(FeedWireDecode.item(OwnerJSON.item("fi_1", state: "answered", extra: [
            "answer": ["value": ["decision": "allow", "scope": "session"], "by": "usr_1", "device": "Mac Studio", "at": 1_700_000_001_000]])))
        #expect(answered.answer?.reply == .permission(allow: true, scope: .session))
        #expect(answered.answer?.device == "Mac Studio")
        let cancelled = try #require(FeedWireDecode.item(OwnerJSON.item("fi_2", state: "cancelled", extra: [
            "cancel": ["reason": "answered_elsewhere", "by": "x", "at": 1]])))
        #expect(cancelled.cancelReason == .answeredElsewhere)
    }

    @Test func encodesAnswersInTheKindSchemas() {
        #expect(FeedWireEncode.answer(.permission(allow: false, scope: .always)) as NSDictionary == ["decision": "deny"])
        #expect(FeedWireEncode.answer(.permission(allow: true, scope: .session)) as NSDictionary == ["decision": "allow", "scope": "session"])
        #expect(FeedWireEncode.answer(.plan(approved: false, comment: "smaller")) as NSDictionary == ["verdict": "request_changes", "comment": "smaller"])
        #expect(FeedWireEncode.answer(.text("  answer  ")) as NSDictionary == ["text": "answer"])
        #expect(FeedWireEncode.answer(.plan(approved: true, comment: "  ")) as NSDictionary == ["verdict": "approve"])
        #expect(FeedWireEncode.answer(.choice(["q": FeedChoiceSelection(selected: ["a"], other: "z")])) as NSDictionary
                == ["answers": ["q": ["selected": ["a"], "other": "z"]]])
        let frame = FeedWireEncode.opFrame(.decline(itemID: "fi_1"), key: IntentKey(rawValue: "k1"), device: nil)
        #expect(frame as NSDictionary == ["t": "op", "op": "feed.cancel", "params": ["item": "fi_1", "reason": "declined"],
                                          "idempotency_key": "k1", "origin": "user"])
        #expect(FeedWireEncode.params(.readAll, device: nil) as NSDictionary == ["all": true])
        #expect(FeedWireEncode.params(.answer(itemID: "fi_1", reply: .confirm(true)), device: "iPhone") as NSDictionary
                == ["item": "fi_1", "answer": ["confirmed": true], "device": "iPhone"])
    }

    @Test func mirrorAppliesNextRevisionDropsDuplicatesAndFlagsGaps() throws {
        var mirror = FeedMirror()
        let a = try #require(FeedWireDecode.item(OwnerJSON.item("fi_a")))
        let b = try #require(FeedWireDecode.item(OwnerJSON.item("fi_b")))
        #expect(mirror.apply(event: 1, items: [a], present: nil) == .gap) // no snapshot yet
        mirror.apply(snapshot: 10, items: [a])
        #expect(mirror.apply(event: 10, items: [b], present: nil) == .duplicate)
        #expect(mirror.apply(event: 11, items: [b], present: nil) == .applied)
        #expect(mirror.items.count == 2)
        #expect(mirror.apply(event: 12, items: [], present: ["fi_b"]) == .applied)
        #expect(Array(mirror.items.keys) == ["fi_b"])
        #expect(mirror.apply(event: 14, items: [a], present: nil) == .gap)
        #expect(mirror.apply(event: 15, items: [a], present: nil) == .gap) // stays stale until a snapshot
        #expect(mirror.revision == 12)
    }
}
