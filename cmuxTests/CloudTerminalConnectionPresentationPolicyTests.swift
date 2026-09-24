import AppKit
import CmuxCloudTui
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The connection card must never flash during a healthy handoff and must never
/// call a connected pane unavailable (https://github.com/manaflow-ai/cmux/issues/12537).
/// The pane shows no progress card at all; only Reconnect, once recovery has
/// kept failing.
@Suite("Cloud terminal connection presentation")
struct CloudTerminalConnectionPresentationPolicyTests {
    private typealias Policy = CloudTerminalConnectionPresentationPolicy

    @Test
    func workingAttachmentsShowNothingWhateverTheStage() {
        for phase in [CloudTuiManualMirrorPhase.connecting, .attached] {
            for stage in [Policy.Stage.silent, .failure] {
                let input = Policy.Input(phase: phase, replayReceived: false, automaticRecovery: true, stage: stage)
                #expect(Policy.outcome(for: input) == .none, "\(phase) at \(stage)")
            }
        }
        let usable = Policy.Input(phase: .attached, replayReceived: true, automaticRecovery: true, stage: .failure)
        #expect(Policy.outcome(for: usable) == .none)
    }

    @Test
    func disconnectedOffersReconnectOnlyAfterTheGraceOrWhenRecoveryStopped() {
        let recovering = Policy.Input(phase: .disconnected, replayReceived: false, automaticRecovery: true, stage: .silent)
        #expect(Policy.outcome(for: recovering) == .none)
        let exhausted = Policy.Input(phase: .disconnected, replayReceived: false, automaticRecovery: true, stage: .failure)
        #expect(Policy.outcome(for: exhausted) == .failure)
        let givenUp = Policy.Input(phase: .disconnected, replayReceived: false, automaticRecovery: false, stage: .silent)
        #expect(Policy.outcome(for: givenUp) == .failure)
    }

    @Test
    func idleAndStoppedShowNothing() {
        for phase in [CloudTuiManualMirrorPhase.idle, .stopped] {
            let input = Policy.Input(phase: phase, replayReceived: false, automaticRecovery: false, stage: .failure)
            #expect(Policy.outcome(for: input) == .none)
        }
    }

    @Test
    func episodeBoundariesFollowUsability() {
        #expect(Policy.isUsable(Policy.Input(phase: .attached, replayReceived: true, automaticRecovery: true, stage: .silent)))
        #expect(!Policy.isUsable(Policy.Input(phase: .attached, replayReceived: false, automaticRecovery: true, stage: .silent)))
        #expect(Policy.isUnusableEpisode(Policy.Input(phase: .connecting, replayReceived: false, automaticRecovery: true, stage: .silent)))
        #expect(!Policy.isUnusableEpisode(Policy.Input(phase: .idle, replayReceived: false, automaticRecovery: true, stage: .silent)))
    }

