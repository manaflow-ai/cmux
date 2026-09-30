import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileHost
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// One terminal's render-grid output must never wait behind another
/// terminal's output on the phone connection (QUIC head-of-line blocking).
@Suite(.serialized)
struct MobileHostSurfaceEventLaneTests {
    @Test func stalledSurfaceOutputDoesNotDelayAnotherSurfacesRenderGrid() async throws {
        let control = RecordingMobileHostByteTransport()
        let writer = SurfaceGatedIndependentEventWriter(stalledSurfaceID: "surface-a")
        let session = MobileHostConnection(
            id: UUID(),
            transport: control,
            independentEventWriter: writer,
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
                    "topics": ["terminal.render_grid"],
                    "event_transport": "iroh_server_events_v1",
                    "surface_event_lanes": "v1",
                ],
                auth: nil
            )
        )

        // The user is looking at surface B, so it owns the one dedicated
        // stream. Surface A's background replay remains on the shared lane.
        await session.noteInteractiveSurface("surface-b")
        #expect(await session.sendEvent(
            topic: "terminal.render_grid",
            payload: ["surface_id": "surface-a", "full": true, "rows": ["replay"]]
        ))
        #expect(await writer.waitUntilStalled())

        // The user types on surface B. Its echo must reach the wire now, not
        // after surface A's replay drains.
        #expect(await session.sendEvent(
            topic: "terminal.render_grid",
            payload: ["surface_id": "surface-b", "full": true, "rows": ["echo"]]
        ))
        let delivered = await writer.waitForDeliveredSurface("surface-b")
        #expect(delivered, "surface-b's render grid waited behind surface-a's stalled write")

        await session.close(reason: "test complete")
    }

    @Test func hostGrantsSurfaceLanesOnlyWhenThePhoneAsksForThem() async throws {
        for asks in [false, true] {
            let writer = RecordingSurfaceLaneEventWriter()
            let session = MobileHostConnection(
                id: UUID(),
                transport: RecordingMobileHostByteTransport(),
                independentEventWriter: writer,
                authorizeRequest: { _ in nil },
                onAuthorizedRequest: { _ in },
                handleRequest: { _ in .ok([:]) },
                onClose: { _ in }
            )
            var params: [String: Any] = [
                "stream_id": "events",
                "topics": ["terminal.render_grid"],
                "event_transport": "iroh_server_events_v1",
            ]
            if asks { params["surface_event_lanes"] = "v1" }
            let result = await session.debugHandleSubscriptionRPCForTesting(
                MobileHostRPCRequest(id: "s", method: "mobile.events.subscribe", params: params, auth: nil)
            )
            guard case let .ok(payload)? = result,
                  let acknowledgement = payload as? [String: Any] else {
                Issue.record("Expected a subscribe acknowledgement")
                return
            }
            // An older phone reads exactly one events stream, so it must never
            // be sent a second one.
            #expect((acknowledgement["surface_event_lanes"] as? String) == (asks ? "v1" : nil))

            if asks {
                await session.noteInteractiveSurface("surface-a")
            }
            #expect(await session.sendEvent(
                topic: "terminal.render_grid",
                payload: ["surface_id": "surface-a", "full": true]
            ))
            #expect(await writer.waitForWrites(1))
            #expect(await writer.writes() == [asks ? .surface("surface-a", generation: 0) : .shared])
            await session.close(reason: "test complete")
        }
    }

    @Test func failedSurfaceLaneRecoversOnAFreshStreamWithoutClosingTheConnection() async throws {
        let writer = RecordingSurfaceLaneEventWriter(failFirstSurfaceWrite: true)
        let recorder = MobileHostConnectionCloseRecorder()
        let session = MobileHostConnection(
            id: UUID(),
            transport: RecordingMobileHostByteTransport(),
            independentEventWriter: writer,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in await recorder.record(id) }
        )
        _ = await session.debugHandleSubscriptionRPCForTesting(
            MobileHostRPCRequest(
                id: "s",
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": "events",
                    "topics": ["terminal.render_grid"],
                    "event_transport": "iroh_server_events_v1",
                    "surface_event_lanes": "v1",
                ],
                auth: nil
            )
        )
        await session.noteInteractiveSurface("surface-a")
        #expect(await session.sendEvent(
            topic: "terminal.render_grid",
            payload: ["surface_id": "surface-a", "full": true]
        ))
        #expect(await writer.waitForWrites(1))
        for _ in 0..<2_000 where session.eventQueue.surfaceLaneGeneration(surfaceID: "surface-a") == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(session.eventQueue.surfaceLaneGeneration(surfaceID: "surface-a") == 1)
        // The lost frame broke the chain: deltas are refused until the
        // producer's full-frame resync, which rides a new stream generation.
        #expect(await !session.sendEvent(
            topic: "terminal.render_grid",
            payload: ["surface_id": "surface-a", "full": false]
        ))
        #expect(await session.sendEvent(
            topic: "terminal.render_grid",
            payload: ["surface_id": "surface-a", "full": true]
        ))
        #expect(await writer.waitForWrites(2))
        #expect(await writer.writes() == [
            .surface("surface-a", generation: 0),
            .surface("surface-a", generation: 1),
        ])
        #expect(await recorder.recordedIDs().isEmpty)
        await session.close(reason: "test complete")
    }

    @Test func staleFocusContinuationCannotReprioritizeAfterANewerFocus() async throws {
        let writer = FocusOrderingIndependentEventWriter()
        let session = MobileHostConnection(
            id: UUID(),
            transport: RecordingMobileHostByteTransport(),
            independentEventWriter: writer,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        _ = await session.debugHandleSubscriptionRPCForTesting(
            MobileHostRPCRequest(
                id: "s",
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": "events",
                    "topics": ["terminal.render_grid"],
                    "event_transport": "iroh_server_events_v1",
                    "surface_event_lanes": "v1",
                ],
                auth: nil
            )
        )
        await session.noteInteractiveSurface("surface-x")
        #expect(await session.sendEvent(
            topic: "terminal.render_grid",
            payload: ["surface_id": "surface-x", "full": true]
        ))

        let first = Task { await session.noteInteractiveSurface("surface-a") }
        await writer.waitForReleaseStart()
        let second = Task { await session.noteInteractiveSurface("surface-b") }
        await writer.waitForNote("surface-b")
        await writer.releaseBlockedOperation()
        await first.value
        await second.value

        #expect(await writer.notes() == ["surface-x", "surface-b"])
        await session.close(reason: "test complete")
    }

    @Test func surfaceLaneFallbackToControlRebasesEachSurfaceWithAFullFrame() {
        let queue = MobileHostConnectionEventQueue()
        queue.updateSubscribedTopics(["terminal.render_grid"])
        queue.enableSurfaceLanes(limit: 4)
        _ = queue.focusSurfaceLane("s")
        let full = queue.enqueue(
            topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: true, frame: Data([1])
        )
        #expect(full.drainLane == .surface("s"))
        let delta = queue.enqueue(
            topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: false, frame: Data([2])
        )
        #expect(delta.admitted)

        // Falling back drops the frames still queued for the surface stream
        // and poisons the surface until a full frame on the shared lane.
        #expect(queue.disableSurfaceLanes() == ["s"])
        #expect(queue.count == 0)
        let staleDelta = queue.enqueue(
            topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: false, frame: Data([3])
        )
        #expect(!staleDelta.admitted)
        let rebase = queue.enqueue(
            topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: true, frame: Data([4])
        )
        #expect(rebase.admitted)
        #expect(rebase.drainLane == .shared)
    }

    @Test func deltaCrossingOntoANewStreamRequestsAFullFrame() {
        let queue = MobileHostConnectionEventQueue()
        queue.updateSubscribedTopics(["terminal.render_grid"])
        _ = queue.enqueue(
            topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: true, frame: Data([1])
        )
        // Lanes are negotiated mid-chain: a delta may not follow its base
        // onto a different stream, where it could overtake it.
        queue.enableSurfaceLanes(limit: 4)
        _ = queue.focusSurfaceLane("s")
        let crossing = queue.enqueue(
            topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: false, frame: Data([2])
        )
        #expect(!crossing.admitted)
        #expect(crossing.renderGridResyncSurfaceIDs == ["s"])
        let rebase = queue.enqueue(
            topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: true, frame: Data([3])
        )
        #expect(rebase.drainLane == .surface("s"))
        let next = queue.enqueue(
            topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: false, frame: Data([4])
        )
        #expect(next.admitted)
        #expect(!next.startDrain)
    }

    @Test func eachSurfaceLaneDrainsIndependentlyAndOverflowRidesTheSharedLane() {
        let queue = MobileHostConnectionEventQueue()
        queue.updateSubscribedTopics(["terminal.render_grid", "workspace.updated"])
        queue.enableSurfaceLanes(limit: 2)
        _ = queue.focusSurfaceLane("a")
        _ = queue.focusSurfaceLane("b")
        let a = queue.enqueue(topic: "terminal.render_grid", coalesceKey: "a", isFullRenderGridFrame: true, frame: Data([1]))
        let b = queue.enqueue(topic: "terminal.render_grid", coalesceKey: "b", isFullRenderGridFrame: true, frame: Data([2]))
        let c = queue.enqueue(topic: "terminal.render_grid", coalesceKey: "c", isFullRenderGridFrame: true, frame: Data([3]))
        let shared = queue.enqueue(topic: "workspace.updated", coalesceKey: nil, isFullRenderGridFrame: false, frame: Data([4]))
        #expect(a.startDrain && a.drainLane == .surface("a"))
        #expect(b.startDrain && b.drainLane == .surface("b"))
        // Both surface lanes are busy, so the bounded third surface shares.
        #expect(c.startDrain && c.drainLane == .shared)
        #expect(!shared.startDrain)
        #expect(queue.dequeue(lane: .surface("b"))?.frame == Data([2]))
        #expect(queue.dequeue(lane: .shared)?.frame == Data([3]))
        #expect(queue.dequeue(lane: .shared)?.frame == Data([4]))
        #expect(queue.dequeue(lane: .surface("a"))?.frame == Data([1]))
    }

    @Test func repeatedSurfaceLaneFailuresPinTheSurfaceToTheSharedLane() {
        let queue = MobileHostConnectionEventQueue()
        queue.updateSubscribedTopics(["terminal.render_grid"])
        queue.enableSurfaceLanes(limit: 4)
        _ = queue.focusSurfaceLane("s")
        for attempt in 0..<MobileHostConnectionEventQueue.maximumSurfaceLaneFailureCount {
            let generation = queue.surfaceLaneGeneration(surfaceID: "s")
            #expect(generation == UInt64(attempt))
            let full = queue.enqueue(
                topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: true, frame: Data([1])
            )
            #expect(full.drainLane == .surface("s"))
            _ = queue.dequeue(lane: .surface("s"))
            _ = queue.finishDrain(lane: .surface("s"))
            #expect(queue.retireSurfaceLane(surfaceID: "s", generation: generation) == ["s"])
            // A second report for the same stream changes nothing.
            #expect(queue.retireSurfaceLane(surfaceID: "s", generation: generation).isEmpty)
        }
        let pinned = queue.enqueue(
            topic: "terminal.render_grid", coalesceKey: "s", isFullRenderGridFrame: true, frame: Data([2])
        )
        #expect(pinned.drainLane == .shared)
    }
}

