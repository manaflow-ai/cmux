import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalWindowPortalTransientRecoveryTests {
    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func drainMainQueueTurn() {
        var didDrain = false
        DispatchQueue.main.async {
            didDrain = true
        }
        waitUntil { didDrain }
    }

    @Test func externalGeometryTinyFrameSchedulesSelfRecoveryAfterAnchorSettles() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)
        let stableFrame = NSRect(x: 40, y: 60, width: 260, height: 180)
        let anchor = NSView(frame: stableFrame)
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        defer { TerminalWindowPortalRegistry.detach(hostedView: hosted) }
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        drainMainQueueTurn()

        #expect(!hosted.isHidden)
        #expect(hosted.frame.height > 100)

        let visibleFrameBeforeTransient = hosted.frame
        anchor.frame = NSRect(x: stableFrame.minX, y: stableFrame.minY, width: stableFrame.width, height: 0)
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)

        #expect(
            !hosted.isHidden,
            "A queued transient recovery should not hide an already-visible terminal before the retry runs"
        )
        #expect(hosted.frame.width == visibleFrameBeforeTransient.width)
        #expect(hosted.frame.height == visibleFrameBeforeTransient.height)

        var didRestoreAnchor = false
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        DispatchQueue.main.async {
            anchor.frame = stableFrame
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            didRestoreAnchor = true
        }
        waitUntil {
            didRestoreAnchor &&
                !hosted.isHidden &&
                hosted.frame.height > 100
        }

        #expect(
            !hosted.isHidden,
            "A one-turn tiny external geometry transient should self-recover without a later user event"
        )
        #expect(hosted.frame.height > 100)
    }

    @Test func transientRecoverySurvivesReasonChangeAfterRetryBudgetExhausted() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)
        let stableFrame = NSRect(x: 40, y: 60, width: 260, height: 180)
        let anchor = NSView(frame: stableFrame)
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        defer { TerminalWindowPortalRegistry.detach(hostedView: hosted) }
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        drainMainQueueTurn()

        #expect(!hosted.isHidden)

        // Phase 1: drive a persistent `anchorHidden` transient and fully spend
        // the per-reason retry budget for that reason. Each synchronize is
        // synchronous and decrements the budget, so looping well past the
        // budget guarantees it is exhausted without depending on run-loop
        // timing.
        anchor.isHidden = true
        contentView.layoutSubtreeIfNeeded()
        for _ in 0..<24 {
            TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        }
        drainMainQueueTurn()
        #expect(hosted.isHidden)

        // Phase 2: switch to a *different* transient reason (a zero-height frame
        // → outsideHostBounds) without ever passing through a healthy sync that
        // would refresh the budget, then let the anchor settle on a later
        // run-loop turn with no explicit re-sync. Recovery for the new reason
        // must still be scheduled; otherwise the terminal stays hidden until an
        // unrelated geometry or user event happens.
        anchor.isHidden = false
        anchor.frame = NSRect(x: stableFrame.minX, y: stableFrame.minY, width: stableFrame.width, height: 0)
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        var didRestoreAnchor = false
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        DispatchQueue.main.async {
            anchor.frame = stableFrame
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            didRestoreAnchor = true
        }
        waitUntil {
            didRestoreAnchor &&
                !hosted.isHidden &&
                hosted.frame.height > 100
        }

        #expect(
            !hosted.isHidden,
            "A transient reason change after the per-reason retry budget is exhausted must still self-recover"
        )
        #expect(hosted.frame.height > 100)
    }
}
