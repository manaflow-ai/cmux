import CNBackend
import CNCore
import CNMockHost
@testable import CNTransport
@testable import CNTransportWebRTC
import Foundation
import Synchronization
import Testing

@Suite struct StreamRouterTests {
    @Test func closedIdsAreTombstonedAndDoNotCrowdOutNewStreams() async throws {
        let router = StreamRouter()
        for id in UInt32(1)...40 {
            _ = router.open(id)
            router.close(id)
            router.deliver(streamId: id, payload: Data([1]))  // late frame after close
        }
        #expect(router.pendingIds.isEmpty)
        router.deliver(streamId: 99, payload: Data([7]))
        var it = router.open(99).makeAsyncIterator()
        #expect(await it.next() == Data([7]))
    }

    @Test func pendingEntriesExpireAndOldestIsEvictedAtCapacity() async throws {
        let router = StreamRouter()
        let t0 = ContinuousClock.now
        for id in UInt32(1)...UInt32(StreamRouter.maxPendingStreams) {
            router.deliver(streamId: id, payload: Data([0]), now: t0)
        }
        // At capacity: the newest stream still gets buffered (oldest evicted).
        router.deliver(streamId: 500, payload: Data([5]), now: t0 + .milliseconds(1))
        #expect(router.pendingIds.contains(500))
        #expect(router.pendingIds.count == StreamRouter.maxPendingStreams)
        // After the TTL every stale entry is dropped.
        router.deliver(streamId: 600, payload: Data([6]), now: t0 + StreamRouter.pendingTTL + .seconds(1))
        #expect(router.pendingIds == [600])
    }

    @Test func detachRPCClosesStreamEvenWhenItFails() async throws {
        let (phone, server) = LoopbackTransport.makePair()
        let client = HostClient(transport: phone, defaultTimeout: .milliseconds(100))
        let stream = client.openStream(id: 3)
        _ = server
        try? await client.detachTerminal(streamId: 3)  // times out: no host
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == nil)
    }
}

/// A connector whose first connect blocks until released; later connects go
/// to the mock host.
final class GatedConnector: Connector {
    let host: MockHost
    let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let calls = Mutex(0)
    let staleTransport = Mutex<LoopbackTransport?>(nil)

    init(host: MockHost) { self.host = host }

    func connect(hostId: String) async throws -> any LinkTransport {
        let n = calls.withLock { $0 += 1; return $0 }
        if n == 1 {
            await withCheckedContinuation { c in gate.withLock { $0 = c } }
            let t = host.connectLoopback()
            staleTransport.withLock { $0 = t }
            return t
        }
        return host.connectLoopback()
    }

    func release() { gate.withLock { $0?.resume(); $0 = nil } }
    var isWaiting: Bool { gate.withLock { $0 != nil } }
}

/// Fails `host.hello` by answering with an error; records whether the
/// transport was closed.
final class HelloRejectingConnector: Connector {
    let closedCount = Mutex(0)
    func connect(hostId: String) async throws -> any LinkTransport {
        let (phone, server) = LoopbackTransport.makePair()
        let link = Link(transport: server)
        Task { [self] in
            for await event in link.events {
                switch event {
                case .message(.control, let data):
                    if let env = try? JSONDecoder().decode(ControlEnvelope.self, from: data), let id = env.id {
                        try? link.send(JSONEncoder().encode(ControlEnvelope.failure(id: id, error: RPCError(code: .unauthorized, message: "no"))), on: .control)
                    }
                case .closed: self.closedCount.withLock { $0 += 1 }
                default: break
                }
            }
        }
        return phone
    }
}

@Suite struct HostConnectionRaceTests {
    @MainActor func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("condition not met in time"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor @Test func staleRunDoesNotClobberNewSession() async throws {
        let host = MockHost(options: MockHost.Options(speed: 40))
        let connector = GatedConnector(host: host)
        let connection = HostConnection(connector: connector, clientInfo: testClient,
                                        backoff: ReconnectBackoff(initial: .milliseconds(20), maxAttempts: 3))
        connection.connect(hostId: MockHost.defaultHostId)
        try await waitUntil { connector.isWaiting }
        // Replace the run while the first one is still connecting.
        connection.connect(hostId: MockHost.defaultHostId)
        try await waitUntil { connection.state.isConnected }
        let live = try #require(connection.client)
        let generation = connection.generation
        connector.release()
        // The stale run gets its transport, notices it is superseded and closes it.
        try await waitUntil { connector.staleTransport.withLock { $0 } != nil }
        let stale = try #require(connector.staleTransport.withLock { $0 })
        var events = stale.events.makeAsyncIterator()
        while let e = await events.next() { if case .closed = e { break } }
        #expect(connection.client === live)
        #expect(connection.generation == generation)
        #expect(connection.state.isConnected)
        _ = try await live.ping()
        connection.disconnect()
    }

    @MainActor @Test func failedHelloClosesTransport() async throws {
        let connector = HelloRejectingConnector()
        let connection = HostConnection(connector: connector, clientInfo: testClient,
                                        backoff: ReconnectBackoff(initial: .milliseconds(5), maxAttempts: 2))
        connection.connect(hostId: "h")
        try await waitUntil { if case .failed = connection.state { true } else { false } }
        try await waitUntil { connector.closedCount.withLock { $0 } == 3 }
    }
}

@Suite struct EventHubTests {
    @Test func doesNotDropEventsUnderBurst() async throws {
        let hub = EventHub()
        let stream = hub.subscribe(topic: "agent.*")
        for i in 0..<10_000 { hub.publish(HostEvent(topic: "agent.item", raw: Data("\(i)".utf8))) }
        hub.finish()
        var n = 0
        for await _ in stream { n += 1 }
        #expect(n == 10_000)
    }
}

@Suite struct AuthTransportTests {
    @Test func signalingTokenMovesToAuthorizationHeader() {
        let r = SignalingClient.request(for: URL(string: "wss://w.example.dev/v1/signal?token=abc")!)
        #expect(r.url?.absoluteString == "wss://w.example.dev/v1/signal")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
    }

    @Test func pkceMatchesRFC7636Vector() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let fresh = PKCE()
        #expect(fresh.verifier.count == 43 && fresh.challenge.count == 43)
        let backend = BackendClient(configuration: BackendConfiguration(baseURL: URL(string: "https://w.example.dev")!), tokenStore: InMemoryTokenStore())
        let url = backend.oauthStartURL(provider: "github", redirect: "app://cb", pkce: p)
        #expect(url.query?.contains("code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM") == true)
    }

    @Test func cancelledPermissionIsRecognized() {
        var p = PermissionTranscriptItem(id: "p", toolCallId: "t", title: "x", options: [PermissionOption(id: "allow_once", name: "Allow", kind: .allowOnce)])
        #expect(!p.isCancelled)
        p.resolved = PermissionTranscriptItem.cancelledResolution
        #expect(p.isCancelled)
    }
}
