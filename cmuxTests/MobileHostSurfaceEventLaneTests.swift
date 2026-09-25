import CMUXMobileCore
import CmuxIrohTransport
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

        // Surface A's replay is stuck in flight: the phone has not granted
        // stream credit for its bytes yet.
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
