import CmuxCloudTui
import CmuxTerminalSizing
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Shared terminal sizing on the Cloud relay path (docs/shared-terminal-sizing.md):
/// the Mac mirror is one participant of a cmux-tui host. A person's
/// `disconnected-by` must never auto-reconnect; a network detach still does.
@Suite struct CloudTerminalSharedSizingTests {
    private static let terminalID = "term_5b1a9c2f0d3e4a5b6c7d8e9f00112233"

    // MARK: Wire decoding

    @Test func detachedEventCarriesReasonActorAndView() throws {
        let line = try JSONSerialization.data(withJSONObject: [
            "event": "detached", "surface": 17, "reason": "disconnected-by",
            "by": ["user_id": "u_maya", "display_name": "Maya", "device_name": "Mac Studio"],
            "view": "mobile:p1",
        ])
        let frame = try #require(CloudTuiManualIOFrameDecoder().decode(line))
        guard case let .detached(surfaceID, reason, view, _) = frame else {
            Issue.record("expected a detached frame, got \(frame)")
            return
        }
        #expect(surfaceID == 17)
        #expect(view == "mobile:p1")
        #expect(reason == .disconnectedBy(TerminalDetachActor(userID: "u_maya", displayName: "Maya", deviceName: "Mac Studio")))
        #expect(!reason.reconnectsAutomatically)
    }

    @Test func legacyDetachedEventStillMeansNetwork() throws {
        let line = try JSONSerialization.data(withJSONObject: ["event": "detached", "surface": 17])
        let frame = try #require(CloudTuiManualIOFrameDecoder().decode(line))
        #expect(frame == .detached(surfaceID: 17, reason: .network, view: nil))
    }

    @Test func sizeStateEventAndAttachParticipantDecode() throws {
        let state: [String: Any] = [
            "generation": 3, "cols": 90, "rows": 30, "reason": "latest", "owners": ["c1"],
            "policy": ["mode": "latest", "priority": [], "fixed": NSNull()],
            "participants": [[
                "id": "c1", "user_id": "u", "display_name": NSNull(), "device_kind": "mac",
                "device_name": NSNull(), "via": NSNull(), "viewport": ["cols": 90, "rows": 30],
                "counts_override": NSNull(), "counts": true, "priority_key": "u/mac",
            ]],
        ]
        let event = try JSONSerialization.data(withJSONObject: ["event": "size-state", "surface": 17, "state": state])
        guard case let .sizeState(_, decoded) = try #require(CloudTuiManualIOFrameDecoder().decode(event)) else {
            Issue.record("expected a size-state frame")
            return
        }
        #expect(decoded.size == TerminalGridSize(cols: 90, rows: 30))
        #expect(decoded.owners == ["c1"])

        let response = try JSONSerialization.data(withJSONObject: [
            "id": 4, "ok": true, "data": ["lease": "l1", "participant": "c1"],
        ])
        guard case let .response(_, _, lease, _, _, _, _, sizing) = try #require(CloudTuiManualIOFrameDecoder().decode(response)) else {
            Issue.record("expected a response frame")
            return
        }
        #expect(lease == "l1")
        #expect(sizing?.participant == "c1")
    }

    @Test func relayViewCommandCarriesIdentityAndViewport() throws {
        let command = try #require(CloudTuiManualIOCommand().resizeRelayView(
            surfaceID: 17,
            view: "mobile:p1",
            identity: TerminalSizingParticipant(
                id: "ignored", userID: "u", displayName: "Maya", deviceKind: .iphone,
                deviceName: "iPhone 17", viewport: TerminalGridSize(cols: 50, rows: 30)
            ),
            requestID: 9
        ))
        #expect(command["cmd"] as? String == "resize-attached-view")
        #expect(command["view"] as? String == "mobile:p1")
        #expect(command["cols"] as? Int == 50)
        let identity = try #require(command["identity"] as? [String: Any])
        #expect(identity["device_kind"] as? String == "iphone")
        #expect(identity["user_id"] as? String == "u")
    }

    // MARK: Session behavior

    @MainActor
    private func attachedSession(
        fixture: CloudManualMirrorSocketFixture,
        reconnects: SharedSizingReconnectCounter,
        capabilities: [String]
    ) async throws -> CloudTuiManualMirrorSession {
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: Self.terminalID,
            remoteSurfaceID: 17,
            onNeedsReconnect: { reconnects.increment() }
        )
        session.reconnect(socketPath: fixture.socketPath)
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": identify.id, "ok": true, "data": ["protocol": 12, "capabilities": capabilities]])
        let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(clientInfo.cmd == "set-client-info")
        fixture.send(["id": clientInfo.id, "ok": true, "data": [:]])
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        fixture.send(["id": attach.id, "ok": true, "data": ["participant": "c1"]])
        #expect(await Self.waitUntil { session.phase == .attached })
        return session
    }

    @Test @MainActor
    func disconnectedByDetachDoesNotReconnect() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let reconnects = SharedSizingReconnectCounter()
        let session = try await attachedSession(
            fixture: fixture, reconnects: reconnects, capabilities: [CloudTuiManualIOCommand().sharedSizingCapability]
        )
        defer { session.stop() }
        #expect(session.sizingRelay.selfParticipantID == "c1")

        fixture.send([
            "event": "detached", "surface": 17, "reason": "disconnected-by",
            "by": ["user_id": "u_maya", "display_name": "Maya", "device_name": "Mac Studio"],
        ])

        #expect(await Self.waitUntil { session.phase == .disconnected })
        #expect(session.sharingDetachment != nil)
        #expect(!session.allowsAutomaticReconnect)
        #expect(session.connectionPresentation == nil)
        #expect(reconnects.count == 0)
    }

    @Test @MainActor
    func networkDetachStillReconnects() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let reconnects = SharedSizingReconnectCounter()
        let session = try await attachedSession(
            fixture: fixture, reconnects: reconnects, capabilities: [CloudTuiManualIOCommand().sharedSizingCapability]
        )
        defer { session.stop() }

        fixture.send(["event": "detached", "surface": 17, "reason": "network"])

        #expect(await Self.waitUntil { session.phase == .disconnected })
        #expect(session.sharingDetachment == nil)
        #expect(session.allowsAutomaticReconnect)
        #expect(reconnects.count >= 1)
    }

    @Test @MainActor
    func phoneDetachKeepsTheMirrorAttached() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let reconnects = SharedSizingReconnectCounter()
        let session = try await attachedSession(
            fixture: fixture, reconnects: reconnects, capabilities: [CloudTuiManualIOCommand().sharedSizingCapability]
        )
        defer { session.stop() }
        session.relayPhones([
            "p1": TerminalSizingParticipant(
                id: "x", userID: "u", deviceKind: .iphone, viewport: TerminalGridSize(cols: 50, rows: 30)
            ),
        ])

        fixture.send(["event": "detached", "surface": 17, "reason": "disconnected-by", "view": "mobile:p1"])

        #expect(await Self.waitUntil { session.sizingRelay.views.isEmpty })
        #expect(session.phase == .attached)
        #expect(reconnects.count == 0)
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
private final class SharedSizingReconnectCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
