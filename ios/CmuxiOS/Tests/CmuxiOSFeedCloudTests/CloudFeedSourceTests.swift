@testable import CmuxiOSFeedCloud
import CmuxiOSFeatureKit
import Foundation
import Testing

@Suite struct CloudFeedSourceTests {
    func makeSource(_ connections: [FakeFeedConnection]) -> (CloudFeedSource, FakeFeedTransport) {
        let transport = FakeFeedTransport(connections)
        let source = CloudFeedSource(apiBaseURL: URL(string: "https://api.example.test")!, device: "iPhone",
                                     clientVersion: "1.2", transport: transport, clock: ImmediateClock(),
                                     token: { "tok" })
        return (source, transport)
    }

    /// Waits for the next snapshot that satisfies `match`.
    func next(_ iterator: inout AsyncStream<SourceSnapshot<[FeedItem]>>.AsyncIterator,
              where match: (SourceSnapshot<[FeedItem]>) -> Bool) async -> SourceSnapshot<[FeedItem]>? {
        while let snapshot = await iterator.next() {
            if match(snapshot) { return snapshot }
        }
        return nil
    }

    func nextFrame(_ iterator: inout AsyncStream<[String: Any]>.AsyncIterator, t: String) async -> [String: Any]? {
        while let frame = await iterator.next() {
            if frame["t"] as? String == t { return frame }
        }
        return nil
    }

