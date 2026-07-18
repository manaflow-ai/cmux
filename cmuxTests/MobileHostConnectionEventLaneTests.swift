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
