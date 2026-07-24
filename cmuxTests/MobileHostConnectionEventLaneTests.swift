import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import Foundation
@preconcurrency import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension MobileHostAuthorizationTests {
    @Test func testMobileHostConnectionClosesWhenFirstFrameTimesOut() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            firstFrameTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )
        await session.debugStartFirstFrameTimeoutForTesting()
        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let finalRecordedIDs = await recorder.recordedIDs()
        #expect(finalRecordedIDs == [connectionID])
    }
    @Test func testMobileHostConnectionClosesWhenIdleAfterFirstFrame() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            idleTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )
        await session.debugStartIdleTimeoutAfterFrameForTesting()
        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let finalRecordedIDs = await recorder.recordedIDs()
        #expect(finalRecordedIDs == [connectionID])
    }
    @Test func testMobileHostConnectionKeepsSubscribedEventStreamPastIdleTimeout() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            idleTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )
        await session.subscribe(streamID: "events", topics: ["terminal.updated"])
        await session.debugStartIdleTimeoutAfterFrameForTesting()
        // An active subscription suppresses the idle-after-frame timeout: the
        // arm path early-returns without scheduling any close. Awaiting an
        // actor-isolated round-trip on the connection guarantees the arm call
        // was fully processed and that the connection is still alive and
        // subscribed, so the recorder reflects the final state with no
        // wall-clock window to race.
        #expect(await session.isSubscribed(to: "terminal.updated"))
        let subscribedCloseIDs = await recorder.recordedIDs()
        #expect(subscribedCloseIDs.isEmpty)
        _ = await session.unsubscribe(streamID: "events")
        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let finalRecordedIDs = await recorder.recordedIDs()
        #expect(finalRecordedIDs == [connectionID])
    }

    @Test func testDeadIndependentEventLaneFallsBackCurrentAndFutureEventsToControl() async throws {
        let control = RecordingMobileHostByteTransport()
        let independent = TestMobileHostIndependentEventWriter(
            behavior: .failAfterProbe
        )
        let session = MobileHostConnection(
            id: UUID(),
            transport: control,
            independentEventWriter: independent,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        let result = await session.debugHandleSubscriptionRPCForTesting(
            MobileHostRPCRequest(
                id: "subscribe",
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": "events",
                    "topics": ["terminal.updated"],
                    "event_transport": "iroh_server_events_v1",
                ],
                auth: nil
            )
        )
        guard case let .ok(payload)? = result else {
            Issue.record("Expected successful independent subscription")
            return
        }
        let acknowledgement = try #require(payload as? [String: Any])
        #expect(
            acknowledgement["event_transport"] as? String
                == "iroh_server_events_v1"
        )

        #expect(
            await session.sendEvent(
                topic: "terminal.updated",
                payload: ["seq": 1]
            )
        )
        let sent = await control.waitForSentBufferCount(1)
        var framed = try #require(sent.first)
        let eventPayload = try #require(
            MobileSyncFrameCodec.decodeFrames(from: &framed).first
        )
        let event = try #require(
            JSONSerialization.jsonObject(with: eventPayload) as? [String: Any]
        )
        #expect(event["kind"] as? String == "event")
        #expect(event["topic"] as? String == "terminal.updated")
        #expect(
            await session.debugEventTransportForTesting(streamID: "events")
                == .control
        )

        #expect(
            await session.sendEvent(
                topic: "terminal.updated",
                payload: ["seq": 2]
            )
        )
        #expect(await control.waitForSentBufferCount(2).count == 2)
        #expect(await independent.observedSendCount() == 2)
        await session.close(reason: "test complete")
    }

    @Test func testIndependentEventBackpressureClosesAtBoundedQueueCapacity() async throws {
        let control = RecordingMobileHostByteTransport()
        let independent = TestMobileHostIndependentEventWriter(
            behavior: .blockAfterProbe
        )
        var blocked = await independent.blockedEvents().makeAsyncIterator()
        let session = MobileHostConnection(
            id: UUID(),
            transport: control,
            independentEventWriter: independent,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        _ = await session.debugHandleSubscriptionRPCForTesting(
            MobileHostRPCRequest(
                id: "subscribe",
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": "events",
                    "topics": ["terminal.updated"],
                    "event_transport": "iroh_server_events_v1",
                ],
                auth: nil
            )
        )

        #expect(
            await session.sendEvent(
                topic: "terminal.updated",
                payload: ["seq": 0]
            )
        )
        _ = await blocked.next()

        for sequence in 1...256 {
            #expect(
                await session.sendEvent(
                    topic: "terminal.updated",
                    payload: ["seq": sequence]
                )
            )
        }
        #expect(
            !(await session.sendEvent(
                topic: "terminal.updated",
                payload: ["seq": 257]
            ))
        )

        #expect(await control.observedCloseCount() == 1)
        #expect(await independent.observedCloseCount() == 1)
        #expect(await session.debugQueuedEventCountForTesting() == 0)
    }

    @Test func testIdempotentSubscriptionDoesNotReprobeHealthyIndependentLane() async throws {
        let control = RecordingMobileHostByteTransport()
        let independent = TestMobileHostIndependentEventWriter(
            behavior: .failAfterProbe
        )
        let session = MobileHostConnection(
            id: UUID(),
            transport: control,
            independentEventWriter: independent,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        let subscribe = MobileHostRPCRequest(
            id: "subscribe",
            method: "mobile.events.subscribe",
            params: [
                "stream_id": "events",
                "topics": ["terminal.updated"],
                "event_transport": "iroh_server_events_v1",
            ],
            auth: nil
        )
        _ = await session.debugHandleSubscriptionRPCForTesting(subscribe)
        guard case let .ok(payload)? = await session.debugHandleSubscriptionRPCForTesting(subscribe) else {
            Issue.record("Expected an idempotent subscribe response")
            return
        }
        let acknowledgement = try #require(payload as? [String: Any])
        #expect(acknowledgement["already_subscribed"] as? Bool == true)
        #expect(
            acknowledgement["event_transport"] as? String
                == "iroh_server_events_v1"
        )
        #expect(
            await session.debugEventTransportForTesting(streamID: "events")
                == .irohServerEvents
        )
        // A re-assertion is a control-channel liveness proof. Re-probing the
        // optional Iroh event lane can consume two 3-second host deadlines and
        // make a healthy phone tear down its control session.
        #expect(await independent.observedSendCount() == 1)
        await session.close(reason: "test complete")
    }

    // MARK: - Bounded emission under a stalled subscriber (issue #8842)

    /// A stalled, never-draining render-grid subscriber must not force the host
    /// to tear the connection down when the bounded event queue fills: dropped
    /// render-grid deltas are recoverable (the producer re-emits a full frame),
    /// while close-on-overflow churns connection resources (sockets, lanes,
    /// tasks) every few seconds for as long as the subscriber stays slow —
    /// the reconnect-churn half of the issue #8842 field incident.
    @Test func testStalledRenderGridSubscriberStaysOpenWithBoundedEventQueue() async throws {
        let transport = StalledSendMobileHostByteTransport()
        let session = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        await session.subscribe(streamID: "events", topics: ["terminal.render_grid"])

        // Sustained synthetic emission far past the bounded queue capacity
        // while the transport never completes a single send.
        for sequence in 0..<768 {
            _ = await session.sendEvent(
                topic: "terminal.render_grid",
                payload: [
                    "surface_id": "surface-8842",
                    "full": false,
                    "state_seq": sequence,
                ]
            )
        }

        // The connection survives the overflow (no teardown churn) and the
        // pending event queue stays bounded no matter how far emission ran
        // ahead of the stalled writer.
        #expect(await transport.observedCloseCount() == 0)
        #expect(await session.debugQueuedEventCountForTesting() <= 256)
        #expect(await session.isSubscribed(to: "terminal.render_grid"))

        await session.close(reason: "test cleanup")
        #expect(await transport.observedCloseCount() == 1)
    }

    /// Events that cannot be re-derived by the client (state-sync deltas and
    /// other non-refresh topics) must keep the close-on-overflow contract: the
    /// host may never silently drop them, so a subscriber that stops draining
    /// is torn down at the bounded capacity instead of growing without bound.
    @Test func testStalledSubscriberOverflowOnNonRecoverableTopicClosesConnection() async throws {
        let transport = StalledSendMobileHostByteTransport()
        let session = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        await session.subscribe(streamID: "events", topics: ["mobile.sync.delta"])

        var admitted = 0
        for sequence in 0..<300 {
            if await session.sendEvent(
                topic: "mobile.sync.delta",
                payload: ["revision": sequence]
            ) {
                admitted += 1
            }
        }

        #expect(await transport.observedCloseCount() == 1)
        #expect(admitted <= 258)
        #expect(await session.debugQueuedEventCountForTesting() == 0)
    }

    /// After close, every per-connection resource must be released: the
    /// connection actor and its transport deallocate even when a send was
    /// stalled mid-flight at close time, so a churned subscriber cannot strand
    /// tasks, buffers, or transport resources on the host.
    @Test func testCloseReleasesConnectionAndTransportResources() async throws {
        var transport: StalledSendMobileHostByteTransport? = StalledSendMobileHostByteTransport()
        weak var weakTransport = transport
        var session: MobileHostConnection? = MobileHostConnection(
            id: UUID(),
            transport: transport!,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        weak var weakSession = session

        await session!.subscribe(streamID: "events", topics: ["terminal.render_grid"])
        for sequence in 0..<8 {
            _ = await session!.sendEvent(
                topic: "terminal.render_grid",
                payload: [
                    "surface_id": "surface-8842-release",
                    "full": false,
                    "state_seq": sequence,
                ]
            )
        }
        await transport!.waitUntilSendStalled()
        await session!.close(reason: "release test")
        #expect(await session!.debugQueuedEventCountForTesting() == 0)

        session = nil
        transport = nil
        for _ in 0..<2_000 {
            if weakSession == nil, weakTransport == nil { break }
            await Task.yield()
        }
        #expect(weakSession == nil)
        #expect(weakTransport == nil)
    }

    @Test func testIdempotentReassertionCannotReenableALaneWithAnInFlightFailure() async throws {
        let control = RecordingMobileHostByteTransport()
        let independent = TestMobileHostIndependentEventWriter(
            behavior: .blockAfterProbe
        )
        var eventBlocked = await independent.blockedEvents().makeAsyncIterator()
        let session = MobileHostConnection(
            id: UUID(),
            transport: control,
            independentEventWriter: independent,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        let subscribe = MobileHostRPCRequest(
            id: "subscribe",
            method: "mobile.events.subscribe",
            params: [
                "stream_id": "events",
                "topics": ["terminal.updated"],
                "event_transport": "iroh_server_events_v1",
            ],
            auth: nil
        )
        _ = await session.debugHandleSubscriptionRPCForTesting(subscribe)
        #expect(
            await session.sendEvent(
                topic: "terminal.updated",
                payload: ["seq": 1]
            )
        )
        _ = await eventBlocked.next()

        guard case let .ok(reassertionPayload)? = await session.debugHandleSubscriptionRPCForTesting(subscribe) else {
            Issue.record("Expected an idempotent subscribe response")
            return
        }
        let reassertion = try #require(reassertionPayload as? [String: Any])
        #expect(
            reassertion["event_transport"] as? String
                == "iroh_server_events_v1"
        )
        await independent.failBlockedSend()
        for _ in 0..<1_000 {
            if await session.debugEventTransportForTesting(streamID: "events") == .control {
                break
            }
            await Task.yield()
        }
        #expect(
            await session.debugEventTransportForTesting(streamID: "events")
                == .control
        )
        #expect(await control.waitForSentBufferCount(1).count == 1)
        await session.close(reason: "test complete")
    }

}

