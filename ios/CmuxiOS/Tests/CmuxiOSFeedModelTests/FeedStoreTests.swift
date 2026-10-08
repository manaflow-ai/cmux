import CmuxiOSFeatureKit
import CmuxiOSFeedModel
import CmuxFeedPushCore
import Foundation
import Testing

actor KeyRecordingFeedSource: FeedSource {
    let hub = MockSnapshotHub<[FeedItem]>(MockFixtures.feedItems())
    private(set) var keys: [IntentKey] = []

    func updates() async -> AsyncStream<SourceSnapshot<[FeedItem]>> { await hub.stream() }

    func perform(_ intent: FeedIntent, key: IntentKey) async throws -> IntentReceipt {
        keys.append(key)
        return .committed(key: key, revision: await hub.current.revision)
    }
}

actor RefusingSeenFeedSource: FeedSource {
    let hub = MockSnapshotHub<[FeedItem]>(MockFixtures.feedItems())
    private(set) var seenCalls = 0

    func updates() async -> AsyncStream<SourceSnapshot<[FeedItem]>> { await hub.stream() }

    func perform(_ intent: FeedIntent, key: IntentKey) async throws -> IntentReceipt {
        if case .seen = intent {
            seenCalls += 1
            return .refused(key: key, reason: "feed.item_gone")
        }
        return .committed(key: key, revision: await hub.current.revision)
    }
}

private struct SeenTransportFailure: Error, Sendable {}

actor TransientSeenFeedSource: FeedSource {
    let hub = MockSnapshotHub<[FeedItem]>(MockFixtures.feedItems())
    private(set) var seenCalls = 0

    func updates() async -> AsyncStream<SourceSnapshot<[FeedItem]>> { await hub.stream() }

    func perform(_ intent: FeedIntent, key: IntentKey) async throws -> IntentReceipt {
        if case .seen = intent {
            seenCalls += 1
            if seenCalls == 1 { throw SeenTransportFailure() }
        }
        return .committed(key: key, revision: await hub.current.revision)
    }
}

@MainActor
@Suite struct FeedStoreTests {
    @Test func answerCommitsAndReportsTheOutcome() async {
        let source = MockFeedSource()
        let store = FeedStore(source: source, device: "iPhone")
        store.receive(await source.hub.current)
        var outcomes: [FeedIntentOutcome] = []
        store.onOutcome = { outcomes.append($0) }
        let reply = FeedReply.permission(allow: true, scope: .always)
        let outcome = await store.answer("feed1", reply)
        #expect(outcome == .committed(.answer(itemID: "feed1", reply: reply)))
        #expect(outcomes == [outcome])
        // The receipt's revision is not mirrored yet: the overlay still shows it.
        #expect(store.item("feed1")?.state == .answered)
        store.receive(await source.hub.current)
        #expect(store.state.pending.isEmpty)
        #expect(store.item("feed1")?.answer?.device == "iPhone")
    }

    @Test func secondAnswerIsRefusedAsClosedElsewhere() async {
        let source = MockFeedSource()
        _ = try? await source.perform(.answer(itemID: "feed1", reply: .permission(allow: false, scope: nil)), key: IntentKey())
        let store = FeedStore(source: source)
        store.receive(await source.hub.current)
        let outcome = await store.answer("feed1", .permission(allow: true, scope: nil))
        guard case .refused(_, _, let closedElsewhere) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(closedElsewhere)
        #expect(store.state.pending.isEmpty)
    }

    @Test func inAppAnswerUsesTheBannerStableKey() async {
        let source = KeyRecordingFeedSource()
        let store = FeedStore(source: source, device: "iPhone")
        store.receive(await source.hub.current)

        _ = await store.answer("feed1", .permission(allow: true, scope: nil))

        #expect(await source.keys == [IntentKey(rawValue: "feed-push-feed1-FEED_ALLOW")])
    }

