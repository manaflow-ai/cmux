import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud manual mirror presentation")
struct CloudManualMirrorPresentationTests {
    @Test
    func attachmentAloneDoesNotHideTheConnectionState() {
        #expect(CloudManualMirrorPresentation(phase: .attached, replayReceived: false).connectionState == .connecting)
        #expect(CloudManualMirrorPresentation(phase: .attached, replayReceived: true).connectionState == .connected)
        #expect(CloudManualMirrorPresentation(phase: .disconnected, replayReceived: true).connectionState == .error)
    }

    @Test @MainActor
    func replayDiagnosticsRequireTheCurrentFrame() async throws {
        let recorder = CloudOperationRecorder()
        let observation = CloudTerminalReplayPresentationDiagnostics(operations: recorder, isVisible: { true })
        defer { observation.reset() }
        observation.receive(1)
        observation.receive(2)
        observation.presented(1)
        #expect(recorder.operations.count == 1)
        #expect(recorder.operations[0].isRunning)
        observation.presented(2)
        try await waitForPresentationOutcome(recorder)
        #expect(recorder.operations[0].outcome == .success)
        #expect(recorder.operations[0].steps.first?.phase == .ready)
        #expect(recorder.operations[0].steps.first?.outcome == .success)
    }

    @Test @MainActor
    func hiddenReplayDefersObservationUntilReveal() async throws {
        let recorder = CloudOperationRecorder()
        var visible = false
        let observation = CloudTerminalReplayPresentationDiagnostics(operations: recorder, isVisible: { visible })
        defer { observation.reset() }
        observation.receive(1)
        #expect(recorder.operations.isEmpty)
        visible = true
        observation.visibilityChanged(true)
        #expect(recorder.operations.count == 1)
        visible = false
        observation.visibilityChanged(false)
        try await waitForPresentationOutcome(recorder)
        #expect(recorder.operations[0].outcome == .cancelled)
        #expect(!recorder.operations[0].needsAttention)
        visible = true
        observation.visibilityChanged(true)
        observation.presented(1)
        try await waitForPresentationOutcome(recorder)
        #expect(recorder.operations.count == 2)
        #expect(recorder.operations[1].outcome == .success)
    }

    @Test @MainActor
    func visibleReplayDeadlineRecordsOneDisplayFailure() async throws {
        let recorder = CloudOperationRecorder()
        let deadline = AsyncStream<Void>.makeStream()
        let observation = CloudTerminalReplayPresentationDiagnostics(
            operations: recorder, isVisible: { true },
            waitForDeadline: { for await _ in deadline.stream { return } }
        )
        defer { observation.reset(); deadline.continuation.finish() }
        observation.receive(1)
        deadline.continuation.yield(())
        try await waitForPresentationOutcome(recorder)
        #expect(recorder.operations[0].outcome == .timeout)
        #expect(recorder.operations[0].steps.first?.phase == .ready)
        observation.visibilityChanged(true)
        observation.receive(2)
        #expect(recorder.operations.count == 1)
    }

    @Test @MainActor
    func windowOcclusionCannotBecomeAPresentationFailure() async throws {
        let recorder = CloudOperationRecorder()
        let deadline = AsyncStream<Void>.makeStream()
        var visible = true
        let observation = CloudTerminalReplayPresentationDiagnostics(
            operations: recorder, isVisible: { visible },
            waitForDeadline: { for await _ in deadline.stream { return } }
        )
        defer { observation.reset(); deadline.continuation.finish() }
        observation.receive(1)
        // Window occlusion can change without a portal visibility event.
        visible = false
        deadline.continuation.yield(())
        try await waitForPresentationOutcome(recorder)
        #expect(recorder.operations[0].outcome == .cancelled)
        #expect(!recorder.operations[0].needsAttention)
        visible = true
        observation.presented(1)
        try await waitForPresentationOutcome(recorder)
        #expect(recorder.operations[1].outcome == .success)
    }

