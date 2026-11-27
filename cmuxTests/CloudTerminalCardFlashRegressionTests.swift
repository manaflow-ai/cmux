import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression for https://github.com/manaflow-ai/cmux/issues/12537: a native Cloud
/// pane must not flash the reconnecting card while a healthy attach is in
/// flight, and a disconnect that automatic recovery repairs a moment later must
/// not be announced as "unavailable". Both are judged at production grace with
/// the session's public API only.
@Suite("Cloud terminal card flash regression")
struct CloudTerminalCardFlashRegressionTests {
    @Test @MainActor
    func startingAnAttachDoesNotShowACardImmediately() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_flash", remoteSurfaceID: 17,
            onNeedsReconnect: {}
        )
        defer { session.stop() }

        session.reconnect(socketPath: fixture.socketPath)

        #expect(session.phase == .connecting)
        #expect(session.connectionPresentation == nil)
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(identify.cmd == "identify")
        #expect(session.connectionPresentation == nil)
    }

    @Test @MainActor
    func aDisconnectUnderAutomaticRecoveryIsNotAnnouncedAsUnavailable() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        var recoveries = 0
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_recover", remoteSurfaceID: 17,
            onNeedsReconnect: { recoveries += 1 }
        )
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath)
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": identify.id, "ok": true, "data": ["protocol": 12]])
        let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": clientInfo.id, "ok": true])
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        fixture.send(["id": attach.id, "ok": true, "data": [:]])
        fixture.send([
            "event": "vt-state", "surface": 17, "cols": 80, "rows": 24,
            "data": Data("$ ".utf8).base64EncodedString()
        ])
        try await Self.waitUntil { session.phase == .attached && session.connectionPresentation == nil }

        // The transport drops. The provider will reconnect this session on its
        // own; the pane keeps its last frame instead of switching to an error.
        fixture.send(["event": "detached", "surface": 17])
        try await Self.waitUntil { session.phase == .disconnected }

        #expect(recoveries == 1)
        #expect(session.allowsAutomaticReconnect)
        #expect(session.connectionPresentation == nil)
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