    @Test func connectsSubscribesAndMirrorsSnapshotAndEvents() async throws {
        let socket = FakeFeedConnection()
        let (source, transport) = makeSource([socket])
        var updates = await source.updates().makeAsyncIterator()
        var sent = socket.outbound.makeAsyncIterator()
        socket.push(OwnerJSON.welcome)
        let subscribe = try #require(await nextFrame(&sent, t: "subscribe"))
        #expect(subscribe["stream"] as? String == "feed:usr_1")
        socket.push(OwnerJSON.snapshot(seq: 4, items: [OwnerJSON.item("fi_1")]))
        let live = try #require(await next(&updates) { $0.connection.isLive })
        #expect(live.revision == 4)
        #expect(live.value.map(\.id) == ["fi_1"])
        socket.push(OwnerJSON.event(seq: 5, items: [OwnerJSON.item("fi_2")]))
        let after = try #require(await next(&updates) { $0.revision == 5 })
        #expect(Set(after.value.map(\.id)) == ["fi_1", "fi_2"])

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "wss://api.example.test/v1/wire/feed")
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.wire.v1, bearer.tok")
        #expect(request.value(forHTTPHeaderField: "x-cmux-client-version") == "1.2")
    }

    @Test func performSendsAnOpFrameAndReturnsAtTheSettle() async throws {
        let socket = FakeFeedConnection()
        let (source, _) = makeSource([socket])
        var updates = await source.updates().makeAsyncIterator()
        var sent = socket.outbound.makeAsyncIterator()
        socket.push(OwnerJSON.welcome)
        socket.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1")]))
        _ = await next(&updates) { $0.connection.isLive }

        let key = IntentKey(rawValue: "idem_1")
        async let receipt = source.perform(.answer(itemID: "fi_1", reply: .permission(allow: true, scope: .session)), key: key)
        let op = try #require(await nextFrame(&sent, t: "op"))
        #expect(op["op"] as? String == "feed.answer")
        #expect(op["origin"] as? String == "user")
        #expect((op["params"] as? NSDictionary) == ["item": "fi_1", "answer": ["decision": "allow", "scope": "session"], "device": "iPhone"])
        socket.push(OwnerJSON.event(seq: 2, items: [OwnerJSON.item("fi_1", state: "answered", revision: 2)]))
        socket.push(["t": "request-settled", "tx": "t", "idempotency_key": "idem_1", "stream": "feed:usr_1", "sequence": 2, "ok": true])
        #expect(try await receipt == .committed(key: key, revision: 2))
    }

    @Test func duplicateKeyCallersShareOneOwnerOperationAndReceipt() async throws {
        let socket = FakeFeedConnection()
        let (source, _) = makeSource([socket])
        var updates = await source.updates().makeAsyncIterator()
        var sent = socket.outbound.makeAsyncIterator()
        socket.push(OwnerJSON.welcome)
        socket.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1")]))
        _ = await next(&updates) { $0.connection.isLive }

        let key = IntentKey(rawValue: "idem_shared")
        let first = Task { try await source.perform(.read(itemIDs: ["fi_1"]), key: key) }
        _ = try #require(await nextFrame(&sent, t: "op"))
        let second = Task { try await source.perform(.read(itemIDs: ["fi_1"]), key: key) }
        while await source.waitingContinuationCount < 2 { await Task.yield() }

        socket.push(["t": "request-settled", "tx": "t", "idempotency_key": key.rawValue,
                     "stream": "feed:usr_1", "sequence": 2, "ok": true])
        let expected = IntentReceipt.committed(key: key, revision: 2)
        #expect(try await first.value == expected)
        #expect(try await second.value == expected)
        #expect(socket.sentFrameCount("op") == 1)
    }

    @Test func duplicateKeyWithDifferentFrameRefusesLocally() async throws {
        let socket = FakeFeedConnection()
        let (source, _) = makeSource([socket])
        var updates = await source.updates().makeAsyncIterator()
        var sent = socket.outbound.makeAsyncIterator()
        socket.push(OwnerJSON.welcome)
        socket.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1")]))
        _ = await next(&updates) { $0.connection.isLive }

        let key = IntentKey(rawValue: "idem_conflict")
        let first = Task { try await source.perform(.read(itemIDs: ["fi_1"]), key: key) }
        _ = try #require(await nextFrame(&sent, t: "op"))
        let second = Task { try await source.perform(.answer(itemID: "fi_1", reply: .confirm(true)), key: key) }
        var secondError: (any Error)?
        do { _ = try await second.value } catch { secondError = error }
        #expect(secondError as? FeatureSourceError == .unsupported("feed.idempotency-conflict"))

        socket.push(["t": "request-settled", "tx": "t", "idempotency_key": key.rawValue,
                     "stream": "feed:usr_1", "sequence": 2, "ok": true])
        #expect(try await first.value == .committed(key: key, revision: 2))
        #expect(socket.sentFrameCount("op") == 1)
    }

    @Test func rejectThenSettleIsARefusalWithTheCode() async throws {
        let socket = FakeFeedConnection()
        let (source, _) = makeSource([socket])
        var updates = await source.updates().makeAsyncIterator()
        var sent = socket.outbound.makeAsyncIterator()
        socket.push(OwnerJSON.welcome)
        socket.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1", state: "answered")]))
        _ = await next(&updates) { $0.connection.isLive }
        let key = IntentKey(rawValue: "idem_2")
        async let receipt = source.perform(.decline(itemID: "fi_1"), key: key)
        _ = await nextFrame(&sent, t: "op")
        socket.push(["t": "reject", "tx": "t", "idempotency_key": "idem_2", "code": "feed.closed", "message": "closed", "retryable": false, "replayed": false])
        socket.push(["t": "request-settled", "tx": "t", "idempotency_key": "idem_2", "stream": "feed:usr_1", "sequence": 0, "ok": false])
        #expect(try await receipt == .refused(key: key, reason: "feed.closed: closed"))
    }

    @Test func revisionGapRequestsASnapshotAndIgnoresEventsUntilThen() async throws {
        let socket = FakeFeedConnection()
        let (source, _) = makeSource([socket])
        var updates = await source.updates().makeAsyncIterator()
        var sent = socket.outbound.makeAsyncIterator()
        socket.push(OwnerJSON.welcome)
        _ = await nextFrame(&sent, t: "subscribe")
        socket.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1")]))
        _ = await next(&updates) { $0.connection.isLive }
        socket.push(OwnerJSON.event(seq: 3, items: [OwnerJSON.item("fi_3")]))
        let request = try #require(await nextFrame(&sent, t: "snapshot.request"))
        #expect(request["stream"] as? String == "feed:usr_1")
        socket.push(OwnerJSON.event(seq: 4, items: [OwnerJSON.item("fi_4")]))
        socket.push(OwnerJSON.snapshot(seq: 4, items: [OwnerJSON.item("fi_1"), OwnerJSON.item("fi_3"), OwnerJSON.item("fi_4")]))
        let repaired = try #require(await next(&updates) { $0.revision == 4 })
        #expect(Set(repaired.value.map(\.id)) == ["fi_1", "fi_3", "fi_4"])
    }

    @Test func dropGoesOfflineAndPerformRefusesToQueue() async throws {
        let first = FakeFeedConnection()
        let (source, _) = makeSource([first])
        var updates = await source.updates().makeAsyncIterator()
        first.push(OwnerJSON.welcome)
        first.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1")]))
        _ = await next(&updates) { $0.connection.isLive }
        first.drop()
        _ = await next(&updates) { if case .offline = $0.connection { true } else { false } }
        await #expect(throws: FeatureSourceError.offline) {
            try await source.perform(.readAll, key: IntentKey())
        }
    }

    @Test func reconnectSettlesDecidedKeysAndResendsTheRest() async throws {
        let first = FakeFeedConnection(), second = FakeFeedConnection()
        let (source, _) = makeSource([first, second])
        var updates = await source.updates().makeAsyncIterator()
        var sentFirst = first.outbound.makeAsyncIterator()
        first.push(OwnerJSON.welcome)
        first.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1"), OwnerJSON.item("fi_2")]))
        _ = await next(&updates) { $0.connection.isLive }

        let decided = IntentKey(rawValue: "idem_a"), undecided = IntentKey(rawValue: "idem_b")
        async let a = source.perform(.answer(itemID: "fi_1", reply: .permission(allow: false, scope: nil)), key: decided)
        _ = await nextFrame(&sentFirst, t: "op")
        async let b = source.perform(.read(itemIDs: ["fi_2"]), key: undecided)
        _ = await nextFrame(&sentFirst, t: "op")
        first.drop()

        var sentSecond = second.outbound.makeAsyncIterator()
        second.push(OwnerJSON.welcome)
        let subscribe = try #require(await nextFrame(&sentSecond, t: "subscribe"))
        #expect(subscribe["pending"] as? [String] == ["idem_a", "idem_b"])
        second.push(OwnerJSON.snapshot(seq: 3, items: [OwnerJSON.item("fi_1", state: "answered"), OwnerJSON.item("fi_2")],
                                       decided: [["idempotency_key": "idem_a", "ok": true, "sequence": 2]]))
        #expect(try await a == .committed(key: decided, revision: 2))
        let resent = try #require(await nextFrame(&sentSecond, t: "op"))
        #expect(resent["idempotency_key"] as? String == "idem_b")
        second.push(["t": "request-settled", "tx": "t", "idempotency_key": "idem_b", "stream": "feed:usr_1", "sequence": 4, "ok": true])
        #expect(try await b == .committed(key: undecided, revision: 4))
    }

    @Test func duplicateKeyCallerDuringReconnectJoinsThePendingOperation() async throws {
        let first = FakeFeedConnection(), reconnected = FakeFeedConnection()
        let transport = FakeFeedTransport([first, reconnected])
        let source = CloudFeedSource(apiBaseURL: URL(string: "https://api.example.test")!, device: "iPhone",
                                     clientVersion: "1.2", transport: transport, clock: ImmediateClock(),
                                     token: { "tok" })
        var updates = await source.updates().makeAsyncIterator()
        var sentFirst = first.outbound.makeAsyncIterator()
        first.push(OwnerJSON.welcome)
        first.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1")]))
        _ = await next(&updates) { $0.connection.isLive }

        let key = IntentKey(rawValue: "idem_reconnect_shared")
        let original = Task { try await source.perform(.read(itemIDs: ["fi_1"]), key: key) }
        _ = try #require(await nextFrame(&sentFirst, t: "op"))
        first.drop()
        while await transport.requests.count < 2 { await Task.yield() }

        // The replacement socket is connected but has not sent welcome yet,
        // so the source is still `.connecting`. A retry with the same key
        // must join the in-flight operation instead of throwing offline.
        let retry = Task { try await source.perform(.read(itemIDs: ["fi_1"]), key: key) }
        while await source.waitingContinuationCount < 2 { await Task.yield() }

        var sentReconnected = reconnected.outbound.makeAsyncIterator()
        reconnected.push(OwnerJSON.welcome)
        _ = try #require(await nextFrame(&sentReconnected, t: "subscribe"))
        reconnected.push(OwnerJSON.snapshot(seq: 2, items: [OwnerJSON.item("fi_1")]))
        _ = await next(&updates) { $0.connection.isLive }
        _ = try #require(await nextFrame(&sentReconnected, t: "op"))
        reconnected.push(["t": "request-settled", "tx": "t", "idempotency_key": key.rawValue,
                          "stream": "feed:usr_1", "sequence": 3, "ok": true])

        let expected = IntentReceipt.committed(key: key, revision: 3)
        #expect(try await original.value == expected)
        #expect(try await retry.value == expected)
        #expect(reconnected.sentFrameCount("op") == 1)
    }

    @Test func gateErrorOnAnOpRefusesItAndOnASnapshotRequestReconnects() async throws {
        let first = FakeFeedConnection(), second = FakeFeedConnection()
        let (source, transport) = makeSource([first, second])
        var updates = await source.updates().makeAsyncIterator()
        var sent = first.outbound.makeAsyncIterator()
        first.push(OwnerJSON.welcome)
        first.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1")]))
        _ = await next(&updates) { $0.connection.isLive }

        let key = IntentKey(rawValue: "idem_e")
        async let receipt = source.perform(.decline(itemID: "fi_1"), key: key)
        _ = await nextFrame(&sent, t: "op")
        first.push(["t": "error", "code": "owner.unreachable", "message": "install check failed", "idempotency_key": "idem_e"])
        #expect(try await receipt == .refused(key: key, reason: "owner.unreachable: install check failed"))

        first.push(OwnerJSON.event(seq: 3, items: []))
        _ = await nextFrame(&sent, t: "snapshot.request")
        first.push(["t": "error", "code": "owner.unreachable", "message": ""])
        _ = await next(&updates) { if case .offline = $0.connection { true } else { false } }
        second.push(OwnerJSON.welcome)
        second.push(OwnerJSON.snapshot(seq: 3, items: [OwnerJSON.item("fi_1")]))
        let back = try #require(await next(&updates) { $0.connection.isLive })
        #expect(back.revision == 3)
        #expect(await transport.requests.count == 2)
    }

    @Test func leavingTheScreenKeepsTheSocketUntilPendingIntentsSettle() async throws {
        let socket = FakeFeedConnection()
        let (source, _) = makeSource([socket])
        var sent = socket.outbound.makeAsyncIterator()
        let key = IntentKey(rawValue: "idem_s")
        let task: Task<IntentReceipt, any Error>
        do {
            var updates = await source.updates().makeAsyncIterator()
            socket.push(OwnerJSON.welcome)
            socket.push(OwnerJSON.snapshot(seq: 1, items: [OwnerJSON.item("fi_1")]))
            _ = await next(&updates) { $0.connection.isLive }
            task = Task { try await source.perform(.read(itemIDs: ["fi_1"]), key: key) }
            _ = await nextFrame(&sent, t: "op")
        }
        // The screen went away (its stream ended) before the settle arrived.
        for _ in 0..<1000 where await source.subscriberCount > 0 { await Task.yield() }
        #expect(await source.subscriberCount == 0)
        socket.push(["t": "request-settled", "tx": "t", "idempotency_key": "idem_s", "stream": "feed:usr_1", "sequence": 2, "ok": true])
        #expect(try await task.value == .committed(key: key, revision: 2))
    }
}