    @MainActor
    private func waitForPresentationOutcome(_ recorder: CloudOperationRecorder) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while recorder.operations.last?.isRunning == true, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(recorder.operations.last?.isRunning == false)
    }

    @Test @MainActor
    func usableAttachmentClearsTheCardWithoutRendererObservations() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_live", remoteSurfaceID: 17,
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
        synchronize()
        #expect(owner.overlay?.currentPresentation?.showsProgress == true)
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": identify.id, "ok": true, "data": ["protocol": 8]])
        let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": clientInfo.id, "ok": true])
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        fixture.send(["id": attach.id, "ok": true, "data": [:]])
        var deadline = ContinuousClock.now + .seconds(5)
        while session.phase != .attached, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.phase == .attached)
        synchronize()
        #expect(owner.overlay?.currentPresentation?.showsProgress == true)

        fixture.send([
            "event": "vt-state", "surface": 17, "cols": 80, "rows": 24,
            "data": Data("cmux@cloud> ".utf8).base64EncodedString()
        ])
        deadline = ContinuousClock.now + .seconds(5)
        while session.connectionPresentation != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.connectionPresentation == nil)
        session.inputRouter.send(.bytes(Data("pwd\n".utf8)))
        let input = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(input.cmd == "send")
        #expect(input.surface == 17)
        // Renderer observations are absent, as during a portal handoff. A
        // healthy byte attachment must not become a connection failure.
        #expect(hosted.surfaceView.renderedFrameSequence == 0)
        synchronize()
        #expect(owner.overlay == nil)
        for visible in [false, true] {
            owner.updateAnchor(anchor, visible: visible, ownershipGeneration: 1)
            synchronize()
            #expect(owner.overlay == nil)
        }

        // A real transport failure must still be shown after successful use.
        fixture.send(["event": "detached", "surface": 17])
        deadline = ContinuousClock.now + .seconds(5)
        while session.phase != .disconnected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.phase == .disconnected)
        synchronize()
        let error = try #require(owner.overlay?.currentPresentation)
        #expect(error.showsReconnectButton)
        #expect(!error.showsProgress)
        #expect(!error.copyableError.isEmpty)
    }

    @Test @MainActor
    func unavailableSurfaceResolutionRequestsRefreshOnceAndRemainsRetryable() {
        var reconnectRequests = 0
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: "term_0123456789abcdef0123456789abcdef",
            remoteSurfaceID: 17,
            onNeedsReconnect: { reconnectRequests += 1 }
        )
        defer { session.stop() }
        session.markSurfaceResolutionUnavailable()
        session.markSurfaceResolutionUnavailable()
        #expect(reconnectRequests == 1)
        #expect(session.connectionPresentation?.showsReconnectButton == true)
        #expect(session.retryConnection())
        #expect(reconnectRequests == 2)
        session.visibilityChanged(true)
        #expect(reconnectRequests == 3)
        session.stop()
        #expect(!session.retryConnection())
    }

    @Test @MainActor
    func reconnectFencesAnAttachedSocketBeforeRequestingFreshResolution() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        var refreshes = 0
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_0123456789abcdef0123456789abcdef",
            remoteSurfaceID: 17, onNeedsReconnect: { refreshes += 1 }
        )
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath)
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": identify.id, "ok": true, "data": ["protocol": 8]])
        let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": clientInfo.id, "ok": true])
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        fixture.send(["id": attach.id, "ok": true, "data": [:]])
        let deadline = ContinuousClock.now + .seconds(5)
        while session.phase != .attached, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.phase == .attached)
        #expect(session.retryConnection())
        #expect(session.phase == .disconnected)
        #expect(refreshes == 1)
        #expect(session.remoteSurfaceID == 17)
        #expect(session.connectionPresentation?.showsReconnectButton == true)
    }

    @Test @MainActor
    func retiringAnOldSessionCannotRemoveItsReplacementsCard() {
        let old = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_old", remoteSurfaceID: 17, onNeedsReconnect: {}
        )
        let replacement = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_new", remoteSurfaceID: 18, onNeedsReconnect: {}
        )
        defer { old.stop(); replacement.stop() }
        let owner = CloudTerminalOverlayCoordinator()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        owner.session = replacement
        owner.apply(replacement.connectionPresentation, in: anchor, frame: anchor.bounds) {}
        owner.unbindSession(old)
        #expect(owner.session === replacement)
        #expect(owner.overlay?.superview === anchor)
        owner.unbindSession(replacement)
        #expect(owner.session == nil)
        #expect(anchor.subviews.isEmpty)
    }

    @Test @MainActor
    func oneCardMovesBetweenAnchorAndPortalAndUsesTheLatestRecovery() throws {
        let owner = CloudTerminalOverlayCoordinator()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let portal = NSView(frame: anchor.frame)
        let connecting = CloudTerminalReconnectOverlayPolicy.Presentation(
            title: "Connecting", detail: "Waiting", showsProgress: true, showsReconnectButton: false
        )
        var actions: [String] = []
        owner.apply(connecting, in: anchor, frame: anchor.bounds) { actions.append("stale") }
        let card = try #require(owner.overlay)
        #expect(card.superview === anchor)
        let failed = CloudTerminalReconnectOverlayPolicy.Presentation(
            title: "Unavailable", detail: "Retry", showsProgress: false, showsReconnectButton: true
        )
        owner.apply(failed, in: portal, frame: portal.bounds) { actions.append("current") }
        #expect(owner.overlay === card)
        #expect(anchor.subviews.isEmpty)
        #expect(card.superview === portal)
        #expect(card.currentPresentation == failed)
        card.onReconnect?()
        #expect(actions == ["current"])
        owner.apply(nil, in: portal, frame: portal.bounds) {}
        #expect(owner.overlay == nil)
        #expect(portal.subviews.isEmpty)
    }
}
