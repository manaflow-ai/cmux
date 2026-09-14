import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The connection card must never flash during a healthy handoff and must never
/// call a connected pane unavailable (https://github.com/manaflow-ai/cmux/issues/12537).
@Suite("Cloud terminal connection presentation")
struct CloudTerminalConnectionPresentationPolicyTests {
    private typealias Policy = CloudTerminalConnectionPresentationPolicy

    @Test
    func silentStageShowsNothingWhileConnectingOrAutomaticallyRecovering() {
        for phase in [CloudTuiManualMirrorPhase.connecting, .disconnected] {
            let input = Policy.Input(phase: phase, replayReceived: false, hasEverReplayed: true, automaticRecovery: true, stage: .silent)
            #expect(Policy.outcome(for: input) == .none)
        }
        let attachedWithoutReplay = Policy.Input(phase: .attached, replayReceived: false, hasEverReplayed: false, automaticRecovery: true, stage: .silent)
        #expect(Policy.outcome(for: attachedWithoutReplay) == .none)
    }

    @Test
    func usableAttachmentNeverShowsACardWhateverTheStage() {
        for stage in [Policy.Stage.silent, .progress, .failure] {
            let input = Policy.Input(phase: .attached, replayReceived: true, hasEverReplayed: true, automaticRecovery: true, stage: stage)
            #expect(Policy.outcome(for: input) == .none)
        }
    }

    @Test
    func progressStageDistinguishesFirstConnectFromReconnect() {
        let first = Policy.Input(phase: .connecting, replayReceived: false, hasEverReplayed: false, automaticRecovery: true, stage: .progress)
        #expect(Policy.outcome(for: first) == .progress(reconnecting: false))
        let again = Policy.Input(phase: .connecting, replayReceived: false, hasEverReplayed: true, automaticRecovery: true, stage: .progress)
        #expect(Policy.outcome(for: again) == .progress(reconnecting: true))
    }

    @Test
    func disconnectedOffersReconnectOnlyAfterTheFailureGraceOrWhenRecoveryStopped() {
        let recovering = Policy.Input(phase: .disconnected, replayReceived: false, hasEverReplayed: true, automaticRecovery: true, stage: .progress)
        #expect(Policy.outcome(for: recovering) == .progress(reconnecting: true))
        let exhausted = Policy.Input(phase: .disconnected, replayReceived: false, hasEverReplayed: true, automaticRecovery: true, stage: .failure)
        #expect(Policy.outcome(for: exhausted) == .failure)
        let givenUp = Policy.Input(phase: .disconnected, replayReceived: false, hasEverReplayed: true, automaticRecovery: false, stage: .silent)
        #expect(Policy.outcome(for: givenUp) == .failure)
        // A reconnect attempt that is still running after the failure grace is
        // progress, not a failure: something is happening.
        let retrying = Policy.Input(phase: .connecting, replayReceived: false, hasEverReplayed: true, automaticRecovery: true, stage: .failure)
        #expect(Policy.outcome(for: retrying) == .progress(reconnecting: true))
    }

    @Test
    func idleAndStoppedShowNothing() {
        for phase in [CloudTuiManualMirrorPhase.idle, .stopped] {
            let input = Policy.Input(phase: phase, replayReceived: false, hasEverReplayed: true, automaticRecovery: false, stage: .failure)
            #expect(Policy.outcome(for: input) == .none)
        }
    }

    @Test
    func progressBuilderTitlesFirstConnectAndReconnectDifferently() {
        let first = CloudTerminalReconnectOverlayPolicy.progress(reconnecting: false)
        let again = CloudTerminalReconnectOverlayPolicy.progress(reconnecting: true)
        #expect(first.showsProgress && !first.showsReconnectButton)
        #expect(again.showsProgress && !again.showsReconnectButton)
        #expect(first.title != again.title)
        #expect(first.detail == again.detail)
    }

    /// The regression the report describes: a fresh attach that completes inside
    /// the grace must never put a card on the pane, not even for one frame.
    @Test @MainActor
    func firstAttachInsideTheGraceNeverShowsACard() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_fresh", remoteSurfaceID: 17,
            presentationPolicy: Policy(progressGrace: .seconds(2), failureGrace: .seconds(4)),
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
    /// neither the reconnecting card nor "unavailable"; the pane stays as it was.
    @Test @MainActor
    func transientDisconnectRepairedInsideTheGraceShowsNothing() async throws {
        var recoveries = 0
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_bounce", remoteSurfaceID: 17,
            presentationPolicy: Policy(progressGrace: .seconds(2), failureGrace: .seconds(4)),
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

    /// Recovery that keeps failing is reported: progress after the first grace,
    /// Reconnect after the second, and a usable attachment clears both at once.
    @Test @MainActor
    func persistentFailureEscalatesToReconnectAndAUsableAttachmentClearsIt() async throws {
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_stuck", remoteSurfaceID: 17,
            presentationPolicy: Policy(progressGrace: .milliseconds(40), failureGrace: .milliseconds(120)),
            onNeedsReconnect: {}
        )
        defer { session.stop() }
        session.markSurfaceResolutionUnavailable()
        #expect(session.connectionPresentation == nil)
        try await Self.waitUntil { session.connectionPresentation?.showsProgress == true }
        #expect(session.connectionPresentation?.showsReconnectButton == false)
        try await Self.waitUntil { session.connectionPresentation?.showsReconnectButton == true }

        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        session.reconnect(socketPath: fixture.socketPath)
        // The attempt that follows an exhausted grace is progress, not failure.
        #expect(session.connectionPresentation?.showsProgress == true)
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
