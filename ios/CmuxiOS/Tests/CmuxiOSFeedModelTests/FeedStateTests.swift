import CmuxiOSFeatureKit
import CmuxiOSFeedModel
import Foundation
import Testing

@Suite struct FeedStateTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func snapshot(_ revision: UInt64, _ items: [FeedItem], live: Bool = true) -> SourceSnapshot<[FeedItem]> {
        SourceSnapshot(revision: revision, value: items, connection: live ? .live(path: "test") : .offline(reason: nil))
    }

    @Test func pendingAnswerOverlaysUntilTheMirrorReachesItsRevision() {
        var state = FeedState()
        state.receive(snapshot(5, MockFixtures.feedItems(now: now)))
        let key = IntentKey()
        state.enqueue(FeedPendingIntent(key: key, intent: .answer(itemID: "feed1", reply: .permission(allow: true, scope: .once)), at: now))
        #expect(state.visibleItems(device: "iPhone").first { $0.id == "feed1" }?.state == .answered)
        #expect(state.isPending("feed1"))

        // Committed at 7: still pending while the mirror is at 5 or 6.
        state.settle(.committed(key: key, revision: 7))
        state.receive(snapshot(6, MockFixtures.feedItems(now: now)))
        #expect(state.pending.count == 1)
        #expect(state.visibleItems(device: nil).first { $0.id == "feed1" }?.answer?.reply == .permission(allow: true, scope: .once))

        // The owner's echo at 7 retires it; the visible feed is the mirror.
        var answered = MockFixtures.feedItems(now: now)
        answered[0].state = .answered
        state.receive(snapshot(7, answered))
        #expect(state.pending.isEmpty)
        #expect(state.visibleItems(device: nil) == answered)
    }

    @Test func refusalAndNotSentLeaveTheLogAtOnce() {
        var state = FeedState()
        state.receive(snapshot(1, MockFixtures.feedItems(now: now)))
        let refused = IntentKey(), lost = IntentKey()
        state.enqueue(FeedPendingIntent(key: refused, intent: .decline(itemID: "feed1"), at: now))
        state.enqueue(FeedPendingIntent(key: lost, intent: .read(itemIDs: ["feed2"]), at: now))
        state.settle(.refused(key: refused, reason: "feed.closed"))
        state.drop(lost)
        #expect(state.pending.isEmpty)
        #expect(state.visibleItems(device: nil) == MockFixtures.feedItems(now: now))
    }

    @Test func answerDoesNotReopenARequestClosedElsewhere() {
        var items = MockFixtures.feedItems(now: now)
        items[0].state = .cancelled
        items[0].cancelReason = .answeredElsewhere
        var state = FeedState()
        state.receive(snapshot(2, items))
        state.enqueue(FeedPendingIntent(key: IntentKey(), intent: .answer(itemID: "feed1", reply: .permission(allow: true, scope: nil)), at: now))
        let item = state.visibleItems(device: nil).first { $0.id == "feed1" }
        #expect(item?.state == .cancelled)
        #expect(item?.answer == nil)
    }

    @Test func archiveSkipsOpenRequestsAndReadAllReadsEverything() {
        var items = MockFixtures.feedItems(now: now)
        FeedIntent.archive(itemIDs: ["feed1", "feed4"]).apply(to: &items, at: now, device: nil)
        #expect(items.first { $0.id == "feed1" }?.isArchived == false)
        #expect(items.first { $0.id == "feed4" }?.isArchived == true)
        FeedIntent.readAll.apply(to: &items, at: now, device: nil)
        #expect(items.allSatisfy { $0.isRead })
    }

    @Test func commitWithoutEventsRetiresImmediately() {
        var state = FeedState()
        state.receive(snapshot(3, MockFixtures.feedItems(now: now)))
        let key = IntentKey()
        state.enqueue(FeedPendingIntent(key: key, intent: .seen(itemIDs: ["feed1"]), at: now))
        state.settle(.committed(key: key, revision: 0))
        #expect(state.pending.isEmpty)
    }
}
