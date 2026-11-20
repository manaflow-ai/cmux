import CmuxCloudTui
import CmuxSurfaceCatalogModel
import CmuxTerminalSizing
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A new Cloud split registers its attach stream while the machine creates the
/// terminal, so the only request left after the create is `attach-surface`.
@Suite
struct CloudManualMirrorHandshakeTests {
    private static let capabilities = ["attach-identity-v1", "view-attachment-lease-v1", "terminal-pending-sequence-v1"]

    @Test @MainActor
    func registrationRunsBeforeTheTerminalExistsAndTheAttachFollowsAlone() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let handshake = Self.handshake()
        handshake.start { fixture.socketPath }

        // No terminal exists yet: the daemon sees only the registration.
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(identify.cmd == "identify")
        fixture.send(["id": identify.id, "ok": true, "data": ["capabilities": Self.capabilities]])
        let registration = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(registration.cmd == "set-client-info")
        fixture.send(["id": registration.id, "ok": true, "data": [:]])

        // The create returns; the session adopts the registered stream.
        let session = Self.session(terminalID: "term_created")
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath, handshake: handshake)
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        #expect(attach.expectedGeneration == "g1")
        #expect(attach.expectedTerminalID == "term_created")
        #expect(attach.id > registration.id)
        #expect(fixture.connectionCount() == 1)

        fixture.send(["event": "vt-state", "surface": 17, "cols": 80, "rows": 24, "data": ""])
        fixture.send(["id": attach.id, "ok": true, "data": ["lease": "lease-1"]])
        #expect(await Self.waitUntil { session.phase == .attached && session.remoteSurfaceID == 17 })
    }

    /// The attach rides a different link lane than the registration, so an
    /// adopted stream still waits for the registration's acknowledgement.
    @Test @MainActor
    func adoptionBeforeTheRegistrationIsAnsweredStillWaitsForIt() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let handshake = Self.handshake()
        handshake.start { fixture.socketPath }
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": identify.id, "ok": true, "data": ["capabilities": Self.capabilities]])
        let registration = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(registration.cmd == "set-client-info")

        let session = Self.session(terminalID: "term_fast")
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath, handshake: handshake)
        let premature = await fixture.nextCommand(timeout: .milliseconds(400))
        #expect(premature == nil, "sent \(premature?.cmd ?? "nothing") before set-client-info was acknowledged")

        fixture.send(["id": registration.id, "ok": true, "data": [:]])
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        #expect(fixture.connectionCount() == 1)
    }

    /// Closing the pane while the adopted registration is still unanswered
    /// releases the stream; a late acknowledgement sends nothing more.
    @Test @MainActor
    func stoppingWhileTheRegistrationIsPendingSendsNoAttach() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let handshake = Self.handshake()
        handshake.start { fixture.socketPath }
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": identify.id, "ok": true, "data": ["capabilities": Self.capabilities]])
        let registration = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(registration.cmd == "set-client-info")

        let session = Self.session(terminalID: "term_closed")
        session.reconnect(socketPath: fixture.socketPath, handshake: handshake)
        session.stop()
        fixture.send(["id": registration.id, "ok": true, "data": [:]])
        let late = await fixture.nextCommand(timeout: .milliseconds(400))
        #expect(late == nil, "sent \(late?.cmd ?? "nothing") after the pane closed")
        #expect(fixture.connectionCount() == 1)
    }

    /// A link that reconnected while the terminal was created has a new socket;
    /// the stale registration is dropped and the session registers afresh.
    @Test @MainActor
    func aDifferentSocketFallsBackToTheSessionsOwnRegistration() async throws {
        let stale = try CloudManualMirrorSocketFixture()
        defer { stale.close() }
        let current = try CloudManualMirrorSocketFixture()
        defer { current.close() }
        let handshake = Self.handshake()
        handshake.start { stale.socketPath }
        let identify = try #require(await stale.nextCommand(timeout: .seconds(5)))
        stale.send(["id": identify.id, "ok": true, "data": ["capabilities": Self.capabilities]])
        let registration = try #require(await stale.nextCommand(timeout: .seconds(5)))
        stale.send(["id": registration.id, "ok": true, "data": [:]])

        let session = Self.session(terminalID: "term_moved")
        defer { session.stop() }
        session.reconnect(socketPath: current.socketPath, handshake: handshake)
        let fresh = try #require(await current.nextCommand(timeout: .seconds(5)))
        #expect(fresh.cmd == "identify")
        #expect(await stale.nextCommand(timeout: .milliseconds(200)) == nil)
    }

    /// A failed registration never strands the pane: the session opens its own stream.
    @Test @MainActor
    func aClosedHandshakeLeavesTheOrdinaryPath() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let handshake = Self.handshake()
        handshake.start { throw CancellationError() }

        let session = Self.session(terminalID: "term_plain")
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath, handshake: handshake)
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(identify.cmd == "identify")
    }

    @MainActor
    private static func handshake() -> CloudTuiManualMirrorHandshake {
        CloudTuiManualMirrorHandshake(identity: {
            TerminalSizingParticipant(id: "", deviceKind: .mac)
        })
    }

    @MainActor
    private static func session(terminalID: String) -> CloudTuiManualMirrorSession {
        CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: terminalID,
            remoteSurfaceID: 0,
            creationAttachment: CloudCreationAttachment(generation: "g1", terminalID: terminalID),
            onNeedsReconnect: {}
        )
    }

    @MainActor
    private static func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
