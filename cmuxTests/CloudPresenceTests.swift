import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for the Mac side of cmux-tui collaboration presence:
/// wire decoding, the commands a presence link sends, and the row mapping an
/// overlay applies when two viewers sit at different scrollback offsets.
@Suite
struct CloudPresenceTests {
    private let decoder = CloudTuiManualIOFrameDecoder()
    private let commands = CloudTuiManualIOCommand()

    private static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test
    func presenceChangedDecodesPointerAndHighlight() throws {
        let frame = try #require(decoder.decode(try Self.line([
            "event": "presence-changed",
            "client": 3,
            "name": "ada",
            "kind": "mac",
            "color": 11,
            "surface": 7,
            "pointer": ["kind": "cell", "row": 3, "col": 12, "scroll_offset": 5],
            "highlight": [
                "start": ["kind": "cell", "row": 3, "col": 0],
                "end": ["kind": "cell", "row": 4, "col": 40],
                "mode": "laser",
            ],
            "updated_at_ms": 1_757_548_800_000,
            "generation": 9,
        ])))
        guard case let .presence(entry) = frame else {
            Issue.record("expected a presence frame, got \(frame)")
            return
        }
        #expect(entry.client == 3)
        #expect(entry.name == "ada")
        #expect(entry.color == 3, "palette slot wraps to 0..<8")
        #expect(entry.surface == 7)
        #expect(entry.pointer == .cell(row: 3, col: 12, scrollOffset: 5))
        #expect(entry.highlight?.mode == .laser)
        #expect(entry.highlight?.end == .cell(row: 4, col: 40, scrollOffset: 0))
        #expect(entry.generation == 9)
        #expect(!entry.isCleared)
    }

    @Test
    func presenceClearWithNullSurfaceStillDecodes() throws {
        // Byte-attach events require a positive surface; a presence clear is
        // the one event that legitimately carries `surface: null`.
        let frame = try #require(decoder.decode(try Self.line([
            "event": "presence-changed",
            "client": 3,
            "name": NSNull(),
            "kind": NSNull(),
            "color": 3,
            "surface": NSNull(),
            "pointer": NSNull(),
            "highlight": NSNull(),
            "updated_at_ms": 1,
            "generation": 10,
        ])))
        guard case let .presence(entry) = frame else {
            Issue.record("expected a presence frame, got \(frame)")
            return
        }
        #expect(entry.isCleared)
        #expect(entry.pointer == nil)
        #expect(entry.highlight == nil)
    }

    @Test
    func presenceCommandsCarryAnchorsAndCapability() throws {
        let info = commands.setPresenceClientInfo(name: "ada", kind: "mac", requestID: 2)
        #expect(info["cmd"] as? String == "set-client-info")
        #expect(info["capabilities"] as? [String] == ["presence-v1"])

        let subscribe = commands.subscribePresence(requestID: 3)
        #expect(subscribe["cmd"] as? String == "subscribe")
        #expect(subscribe["presence_only"] as? Bool == true)

        let update = commands.presenceUpdate(
            surfaceID: 7,
            pointer: .cell(row: 1, col: 2, scrollOffset: 3),
            highlight: CloudPresenceHighlight(
                start: .cell(row: 1, col: 0, scrollOffset: 3),
                end: .point(x: 4.5, y: 6),
                mode: .pin
            ),
            requestID: 4
        )
        #expect(update["cmd"] as? String == "presence-update")
        #expect(update["surface"] as? UInt64 == 7)
        let pointer = try #require(update["pointer"] as? [String: Any])
        #expect(pointer["kind"] as? String == "cell")
        #expect(pointer["row"] as? Int == 1)
        #expect(pointer["scroll_offset"] as? UInt64 == 3)
        let highlight = try #require(update["highlight"] as? [String: Any])
        #expect(highlight["mode"] as? String == "pin")
        #expect((highlight["end"] as? [String: Any])?["kind"] as? String == "point")
        #expect(JSONSerialization.isValidJSONObject(update))

        let list = commands.listClients(requestID: 6)
        #expect(list["cmd"] as? String == "list-clients")

        let listResponse = try #require(decoder.decode(try Self.line([
            "id": 6,
            "ok": true,
            "data": [["client": 42, "self": true]],
        ])))
        guard case let .response(requestID, ok, _, _, _, _, _, selfClientID) = listResponse else {
            Issue.record("expected a list-clients response")
            return
        }
        #expect(requestID == 6)
        #expect(ok)
        #expect(selfClientID == 42)

        let bare = commands.presenceUpdate(surfaceID: 7, pointer: nil, highlight: nil, requestID: 5)
        #expect(bare["pointer"] == nil)
        #expect(bare["highlight"] == nil)
    }

    @Test
    func viewerRowShiftsByScrollbackOffsetDifference() {
        let anchor = CloudPresenceAnchor.cell(row: 10, col: 0, scrollOffset: 4)
        // Same offset: same row.
        #expect(anchor.viewerRow(viewerScrollOffset: 4, rows: 24) == 10)
        // Viewer scrolled two rows further up: the cell appears two rows lower.
        #expect(anchor.viewerRow(viewerScrollOffset: 6, rows: 24) == 12)
        // Viewer at the live bottom: the cell is four rows higher.
        #expect(anchor.viewerRow(viewerScrollOffset: 0, rows: 24) == 6)
        // Off the top or bottom of the viewer's grid: hidden.
        #expect(anchor.viewerRow(viewerScrollOffset: 0, rows: 5) == nil)
        #expect(CloudPresenceAnchor.cell(row: 0, col: 0, scrollOffset: 30)
            .viewerRow(viewerScrollOffset: 0, rows: 24) == nil)
        // Points never map to a terminal row.
        #expect(CloudPresenceAnchor.point(x: 1, y: 2).viewerRow(viewerScrollOffset: 0, rows: 24) == nil)
    }

    @Test
    func unrepresentableScrollOffsetsAreIgnored() throws {
        let malformed = try Self.line([
            "kind": "cell",
            "row": 1,
            "col": 1,
            "scroll_offset": NSNumber(value: UInt64.max),
        ])
        #expect(CloudPresenceAnchor(json: try JSONSerialization.jsonObject(with: malformed)) == nil)
        #expect(CloudPresenceAnchor.cell(row: 1, col: 1, scrollOffset: .max)
            .viewerRow(viewerScrollOffset: 0, rows: 24) == nil)
    }
}

