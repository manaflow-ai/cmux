import CmuxMobileRPC
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A projected device terminal is a manual-mirror Ghostty pane fed raw PTY
/// bytes; these pin the two pure edges of that path: how host events decode
/// per surface, and how the pane's pixels become the grid it asks the host for.
@MainActor
@Suite("Devices: terminal mirror events and grid")
struct DeviceTerminalMirrorTests {
    private let surfaceID = UUID()

    private func envelope(_ topic: String, _ object: [String: Any]) throws -> MobileEventEnvelope {
        MobileEventEnvelope(topic: topic, payloadJSON: try JSONSerialization.data(withJSONObject: object), streamID: nil)
    }

    @Test("Output overflow cannot erase the need to recover a terminal link")
    func overflowingOutputRetainsRecovery() async {
        let events = DeviceLinkTerminalEvents()
        let stream = events.stream(surfaceID: surfaceID)
        events.broadcast(.linkReconnected)
        for sequence in 0..<1_024 {
            events.send(.bytes(sequence: UInt64(sequence), data: Data([65])), surfaceID: surfaceID)
        }
        events.finishAll()
        var received: [DeviceTerminalEvent] = []
        for await event in stream { received.append(event) }
        #expect(received.count <= 512)
        #expect(received.contains {
            if case .bytes = $0 { return false }
            return true
        }, "A control or resynchronization event must survive output overflow")
    }

    @Test("Input queue overflow reports a delivery failure", .timeLimit(.minutes(5)))
    func inputOverflowIsReported() async throws {
        let failures = AsyncStream<String>.makeStream()
        defer { failures.continuation.finish() }
        let router = DeviceTerminalInputRouter(send: { _ in
            Issue.record("Oversized input must not be sent")
        }, onFailure: { error in
            failures.continuation.yield(error.localizedDescription)
        })
        defer { router.invalidate() }
        router.enqueue(.bytes(Data(repeating: 65, count: 256 * 1_024 + 1)))
        var received = failures.stream.makeAsyncIterator()
        let failure = try #require(await received.next())
        #expect(!failure.isEmpty)
    }

    @Test("terminal.bytes decodes to a sequenced byte run for its surface")
    func bytesEvent() throws {
        let decoded = try #require(DeviceTerminalEvent.decode(try envelope("terminal.bytes", [
            "surface_id": surfaceID.uuidString, "seq": 41, "data_b64": Data("hi\r\n".utf8).base64EncodedString(),
        ])))
        #expect(decoded.surfaceID == surfaceID)
        #expect(decoded.event == .bytes(sequence: 41, data: Data("hi\r\n".utf8)))
        let unsequenced = try #require(DeviceTerminalEvent.decode(try envelope("terminal.bytes", [
            "surface_id": surfaceID.uuidString, "data_b64": Data("x".utf8).base64EncodedString(),
        ])))
        #expect(unsequenced.event == .bytes(sequence: nil, data: Data("x".utf8)))
        #expect(DeviceTerminalEvent.decode(try envelope("terminal.bytes", ["surface_id": surfaceID.uuidString])) == nil, "a run without bytes is dropped")
        #expect(DeviceTerminalEvent.decode(try envelope("terminal.bytes", ["surface_id": "nope", "data_b64": "aGk="])) == nil)
    }

    @Test("terminal.updated carries the host grid when the host sends it, and nothing otherwise")
    func updatedEvent() throws {
        let sized = try #require(DeviceTerminalEvent.decode(try envelope("terminal.updated", [
            "surface_id": surfaceID.uuidString, "columns": 132, "rows": 40,
        ])))
        #expect(sized.surfaceID == surfaceID)
        #expect(sized.event == .updated(columns: 132, rows: 40))
        let bare = try #require(DeviceTerminalEvent.decode(try envelope("terminal.updated", ["surface_id": surfaceID.uuidString])))
        #expect(bare.event == .updated(columns: nil, rows: nil))
        #expect(DeviceTerminalEvent.decode(try envelope("workspace.updated", ["surface_id": surfaceID.uuidString])) == nil)
        #expect(DeviceTerminalEvent.decode(MobileEventEnvelope(topic: "terminal.updated", payloadJSON: nil, streamID: nil)) == nil)
    }

    @Test("The desired grid derives from the pane's backing pixels minus the surface padding, clamped")
    func desiredGrid() {
        func sample(width: CGFloat, height: CGFloat, scale: CGFloat = 2) -> TerminalSurfaceRawSizingSample {
            // 80×24 cells of 14×30 px with 8×6 px of padding.
            TerminalSurfaceRawSizingSample(
                columns: 80, rows: 24, cellWidthPx: 14, cellHeightPx: 30,
                surfaceWidthPx: 80 * 14 + 8, surfaceHeightPx: 24 * 30 + 6,
                viewBoundsPt: CGSize(width: width, height: height), backingScale: scale
            )
        }
        // 1000pt × 600pt at 2x = 2000×1200 px; minus 8×6 → 1992×1194; / 14×30 → 142 × 39.
        let grid = DeviceTerminalMirrorSession.desiredGrid(from: sample(width: 1000, height: 600))
        #expect(grid?.columns == 142)
        #expect(grid?.rows == 39)
        #expect(DeviceTerminalMirrorSession.desiredGrid(from: sample(width: 0, height: 600)) == nil)
        #expect(DeviceTerminalMirrorSession.desiredGrid(from: sample(width: 1000, height: 600, scale: 0)) == nil)
        let tiny = DeviceTerminalMirrorSession.desiredGrid(from: sample(width: 100, height: 60))
        #expect(tiny?.columns == 20, "narrow panes clamp up to the host minimum")
        #expect(tiny?.rows == 5)
        let huge = DeviceTerminalMirrorSession.desiredGrid(from: sample(width: 5000, height: 4000))
        #expect(huge?.columns == 300)
        #expect(huge?.rows == 120)
        let noBounds = TerminalSurfaceRawSizingSample(
            columns: 80, rows: 24, cellWidthPx: 14, cellHeightPx: 30, surfaceWidthPx: 1128, surfaceHeightPx: 726,
            viewBoundsPt: nil, backingScale: nil
        )
        #expect(DeviceTerminalMirrorSession.desiredGrid(from: noBounds) == nil)
    }
}
