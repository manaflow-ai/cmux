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
    func testPresentedRendererRevealSkipsDeferredRefresh() throws {
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

        surface.resetDebugForceRefreshCount()
        if GhosttySurfaceScrollView.shouldScheduleVisibilityRevealRefresh(
            rendererPresented: surface.isRendererPresented
        ) {
            hostedView.scheduleVisibilityRevealRefresh(transition: .reveal)
        }
        XCTAssertFalse(
            hostedView.hasVisibilityRevealRefreshScheduled,
            "A currently presented renderer must not enter the deferred reveal path"
        )
        drainMainQueue()
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        surface.setRendererPresentedFrameForTesting(presentedFrameBeforeReveal)
        surface.resetDebugForceRefreshCount()
        hostedView.setVisibleInUI(true)
        drainMainQueue()
        // The reveal redraw runs on a later main-queue turn; wait for it.
        _ = waitUntil(timeout: 2.0) { surface.debugForceRefreshCount() >= expected }

        XCTAssertEqual(surface.debugForceRefreshCount(), expected, message, file: file, line: line)
    }
#endif

}