    @Test func offlineSendsNothingAndQueuesNothing() async {
        let source = MockFeedSource()
        await source.hub.setConnection(.offline(reason: nil))
        let store = FeedStore(source: source)
        store.receive(await source.hub.current)
        let outcome = await store.send(.readAll)
        #expect(outcome == .notSent(.readAll, offline: true))
        #expect(store.state.pending.isEmpty)
        #expect(await source.hub.current.revision == 1)
    }

    @Test func choiceDraftBuildsTheAnswerAndClearsOnSend() async {
        let source = MockFeedSource()
        let store = FeedStore(source: source)
        store.receive(await source.hub.current)
        guard case .choice(let choice) = store.item("feed2")?.kind, let question = choice.questions.first else {
            Issue.record("fixture changed"); return
        }
        store.toggleChoice("feed2", question: question, option: "replace")
        #expect(choice.isComplete(store.choiceDraft("feed2")))
        store.setChoiceOther("feed2", question: question, text: "  ")
        #expect(store.choiceDraft("feed2")[question.id]?.selected == ["replace"])
        let outcome = await store.answer("feed2", .choice(store.choiceDraft("feed2")))
        guard case .committed = outcome else { Issue.record("got \(outcome)"); return }
        #expect(store.choiceDraft("feed2").isEmpty)
    }

    @Test func seenReportsAreBatchedOncePerTurnAndSilent() async {
        let source = MockFeedSource()
        let store = FeedStore(source: source)
        store.receive(await source.hub.current)
        var outcomes = 0
        store.onOutcome = { _ in outcomes += 1 }
        store.reportSeen(["feed1", "feed2"])
        store.reportSeen(["feed2", "feed3"])
        let start = await source.hub.current.revision
        for _ in 0..<20 where await source.hub.current.revision == start { await Task.yield() }
        let items = await source.hub.current.value
        #expect(await source.hub.current.revision == start + 1)
        #expect(Set(items.filter { $0.seenAt != nil }.map(\.id)) == ["feed1", "feed2", "feed3"])
        #expect(outcomes == 0)
    }

    @Test func refusedSeenReportsStaySuppressed() async {
        let source = RefusingSeenFeedSource()
        let store = FeedStore(source: source)
        store.receive(await source.hub.current)

        store.reportSeen(["feed1"])
        for _ in 0..<20 where await source.seenCalls == 0 { await Task.yield() }
        #expect(await source.seenCalls == 1)

        // A later visibility pass must not resend a permanently refused batch.
        store.reportSeen(["feed1"])
        for _ in 0..<20 { await Task.yield() }
        #expect(await source.seenCalls == 1)
    }

    @Test func refusedSeenBatchStillCommitsValidIds() async throws {
        let source = MockFeedSource()
        let store = FeedStore(source: source)
        store.receive(await source.hub.current)

        // Simulate a remote deletion after the phone's mirror was rendered.
        _ = try await source.hub.commit { items in
            items.removeAll { $0.id == "feed2" }
        }
        store.reportSeen(["feed1", "feed2"])

        for _ in 0..<100 {
            if await source.hub.current.value.first(where: { $0.id == "feed1" })?.seenAt != nil { break }
            await Task.yield()
        }
        #expect(await source.hub.current.value.first(where: { $0.id == "feed1" })?.seenAt != nil)
    }

    @Test func transportFailureReleasesSeenReportsForRetry() async {
        let source = TransientSeenFeedSource()
        let store = FeedStore(source: source)
        store.receive(await source.hub.current)

        store.reportSeen(["feed1"])
        for _ in 0..<20 where await source.seenCalls == 0 { await Task.yield() }
        #expect(await source.seenCalls == 1)

        // Keep rendering while the failed send settles; once released, the
        // next visibility pass should submit the id again.
        for _ in 0..<100 where await source.seenCalls < 2 {
            store.reportSeen(["feed1"])
            await Task.yield()
        }
        #expect(await source.seenCalls == 2)
    }
}