    /// The regression the report describes: a fresh attach must never put a card
    /// on the pane, not even for one frame, at any point of the handshake.
    @Test @MainActor
    func firstAttachNeverShowsACard() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_fresh", remoteSurfaceID: 17,
            presentationPolicy: Policy(failureGrace: .seconds(4)),
            onNeedsReconnect: {}
        )
        defer { session.stop() }
        let frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let hosted = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: frame))
        let anchor = GhosttyTerminalView.HostContainerView(frame: frame)
        let owner = hosted.cloudTerminalOverlay
        owner.session = session
        owner.updateAnchor(anchor, visible: true, ownershipGeneration: 1)
        func synchronize() {
            owner.synchronize(hostedView: hosted, contentFrame: frame, legacyPresentation: nil) {}
        }

        session.reconnect(socketPath: fixture.socketPath)
        #expect(session.phase == .connecting)
        #expect(session.connectionPresentation == nil)
        synchronize()
        #expect(owner.overlay == nil)
        try await Self.completeHandshake(fixture, surface: 17)
        try await Self.waitUntil { session.phase == .attached }
        #expect(session.connectionPresentation == nil)
        synchronize()
        #expect(owner.overlay == nil)
        fixture.send([
            "event": "vt-state", "surface": 17, "cols": 80, "rows": 24,
            "data": Data("cmux@cloud> ".utf8).base64EncodedString()
        ])
        try await Self.waitUntil { !session.isPresentationEpisodeActive }
        #expect(session.connectionPresentation == nil)
        synchronize()
        #expect(owner.overlay == nil)
    }

    /// A disconnect that automatic recovery repairs inside the grace shows
    /// nothing at any point; the pane keeps its last frame.
    @Test @MainActor
    func transientDisconnectRepairedInsideTheGraceShowsNothing() async throws {
        var recoveries = 0
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_bounce", remoteSurfaceID: 17,
            presentationPolicy: Policy(failureGrace: .seconds(4)),
            onNeedsReconnect: { recoveries += 1 }
        )
        defer { session.stop() }
        var presentations: [CloudTerminalReconnectOverlayPolicy.Presentation?] = []
        for cycle in 0..<3 {
            let fixture = try CloudManualMirrorSocketFixture()
            defer { fixture.close() }
            // The provider resolved a new numeric surface: the session fences the
            // old stream (disconnected) and immediately reconnects (connecting).
            session.updateRemoteSurfaceID(UInt64(17 + cycle))
            presentations.append(session.connectionPresentation)
            session.reconnect(socketPath: fixture.socketPath)
            presentations.append(session.connectionPresentation)
            try await Self.completeHandshake(fixture, surface: UInt64(17 + cycle))
            fixture.send([
                "event": "vt-state", "surface": UInt64(17 + cycle), "cols": 80, "rows": 24,
                "data": Data("$ ".utf8).base64EncodedString()
            ])
            try await Self.waitUntil { session.phase == .attached && !session.isPresentationEpisodeActive }
            presentations.append(session.connectionPresentation)
            // The transport drops; recovery is automatic and fast.
            fixture.send(["event": "detached", "surface": UInt64(17 + cycle)])
            try await Self.waitUntil { session.phase == .disconnected }
            presentations.append(session.connectionPresentation)
        }
        #expect(presentations.allSatisfy { $0 == nil })
        #expect(recoveries == 3)
    }

    /// Recovery that keeps failing is reported with Reconnect after the grace,
    /// and a usable attachment clears it at once.
    @Test @MainActor
    func persistentFailureOffersReconnectAndAUsableAttachmentClearsIt() async throws {
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_stuck", remoteSurfaceID: 17,
            presentationPolicy: Policy(failureGrace: .milliseconds(80)),
            onNeedsReconnect: {}
        )
        defer { session.stop() }
        session.markSurfaceResolutionUnavailable()
        #expect(session.connectionPresentation == nil)
        try await Self.waitUntil { session.connectionPresentation?.showsReconnectButton == true }
        #expect(session.connectionPresentation?.showsProgress == false)

        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        session.reconnect(socketPath: fixture.socketPath)
        // The attempt that follows an exhausted grace shows nothing while it runs.
        #expect(session.connectionPresentation == nil)
        try await Self.completeHandshake(fixture, surface: 17)
        fixture.send([
            "event": "vt-state", "surface": 17, "cols": 80, "rows": 24,
            "data": Data("$ ".utf8).base64EncodedString()
        ])
        try await Self.waitUntil { session.connectionPresentation == nil && session.phase == .attached }
        #expect(!session.isPresentationEpisodeActive)
    }

    @MainActor
    private static func completeHandshake(_ fixture: CloudManualMirrorSocketFixture, surface: UInt64) async throws {
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(identify.cmd == "identify")
        fixture.send(["id": identify.id, "ok": true, "data": ["protocol": 12]])
        let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(clientInfo.cmd == "set-client-info")
        fixture.send(["id": clientInfo.id, "ok": true])
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        #expect(attach.surface == surface)
        fixture.send(["id": attach.id, "ok": true, "data": [:]])
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
