import CmuxMobileRPC
import CmuxMobileHost
import CmuxTerminal
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A projected device terminal is a manual-mirror Ghostty pane fed raw PTY
/// bytes; these pin the two pure edges of that path: how host events decode
/// per surface, and that opening a pane cannot resize the host terminal.
@MainActor
@Suite("Devices: terminal mirror events and grid")
struct DeviceTerminalMirrorTests {
    private let surfaceID = UUID()

    @Test("A slow Mac keeps the latest grid for each surface without changing phone event admission")
    func pendingGridUpdatesAreBoundedAndSurfaceScoped() {
        let topic = DeviceTerminalGridPublisher.eventTopic
        let queue = MobileHostConnectionEventQueue(maximumEventCount: 1, maximumByteCount: 4)
        queue.updateSubscribedTopics([topic, "terminal.bytes"])
        for value in 0..<100 {
            _ = queue.enqueue(topic: topic, coalesceKey: "first", isFullRenderGridFrame: false, frame: Data([UInt8(value)]))
        }
        let second = queue.enqueue(topic: topic, coalesceKey: "second", isFullRenderGridFrame: false, frame: Data([200]))
        _ = queue.enqueue(topic: "terminal.bytes", coalesceKey: "first", isFullRenderGridFrame: false, frame: Data([0]))
        #expect(!second.admitted, "A distinct Mac grid must close the connection instead of growing the queue")
        #expect(queue.count == 2, "Other event pressure cannot discard a surface's last known dimensions")
        #expect(queue.byteCount == 2)
        #expect(queue.dequeue()?.frame == Data([99]))
        #expect(queue.dequeue()?.frame == Data([0]))
        #expect(queue.byteCount == 0)
        let phone = MobileHostConnectionEventQueue()
        phone.updateSubscribedTopics(["terminal.updated", "terminal.render_grid"])
        #expect(!phone.enqueue(topic: topic, coalesceKey: "first", isFullRenderGridFrame: false, frame: Data([1])).admitted)
    }

    @Test("Global render ticks emit only changed Mac dimensions and reuse the live surface index")
    func gridPublishingIsBoundedByGeometryChanges() {
        let other = UUID()
        var publisher = DeviceTerminalGridPublisher()
        var grids = [surfaceID: DeviceTerminalGridPublisher.Grid(columns: 80, rows: 24, generation: 1),
                     other: DeviceTerminalGridPublisher.Grid(columns: 120, rows: 40, generation: 1)]
        var indexReads = 0
        var emitted: [UUID] = []
        func update(topology: UInt64 = 1) {
            publisher.refresh(updatedSurfaceIDs: [surfaceID], global: true, topologyGeneration: topology,
                allSurfaceIDs: { indexReads += 1; return Set(grids.keys) },
                sample: { grids[$0] }, publish: { id, _ in emitted.append(id) })
        }
        update()
        #expect(Set(emitted) == [surfaceID, other])
        emitted.removeAll()
        for _ in 0..<100 { update() }
        #expect(emitted.isEmpty, "Typing and render ticks must not cause replays when dimensions have not changed")
        #expect(indexReads == 1)
        grids[surfaceID] = .init(columns: 60, rows: 24, generation: 1)
        update()
        #expect(emitted == [surfaceID])
        emitted.removeAll()
        grids[other] = nil
        update(topology: 2)
        #expect(emitted.isEmpty)
        #expect(indexReads == 2)
        publisher.reset()
        update(topology: 2)
        #expect(emitted == [surfaceID], "A new subscriber receives the current dimensions")
    }

    @Test func deviceNoticeDismissesWithoutClosingAndResetsAfterRecovery() {
        var retries = 0
        let status = DeviceTerminalAttachmentStatus()
        status.onRetry = { retries += 1 }
        status.update(connected: false, connecting: false)
        #expect(status.presentation?.showsReconnectButton == true)
        status.dismiss()
        #expect(status.presentation == nil)
        status.update(connected: false, connecting: true)
        status.update(connected: false, connecting: false)
        #expect(status.presentation == nil, "Background retries cannot resurrect a dismissed notice")
        status.retry()
        #expect(retries == 1)
        #expect(status.presentation != nil)
        status.update(connected: true, connecting: false)
        #expect(status.presentation == nil)
        status.update(connected: false, connecting: false)
        #expect(status.presentation != nil, "A later disconnection gets its own notice")
    }

    private func envelope(_ topic: String, _ object: [String: Any]) throws -> MobileEventEnvelope {
        MobileEventEnvelope(topic: topic, payloadJSON: try JSONSerialization.data(withJSONObject: object), streamID: nil)
    }

