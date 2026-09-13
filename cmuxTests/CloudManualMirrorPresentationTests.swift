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
    func readinessGateKeepsLoadingAcrossOutOfOrderReplayAndFrameEvents() {
        var gate = CloudTerminalReadinessGate()
        gate.begin(baselineFrame: 10)

        // A replay may arrive before the native renderer is presented.
        let replayBeforeRenderer = gate.check(attachmentReady: true, rendererPresented: false, frameSequence: 11)
        #expect(!replayBeforeRenderer)
        #expect(gate.firstPresentedFrame == nil)
        // A frame from the old generation cannot dismiss the loader.
        let oldFrame = gate.check(attachmentReady: true, rendererPresented: true, frameSequence: 10)
        #expect(!oldFrame)
        #expect(gate.firstPresentedFrame == nil)
        let firstPresented = gate.check(attachmentReady: true, rendererPresented: true, frameSequence: 11)
        #expect(firstPresented)
        #expect(gate.firstPresentedFrame == 11)
        let secondPresented = gate.check(attachmentReady: true, rendererPresented: true, frameSequence: 12)
        #expect(!secondPresented)

        // Reconnect establishes a new generation baseline and requires a new frame.
        gate.begin(baselineFrame: 20)
        let reconnectBaseline = gate.check(attachmentReady: true, rendererPresented: true, frameSequence: 20)
        #expect(!reconnectBaseline)
        let reconnectFrame = gate.check(attachmentReady: true, rendererPresented: true, frameSequence: 21)
        #expect(reconnectFrame)
    }

    @Test
    func attachmentAloneDoesNotHideTheConnectionState() {
        #expect(CloudManualMirrorPresentation(phase: .attached, replayReceived: false).connectionState == .connecting)
        #expect(CloudManualMirrorPresentation(phase: .attached, replayReceived: true).connectionState == .connecting)
        #expect(CloudManualMirrorPresentation(phase: .attached, replayReceived: true, firstFramePresented: true).connectionState == .connected)
        #expect(CloudManualMirrorPresentation(phase: .disconnected, replayReceived: true).connectionState == .error)
    }

    @Test @MainActor
    func replayAloneKeepsTheCardUntilAVisibleFrame() async throws {
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
        #expect(session.connectionPresentation?.showsProgress == true)
        session.inputRouter.send(.bytes(Data("pwd\n".utf8)))
        let input = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(input.cmd == "send")
        #expect(input.surface == 17)
        // Renderer observations are absent, as during a portal handoff. The
        // healthy byte attachment remains visibly loading until a frame lands.
        #expect(hosted.surfaceView.renderedFrameSequence == 0)
        synchronize()
        #expect(owner.overlay?.currentPresentation?.showsProgress == true)
        for visible in [false, true] {
            owner.updateAnchor(anchor, visible: visible, ownershipGeneration: 1)
            synchronize()
            if visible {
                #expect(owner.overlay?.currentPresentation?.showsProgress == true)
            } else {
                #expect(owner.overlay == nil)
            }
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