@Suite(.serialized)
@MainActor
struct CloudPresenceDeliveryTests {
    private func acceptHandshake(_ fixture: CloudManualMirrorSocketFixture) async throws -> UInt64 {
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(1)))
        #expect(identify.cmd == "identify")
        let info = try #require(await fixture.nextCommand(timeout: .seconds(1)))
        #expect(info.cmd == "set-client-info")
        fixture.send(["id": identify.id, "ok": true, "data": ["capabilities": ["presence-v1"]]])
        let clients = try #require(await fixture.nextCommand(timeout: .seconds(1)))
        #expect(clients.cmd == "list-clients")
        fixture.send(["id": clients.id, "ok": true, "data": [["client": 41, "self": true]]])
        let subscribe = try #require(await fixture.nextCommand(timeout: .seconds(1)))
        #expect(subscribe.cmd == "subscribe")
        return subscribe.id
    }

    private func waitUntilReady(_ link: CloudPresenceLink) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while link.phase != .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(link.phase == .ready)
    }

    @Test
    func pointerBurstSendsFinalCellWithoutAnotherMouseEvent() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        let link = CloudPresenceLink(machineID: "burst", socketPath: fixture.socketPath,
                                     clientName: "Alice", onEntry: { _ in }, onPhaseChange: { _ in })
        defer { link.stop(); fixture.close() }
        let subscribe = try await acceptHandshake(fixture)
        fixture.send(["id": subscribe, "ok": true, "data": [:]])
        try await waitUntilReady(link)
        link.publish(surfaceID: 7, pointer: .cell(row: 1, col: 2, scrollOffset: 0), highlight: nil)
        link.publish(surfaceID: 7, pointer: .cell(row: 8, col: 2, scrollOffset: 0), highlight: nil)
        let first = await fixture.nextCommand(timeout: .seconds(1))
        #expect(first?.pointerRow == 1)
        let final = await fixture.nextCommand(timeout: .milliseconds(250))
        #expect(final?.pointerRow == 8, "The settled cell must be sent even when the mouse stops during throttling")
    }

    @Test
    func subscriptionAcknowledgementGatesOutgoingPresence() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        let link = CloudPresenceLink(machineID: "handshake", socketPath: fixture.socketPath,
                                     clientName: "Alice", onEntry: { _ in }, onPhaseChange: { _ in })
        defer { link.stop(); fixture.close() }
        let subscribe = try await acceptHandshake(fixture)
        link.publish(surfaceID: 7, pointer: .cell(row: 4, col: 2, scrollOffset: 0), highlight: nil)
        #expect(link.phase == .connecting)
        #expect(await fixture.nextCommand(timeout: .milliseconds(100)) == nil)
        fixture.send(["id": subscribe, "ok": true, "data": [:]])
        try await waitUntilReady(link)
        #expect(await fixture.nextCommand(timeout: .seconds(1))?.pointerRow == 4)
    }

    @Test
    func paneRegistrationAndRemapNotifyExistingPresence() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        let store = CloudPresenceStore()
        let machine = "existing-\(UUID().uuidString)"
        let firstPane = UUID()
        let laterPane = UUID()
        store.registerPane(panelID: firstPane, machineID: machine, remoteSurfaceID: 7, socketPath: fixture.socketPath)
        defer {
            store.unregisterPane(panelID: firstPane)
            store.unregisterPane(panelID: laterPane)
            fixture.close()
        }
        let subscribe = try await acceptHandshake(fixture)
        fixture.send(["id": subscribe, "ok": true, "data": [:]])
        fixture.send(["event": "presence-changed", "client": 42, "color": 2, "surface": 7,
                      "name": "Bob", "pointer": ["kind": "cell", "row": 2, "col": 3],
                      "generation": 1, "updated_at_ms": 1])
        let deadline = ContinuousClock.now + .seconds(1)
        while store.entries(forPane: firstPane).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.entries(forPane: firstPane).count == 1)
        let counter = CloudPresenceNotificationCounter()
        let machineIDKey = CloudPresenceStore.machineIDKey
        let observer = NotificationCenter.default.addObserver(forName: .cloudPresenceDidChange, object: nil, queue: nil) { note in
            guard note.userInfo?[machineIDKey] as? String == machine else { return }
            MainActor.assumeIsolated { counter.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.registerPane(panelID: laterPane, machineID: machine, remoteSurfaceID: 0, socketPath: fixture.socketPath)
        #expect(counter.value == 1, "A newly created overlay must receive the current machine state")
        store.updateRemoteSurfaceID(panelID: laterPane, remoteSurfaceID: 7)
        #expect(counter.value == 2, "Resolving a pane must redraw existing peers without waiting for their next move")
        #expect(store.entries(forPane: laterPane).first?.name == "Bob")
    }

    @Test
    func carrierReplacementResendsUnchangedPresence() async throws {
        let first = try CloudManualMirrorSocketFixture()
        let second = try CloudManualMirrorSocketFixture()
        let link = CloudPresenceLink(machineID: "reconnect", socketPath: first.socketPath,
                                     clientName: "Alice", onEntry: { _ in }, onPhaseChange: { _ in })
        defer { link.stop(); first.close(); second.close() }
        let firstSubscription = try await acceptHandshake(first)
        first.send(["id": firstSubscription, "ok": true, "data": [:]])
        try await waitUntilReady(link)
        link.publish(surfaceID: 7, pointer: .cell(row: 6, col: 2, scrollOffset: 0), highlight: nil)
        #expect(await first.nextCommand(timeout: .seconds(1))?.pointerRow == 6)
        link.reconnect(socketPath: second.socketPath)
        let secondSubscription = try await acceptHandshake(second)
        second.send(["id": secondSubscription, "ok": true, "data": [:]])
        #expect(await second.nextCommand(timeout: .seconds(1))?.pointerRow == 6)
    }

    @Test
    func clearCancelsThePendingHover() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        let link = CloudPresenceLink(machineID: "clear", socketPath: fixture.socketPath,
                                     clientName: "Alice", onEntry: { _ in }, onPhaseChange: { _ in })
        defer { link.stop(); fixture.close() }
        let subscribe = try await acceptHandshake(fixture)
        fixture.send(["id": subscribe, "ok": true, "data": [:]])
        try await waitUntilReady(link)
        link.publish(surfaceID: 7, pointer: .cell(row: 1, col: 2, scrollOffset: 0), highlight: nil)
        link.publish(surfaceID: 7, pointer: .cell(row: 8, col: 2, scrollOffset: 0), highlight: nil)
        link.clear()
        #expect(await fixture.nextCommand(timeout: .seconds(1))?.cmd == "presence-update")
        #expect(await fixture.nextCommand(timeout: .seconds(1))?.cmd == "presence-clear")
        #expect(await fixture.nextCommand(timeout: .milliseconds(120))?.cmd == nil)
    }
}

@MainActor
private final class CloudPresenceNotificationCounter {
    var value = 0
}
