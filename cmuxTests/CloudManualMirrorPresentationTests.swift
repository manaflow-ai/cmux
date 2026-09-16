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
    @Test("Repeated recovery preserves a usable stream across pane visibility changes", arguments: [false, true])
    @MainActor
    func repeatedRecoveryDoesNotFlashOrReuseAnOldSurface(replayFirst: Bool) async throws {
        var recoveries = 0
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_recovery", remoteSurfaceID: 17,
            presentationPolicy: .immediate,
            onNeedsReconnect: { recoveries += 1 }
        )
        defer { session.stop() }
        let frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let hosted = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: frame))
        let anchor = GhosttyTerminalView.HostContainerView(frame: frame)
        let owner = hosted.cloudTerminalOverlay
        owner.session = session
        owner.updateAnchor(anchor, visible: true, ownershipGeneration: 1)

        // Reuse one session while the daemon-local surface and socket change.
        // No renderer callback is supplied: connection health must remain
        // independent of a hidden, occluded, or newly reparented native view.
        for cycle in 0..<8 {
            let fixture = try CloudManualMirrorSocketFixture()
            defer { fixture.close() }
            let surfaceID = UInt64(17 + cycle)
            session.updateRemoteSurfaceID(surfaceID)
            session.reconnect(socketPath: fixture.socketPath)
            let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
            #expect(identify.cmd == "identify")
            fixture.send(["id": identify.id, "ok": true, "data": ["protocol": 12]])
            let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
            #expect(clientInfo.cmd == "set-client-info")
            fixture.send(["id": clientInfo.id, "ok": true])
            let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
            #expect(attach.cmd == "attach-surface")
            #expect(attach.surface == surfaceID)
            let replay: [String: Any] = [
                "event": "vt-state", "surface": surfaceID, "cols": 80, "rows": 24,
                "data": Data("retained history> ".utf8).base64EncodedString()
            ]
            let acknowledgement: [String: Any] = ["id": attach.id, "ok": true, "data": [:]]
            fixture.send(replayFirst ? replay : acknowledgement)
            fixture.send(replayFirst ? acknowledgement : replay)
            try await waitForSession {
                session.phase == .attached && session.connectionPresentation == nil
            }

            for _ in 0..<10 {
                session.visibilityChanged(false)
                owner.updateAnchor(anchor, visible: false, ownershipGeneration: 1)
                owner.synchronize(hostedView: hosted, contentFrame: frame, legacyPresentation: nil) {}
                #expect(owner.overlay == nil)
                let release = try #require(await fixture.nextCommand(timeout: .seconds(5)))
                #expect(release.cmd == "release-surface-size")
                #expect(release.surface == surfaceID)
                session.visibilityChanged(true)
                session.visibilityChanged(true)
                session.reconnect(socketPath: fixture.socketPath)
                owner.updateAnchor(anchor, visible: true, ownershipGeneration: 1)
                owner.synchronize(hostedView: hosted, contentFrame: frame, legacyPresentation: nil) {}
                #expect(session.phase == .attached)
                #expect(owner.overlay == nil)
                #expect(recoveries == cycle)
            }

            // A stale detach from a retired numeric surface must not close
            // this attachment. Reading the input command also fences all
            // preceding client commands and catches duplicate attach calls.
            fixture.send(["event": "detached", "surface": surfaceID + 100])
            session.inputRouter.send(.bytes(Data("echo cycle-\(cycle)\n".utf8)))
            let input = try #require(await fixture.nextCommand(timeout: .seconds(5)))
            #expect(input.cmd == "send")
            #expect(input.surface == surfaceID)
            #expect(session.phase == .attached)
            fixture.send(["event": "detached", "surface": surfaceID])
            try await waitForSession { session.phase == .disconnected }
            #expect(recoveries == cycle + 1)
            owner.synchronize(hostedView: hosted, contentFrame: frame, legacyPresentation: nil) {}
            #expect(owner.overlay?.currentPresentation?.showsReconnectButton == true)
        }
    }

    @MainActor
    private func waitForSession(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try Task.checkCancellation()
            await Task.yield()
        }
        try #require(condition())
    }

    @Test
    func attachmentAloneDoesNotHideTheConnectionState() {
        #expect(CloudManualMirrorPresentation(phase: .idle, replayReceived: false).connectionState == nil)
        #expect(CloudManualMirrorPresentation(phase: .attached, replayReceived: false).connectionState == .connecting)
        #expect(CloudManualMirrorPresentation(phase: .attached, replayReceived: true).connectionState == .connected)
        #expect(CloudManualMirrorPresentation(phase: .disconnected, replayReceived: true).connectionState == .error)
    }

    @Test @MainActor
    func cancellingAnActiveConnectionSuppressesAutomaticRecovery() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        var refreshes = 0
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_cancel", remoteSurfaceID: 17,
            onNeedsReconnect: { refreshes += 1 }
        )
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath)
        #expect(session.phase == .connecting)
        #expect(session.cancelConnectionAttempt())
        #expect(session.phase == .idle)
        #expect(!session.allowsAutomaticReconnect)
        #expect(refreshes == 0)
        session.visibilityChanged(true)
        #expect(refreshes == 0)
        #expect(session.connectionPresentation == nil)
        #expect(session.retryConnection())
        #expect(session.allowsAutomaticReconnect)
        #expect(refreshes == 1)
    }

    @Test @MainActor
    func progressCardDismissalInvokesCancellationCallback() throws {
        let owner = CloudTerminalOverlayCoordinator()
        let destination = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let progress = CloudTerminalReconnectOverlayPolicy.Presentation(
            title: "Connecting", detail: "Waiting", showsProgress: true, showsReconnectButton: false
        )
        var cancelled = 0
        owner.apply(progress, in: destination, frame: destination.bounds, dismissalID: "cancel-test", onReconnect: {}, onCancel: {
            cancelled += 1
        })
        let card = try #require(owner.overlay)
        card.onDismiss?()
        #expect(cancelled == 1)
        #expect(owner.overlay == nil)
    }

    @Test @MainActor
    func coordinatorRemovesReconnectCardWhenReadySnapshotArrives() throws {
        let owner = CloudTerminalOverlayCoordinator()
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        )
        let anchor = GhosttyTerminalView.HostContainerView(frame: hosted.bounds)
        owner.updateAnchor(anchor, visible: true, ownershipGeneration: 1)
        let reconnecting = CloudTerminalReconnectOverlayPolicy.Presentation(
            title: "Reconnecting", detail: "Waiting", showsProgress: true, showsReconnectButton: false
        )
        owner.synchronize(
            hostedView: hosted,
            contentFrame: hosted.bounds,
            legacyPresentation: reconnecting,
            onReconnect: {}
        )
        #expect(owner.overlay != nil)

        owner.synchronize(
            hostedView: hosted,
            contentFrame: hosted.bounds,
            legacyPresentation: nil,
            onReconnect: {}
        )
        #expect(owner.overlay == nil)
        #expect(anchor.subviews.isEmpty)
    }

    @Test @MainActor
    func usableAttachmentClearsTheCardWithoutRendererObservations() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_live", remoteSurfaceID: 17,
            presentationPolicy: .immediate,
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
        #expect(owner.overlay == nil)
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
        #expect(owner.overlay == nil)

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
    func unavailableSurfaceResolutionLeavesRefreshToProviderAndRemainsRetryable() async throws {
        var reconnectRequests = 0
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: "term_0123456789abcdef0123456789abcdef",
            remoteSurfaceID: 17,
            presentationPolicy: CloudTerminalConnectionPresentationPolicy(failureGrace: .milliseconds(80)),
            onNeedsReconnect: { reconnectRequests += 1 }
        )
        defer { session.stop() }
        session.markSurfaceResolutionUnavailable()
        session.markSurfaceResolutionUnavailable()
        // The provider schedules resolution retries with backoff. A failed
        // resolution must not immediately request the same refresh again, and
        // while that automatic recovery runs the pane stays quiet; Reconnect is
        // offered only once recovery keeps failing.
        #expect(reconnectRequests == 0)
        #expect(session.connectionPresentation == nil)
        try await waitForSession { session.connectionPresentation?.showsReconnectButton == true }
        #expect(session.retryConnection())
        #expect(reconnectRequests == 1)
        session.visibilityChanged(true)
        #expect(reconnectRequests == 2)
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
        // An explicit Reconnect clears the card while the attempt runs; it is
        // not reported as a failure.
        #expect(session.connectionPresentation == nil)
    }

    @Test @MainActor
    func retiringAnOldSessionCannotRemoveItsReplacementsCard() {
        let old = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_old", remoteSurfaceID: 17, onNeedsReconnect: {}
        )
        let replacement = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_new", remoteSurfaceID: 18,
            presentationPolicy: .immediate, onNeedsReconnect: {}
        )
        defer { old.stop(); replacement.stop() }
        let owner = CloudTerminalOverlayCoordinator()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        replacement.markSurfaceResolutionUnavailable()
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
