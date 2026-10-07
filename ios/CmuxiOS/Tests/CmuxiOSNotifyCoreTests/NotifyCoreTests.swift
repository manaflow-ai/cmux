import CmuxFeedPushCore
import CmuxiOSFeatureKit
import Foundation
import Testing
@testable import CmuxiOSNotifyCore

/// Records sent ops; refuses or fails on demand.
actor RecordingOps: CloudOpsSending {
    private(set) var sent: [CloudOp] = []
    var failure: CloudOpsError?

    init(failure: CloudOpsError? = nil) { self.failure = failure }

    func send(_ op: CloudOp, as user: String?) async throws {
        sent.append(op)
        if let failure { throw failure }
    }
}

@Suite struct BannerIntentMappingTests {
    @Test func everyAnswerMapsToTheC6Reply() {
        #expect(FeedAnswer.decision(allow: true, scope: "session").feedReply == .permission(allow: true, scope: .session))
        #expect(FeedAnswer.decision(allow: true, scope: nil).feedReply == .permission(allow: true, scope: nil))
        #expect(FeedAnswer.decision(allow: false, scope: "session").feedReply == .permission(allow: false, scope: nil))
        #expect(FeedAnswer.confirmed(false).feedReply == .confirm(false))
        #expect(FeedAnswer.text("ok").feedReply == .text("ok"))
        #expect(FeedAnswer.verdict(approve: false, comment: "more tests").feedReply == .plan(approved: false, comment: "more tests"))
    }

    @Test func pushIntentsBecomeFeedIntentsWithTheSameKey() {
        let read = FeedPushIntent(item: "fi_1", change: .read, idempotencyKey: "k-read")
        #expect(read.feedIntent == .read(itemIDs: ["fi_1"]))
        #expect(read.intentKey == IntentKey(rawValue: "k-read"))
        let answer = FeedPushIntent(item: "fi_2", change: .answer(.decision(allow: true, scope: "once")), idempotencyKey: "k")
        #expect(answer.feedIntent == .answer(itemID: "fi_2", reply: .permission(allow: true, scope: .once)))
    }

    @Test func aBannerTapEndsAsTheSameIntentTheFeedTabSends() throws {
        let info: [AnyHashable: Any] = ["aps": ["category": "FEED_APPROVE_SESSION"], "cmux": ["feed_item": "fi_3"]]
        guard case .perform(let intent) = FeedPushResponse(actionIdentifier: "FEED_ALLOW_SESSION", userText: nil, userInfo: info) else {
            Issue.record("expected perform"); return
        }
        let op = try OpsFeedIntentPerformer(ops: RecordingOps(), device: "iPhone").op(for: intent.feedIntent, key: intent.intentKey)
        let body = try JSONSerialization.jsonObject(with: op.body()) as? [String: Any]
        let params = body?["params"] as? [String: Any]
        #expect(body?["op"] as? String == "feed.answer")
        #expect(body?["origin"] as? String == "user")
        #expect(body?["idempotency_key"] as? String == "feed-push-fi_3-FEED_ALLOW_SESSION")
        #expect(params?["item"] as? String == "fi_3")
        #expect(params?["device"] as? String == "iPhone")
        let answer = params?["answer"] as? [String: Any]
        #expect(answer?["decision"] as? String == "allow")
        #expect(answer?["scope"] as? String == "session")
    }
}

@Suite struct OpsFeedIntentPerformerTests {
    @Test func committedWhenTheOwnerAccepts() async throws {
        let ops = RecordingOps()
        let receipt = try await OpsFeedIntentPerformer(ops: ops, device: nil).perform(.read(itemIDs: ["fi_1"]), key: IntentKey(rawValue: "k"))
        #expect(receipt == .committed(key: IntentKey(rawValue: "k"), revision: 0))
        let sent = await ops.sent
        #expect(sent.map(\.op) == ["feed.read"])
        #expect(sent.first?.params["items"] == .array([.string("fi_1")]))
    }

    @Test func aDomainRefusalIsARefusedReceipt() async throws {
        let ops = RecordingOps(failure: .rejected(code: "feed.closed", retryable: false))
        let receipt = try await OpsFeedIntentPerformer(ops: ops, device: nil)
            .perform(.answer(itemID: "fi_1", reply: .confirm(true)), key: IntentKey(rawValue: "k"))
        #expect(receipt == .refused(key: IntentKey(rawValue: "k"), reason: "feed.closed"))
        #expect(BannerActionOutcome(receipt: receipt) == .answeredElsewhere)
    }

    @Test func transportFailuresThrowSoTheUserHearsNotSent() async {
        let ops = RecordingOps(failure: .transport)
        await #expect(throws: CloudOpsError.self) {
            _ = try await OpsFeedIntentPerformer(ops: ops, device: nil).perform(.readAll, key: IntentKey())
        }
        let retryable = RecordingOps(failure: .rejected(code: "owner.unreachable", retryable: true))
        await #expect(throws: CloudOpsError.self) {
            _ = try await OpsFeedIntentPerformer(ops: retryable, device: nil).perform(.readAll, key: IntentKey())
        }
    }

    @Test func outcomesDecideTheBanner() {
        #expect(BannerActionOutcome(receipt: .committed(key: IntentKey(), revision: 3)).removesBanner)
        #expect(!BannerActionOutcome(receipt: .refused(key: IntentKey(), reason: "auth.forbidden")).removesBanner)
        #expect(!BannerActionOutcome(error: CloudOpsError.transport).removesBanner)
    }
}

@Suite struct FeedNotificationReconcilerTests {
    let now = Date(timeIntervalSince1970: 1_000)

    func item(_ id: String, kind: FeedItemKind = .question(FeedQuestion(question: "q")), state: FeedItemState = .open,
              read: Bool = false, archived: Bool = false) -> FeedItem {
        FeedItem(id: id, kind: kind, state: state, source: "agent", title: id, createdAt: now,
                 readAt: read ? now : nil, archivedAt: archived ? now : nil)
    }

    @Test func badgeIsOpenRequestsPlusUnreadNotices() {
        let items = [item("fi_open"), item("fi_answered", state: .answered),
                     item("fi_notice", kind: .done), item("fi_read", kind: .done, read: true)]
        #expect(FeedNotificationReconciler(items: items).badge == 2)
    }

    @Test func removesBannersOfItemsThatNoLongerNeedTheUser() {
        let items = [item("fi_open"), item("fi_answered", state: .answered), item("fi_notice", kind: .done),
                     item("fi_read", kind: .done, read: true), item("fi_archived", kind: .done, archived: true)]
        let delivered = ["fi_open", "fi_answered", "fi_notice", "fi_read", "fi_archived", "fi_gone", "cmux.feed.not-sent", "term-1"]
        #expect(FeedNotificationReconciler(items: items).staleIdentifiers(delivered: delivered)
            == ["fi_answered", "fi_read", "fi_archived", "fi_gone"])
    }
}