    @Test("Opening a smaller Mac mirror does not resize the host terminal", .timeLimit(.minutes(1)))
    func mirrorAttachPreservesHostGrid() async throws {
        let requests = AsyncStream<String>.makeStream()
        let events = DeviceLinkTerminalEvents()
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, ioMode: .manualMirror
        )
        var methods: [String] = []
        let session = DeviceTerminalMirrorSession(
            remoteWorkspaceID: "workspace", remoteSurfaceID: surfaceID,
            events: events, isConnected: { true },
            requestData: { method, params in
                methods.append(method)
                #expect(params["viewport_columns"] == nil)
                #expect(params["viewport_rows"] == nil)
                requests.continuation.yield(method)
                return try JSONSerialization.data(withJSONObject: [
                    "columns": 160, "rows": 48, "seq": 0, "data_b64": ""
                ])
            }
        )
        defer { session.stop(); events.finishAll(); requests.continuation.finish() }
        session.bind(surface: surface)
        // The actual renderer callback runs before attach when the new pane
        // receives its first (smaller) size. It must not negotiate the host down.
        surface.onManualSizeApplied?(TerminalSurfaceRawSizingSample(
            columns: 80, rows: 24, cellWidthPx: 14, cellHeightPx: 30,
            surfaceWidthPx: 1120, surfaceHeightPx: 720,
            viewBoundsPt: CGSize(width: 560, height: 360), backingScale: 2
        ))
        session.start()
        for await method in requests.stream {
            if method == "mobile.terminal.replay" { break }
        }
        #expect(methods == ["mobile.terminal.replay"])
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

    @Test("Invalidating the input router cancels an in-flight send", .timeLimit(.minutes(5)))
    func invalidatingInputCancelsSend() async throws {
        let started = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); cancelled.continuation.finish() }
        let router = DeviceTerminalInputRouter(send: { _ in
            try await withTaskCancellationHandler {
                started.continuation.yield(())
                // This is a deliberately hung transport with a watchdog;
                // success requires cancellation, never elapsed time.
                try await Task.sleep(for: .seconds(300))
            } onCancel: {
                cancelled.continuation.yield(())
            }
        }, onFailure: { _ in Issue.record("Teardown cancellation is not a delivery failure") })
        defer { router.invalidate() }
        router.enqueue(.bytes(Data("first".utf8)))
        var sends = started.stream.makeAsyncIterator()
        try #require(await sends.next() != nil)
        router.enqueue(.bytes(Data("pending".utf8)))
        router.invalidate()
        var cancellations = cancelled.stream.makeAsyncIterator()
        try #require(await cancellations.next() != nil)
    }

    @Test("Host diagnostics never appear in a device error's user-facing description")
    func hostDiagnosticsStayPrivate() {
        let diagnostic = "mobile.terminal.create secret-account@internal.invalid"
        for error in [
            DeviceLinkError.hostRejected(code: "internal", message: diagnostic),
            DeviceLinkError.malformedResponse(diagnostic)
        ] {
            #expect(error.errorDescription?.contains(diagnostic) == false)
            #expect(error.errorDescription?.isEmpty == false)
        }
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

    @Test("Named resize events carry the host grid", arguments: ["terminal.updated", "device.terminal.grid"])
    func updatedEvent(topic: String) throws {
        let sized = try #require(DeviceTerminalEvent.decode(try envelope(topic, [
            "surface_id": surfaceID.uuidString, "columns": 132, "rows": 40,
        ])))
        #expect(sized.surfaceID == surfaceID)
        #expect(sized.event == .updated(columns: 132, rows: 40))
        let bare = try #require(DeviceTerminalEvent.decode(try envelope("terminal.updated", ["surface_id": surfaceID.uuidString])))
        #expect(bare.event == .updated(columns: nil, rows: nil))
        #expect(DeviceTerminalEvent.decode(try envelope("workspace.updated", ["surface_id": surfaceID.uuidString])) == nil)
        #expect(DeviceTerminalEvent.decode(MobileEventEnvelope(topic: "terminal.updated", payloadJSON: nil, streamID: nil)) == nil)
    }

    @Test("Terminal grid updates reject malformed dimensions")
    func rejectsMalformedGridUpdates() throws {
        let invalid: [Any] = [true, "80", 1.5, 0, -1, 65_536, NSNull()]
        for value in invalid {
            #expect(DeviceTerminalEvent.decode(try envelope("terminal.updated", [
                "surface_id": surfaceID.uuidString, "columns": value, "rows": 24
            ])) == nil)
            #expect(DeviceTerminalEvent.decode(try envelope("terminal.updated", [
                "surface_id": surfaceID.uuidString, "columns": 80, "rows": value
            ])) == nil)
        }
    }

}
