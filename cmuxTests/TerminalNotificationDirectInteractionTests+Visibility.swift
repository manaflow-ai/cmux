import XCTest
import AppKit
import CmuxTerminal
import CmuxTerminalCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalNotificationDirectInteractionTests {
    func testPresentedRendererSkipsRedundantDeferredRefresh() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let livePortalWorkspace = try makeAuthorizedPortalTabId()
        defer { livePortalWorkspace.tearDown() }

        let surface = TerminalSurface(
            tabId: livePortalWorkspace.id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        defer { surface.releaseHostedSurfaceForTesting() }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        hostedView.setVisibleInUI(true)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        waitForRuntimeSurface(surface, file: #filePath, line: #line)
        guard surface.surface != nil else { return }
        XCTAssertTrue(
            waitUntil(timeout: 5.0) { surface.isRendererPresented },
            "Expected the visible renderer to present before testing the reveal policy"
        )
        drainMainQueue()

        surface.resetDebugForceRefreshCount()
        // A renderer can present after a reveal queues its fallback but before
        // the callback runs. Exercise that callback's current-health guard.
        hostedView.scheduleVisibilityRevealRefresh(transition: .reveal)
        XCTAssertTrue(
            hostedView.hasVisibilityRevealRefreshScheduled,
            "Expected a pending callback to exercise the deferred refresh guard"
        )
        drainMainQueue()
        XCTAssertFalse(hostedView.hasVisibilityRevealRefreshScheduled)
        XCTAssertEqual(surface.debugForceRefreshCount(), 0)
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testVisibilityRestoreRefreshesSurfaceWhileTerminalIsInactive() throws {
#if DEBUG
        try assertInactiveVisibilityRestoreRefreshCount(
            presentedFrameBeforeReveal: false,
            expected: 1,
            "Restoring a portal whose renderer never presented a frame should force a redraw even when focus recovery is inactive"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testWarmVisibilityRestoreRefreshesAfterRendererLossWhileTerminalIsInactive() throws {
#if DEBUG
        try assertInactiveVisibilityRestoreRefreshCount(
            presentedFrameBeforeReveal: true,
            expected: 1,
            "A historical frame must not suppress the reveal redraw after the renderer is no longer presented"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

#if DEBUG
    /// The reveal fallback depends on whether the renderer is currently
    /// presented, rather than on whether it presented a historical frame
    /// (#14044). The test pins that historical state while the portal is hidden
    /// instead of inheriting whatever the GPU presented during setup.
    private func assertInactiveVisibilityRestoreRefreshCount(
        presentedFrameBeforeReveal: Bool,
        expected: Int,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let livePortalWorkspace = try makeAuthorizedPortalTabId()
        defer { livePortalWorkspace.tearDown() }

        let surface = TerminalSurface(
            tabId: livePortalWorkspace.id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        defer { surface.releaseHostedSurfaceForTesting() }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        hostedView.setVisibleInUI(true)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        waitForRuntimeSurface(surface, file: file, line: line)
        guard surface.surface != nil else { return }

        hostedView.setActive(false)
        hostedView.setVisibleInUI(false)
        drainMainQueue(file: file, line: line)

        surface.setRendererPresentedFrameForTesting(presentedFrameBeforeReveal)
        surface.resetDebugForceRefreshCount()
        hostedView.setVisibleInUI(true)
        // Revealing asks the surface to present again and can create a new
        // presentation probe. Pin the fixture after that transition too, so a
        // late probe acknowledgement cannot race the deferred callback.
        surface.setRendererPresentedFrameForTesting(presentedFrameBeforeReveal)
        XCTAssertEqual(surface.hasPresentedFrame, presentedFrameBeforeReveal, file: file, line: line)
        XCTAssertFalse(surface.isRendererPresented, file: file, line: line)
        XCTAssertTrue(
            hostedView.hasVisibilityRevealRefreshScheduled,
            "An unpresented renderer must schedule the reveal fallback",
            file: file,
            line: line
        )
        XCTAssertEqual(
            surface.debugForceRefreshCount(), 0,
            "The reveal must defer its redraw until after the visibility update",
            file: file,
            line: line
        )
        drainMainQueue(file: file, line: line)
        XCTAssertFalse(hostedView.hasVisibilityRevealRefreshScheduled, file: file, line: line)

        XCTAssertEqual(surface.debugForceRefreshCount(), expected, message, file: file, line: line)
    }
#endif

}