/// Records which lane each event write used.
actor RecordingSurfaceLaneEventWriter: MobileHostIndependentEventWriting {
    enum Write: Equatable, Sendable {
        case shared
        case surface(String, generation: UInt64)
    }

    nonisolated let maximumSurfaceEventLaneCount = 16
    private var failFirstSurfaceWrite: Bool
    private var recorded: [Write] = []

    init(failFirstSurfaceWrite: Bool = false) {
        self.failFirstSurfaceWrite = failFirstSurfaceWrite
    }

    func probe(_: Data) async -> Bool { true }
    func send(_: Data) async throws { recorded.append(.shared) }
    func reset() async {}
    func close() async {}

    func sendSurfaceEvent(_: Data, surfaceID: String, generation: UInt64) async throws {
        recorded.append(.surface(surfaceID, generation: generation))
        if failFirstSurfaceWrite {
            failFirstSurfaceWrite = false
            throw CancellationError()
        }
    }

    func writes() -> [Write] { recorded }

    func waitForWrites(_ count: Int) async -> Bool {
        for _ in 0..<2_000 {
            if recorded.count >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}

/// Independent event writer whose writes for one surface never complete
/// until the connection closes, like a QUIC stream out of flow credit.
actor SurfaceGatedIndependentEventWriter: MobileHostIndependentEventWriting {
    nonisolated let maximumSurfaceEventLaneCount = 16
    private let stalledSurfaceID: String
    private var stalledWrites: [CheckedContinuation<Void, any Error>] = []
    private var deliveredSurfaceIDs: [String] = []

    init(stalledSurfaceID: String) {
        self.stalledSurfaceID = stalledSurfaceID
    }

    func probe(_: Data) async -> Bool { true }

    func send(_ framedData: Data) async throws {
        let surfaceID = Self.surfaceID(in: framedData)
        if surfaceID == stalledSurfaceID {
            try await withCheckedThrowingContinuation { stalledWrites.append($0) }
        }
        if let surfaceID { deliveredSurfaceIDs.append(surfaceID) }
    }

    func reset() async {}

    func close() async {
        let writes = stalledWrites
        stalledWrites.removeAll()
        for write in writes { write.resume(throwing: CancellationError()) }
    }

    func waitUntilStalled() async -> Bool {
        for _ in 0..<2_000 {
            if !stalledWrites.isEmpty { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    func waitForDeliveredSurface(_ surfaceID: String) async -> Bool {
        for _ in 0..<2_000 {
            if deliveredSurfaceIDs.contains(surfaceID) { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    func delivered() -> [String] { deliveredSurfaceIDs }

    private static func surfaceID(in framedData: Data) -> String? {
        var buffer = framedData
        guard let payload = try? MobileSyncFrameCodec.decodeFrames(from: &buffer).first,
              let envelope = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let body = envelope["payload"] as? [String: Any] else { return nil }
        return body["surface_id"] as? String
    }
}

/// Blocks one released-lane operation so two connection-owned focus
/// transitions can re-enter the actor at the writer await boundary.
actor FocusOrderingIndependentEventWriter: MobileHostIndependentEventWriting {
    nonisolated let maximumSurfaceEventLaneCount = 1
    private var blockNextRelease = true
    private var releaseStartedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var noteWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var recordedNotes: [String] = []

    func probe(_: Data) async -> Bool { true }
    func send(_: Data) async throws {}
    func reset() async {}
    func close() async {}

    func sendSurfaceEvent(
        _: Data,
        surfaceID _: String,
        generation _: UInt64
    ) async throws {}

    func releaseSurfaceLanes(_ generationsBySurfaceID: [String: UInt64]) async {
        guard blockNextRelease, !generationsBySurfaceID.isEmpty else { return }
        blockNextRelease = false
        releaseStartedWaiter?.resume()
        releaseStartedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func noteInteractiveSurface(_ surfaceID: String) async {
        recordedNotes.append(surfaceID)
        noteWaiters.removeValue(forKey: surfaceID)?.resume()
    }

    func waitForReleaseStart() async {
        guard releaseWaiter == nil else { return }
        await withCheckedContinuation { releaseStartedWaiter = $0 }
    }

    func waitForNote(_ surfaceID: String) async {
        guard !recordedNotes.contains(surfaceID) else { return }
        await withCheckedContinuation { noteWaiters[surfaceID] = $0 }
    }

    func releaseBlockedOperation() { releaseWaiter?.resume(); releaseWaiter = nil }
    func notes() -> [String] { recordedNotes }
}