/// A byte transport whose `send` never completes on its own: it models a
/// subscriber that stopped draining (paused phone, dead network path with the
/// socket still open). `close()` fails every stalled send so teardown paths
/// stay deterministic and no task is stranded across tests.
actor StalledSendMobileHostByteTransport: CmxByteTransport {
    private enum StalledSendError: Error {
        case closed
    }

    private var sendWaiters: [CheckedContinuation<Void, any Error>] = []
    private var sendStalledWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeCount = 0
    private var isClosed = false

    func connect() async throws {}

    func receive() async throws -> Data? { nil }

    func send(_: Data) async throws {
        guard !isClosed else {
            throw StalledSendError.closed
        }
        let stalled = sendStalledWaiters
        sendStalledWaiters.removeAll()
        for waiter in stalled {
            waiter.resume()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sendWaiters.append(continuation)
            }
        } onCancel: {
            Task { await self.failStalledSends() }
        }
    }

    func close() async {
        closeCount += 1
        isClosed = true
        failStalledSends()
    }

    /// Waits until at least one send has parked on the stalled transport.
    func waitUntilSendStalled() async {
        if !sendWaiters.isEmpty { return }
        await withCheckedContinuation { continuation in
            sendStalledWaiters.append(continuation)
        }
    }

    func observedCloseCount() -> Int { closeCount }

    private func failStalledSends() {
        let waiters = sendWaiters
        sendWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: StalledSendError.closed)
        }
    }
}
