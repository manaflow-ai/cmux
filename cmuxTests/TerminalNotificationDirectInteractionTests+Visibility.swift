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

    func testWarmVisibilityRestoreSkipsRefreshWhileTerminalIsInactive() throws {
#if DEBUG
        try assertInactiveVisibilityRestoreRefreshCount(
            presentedFrameBeforeReveal: true,
            expected: 0,
            "A renderer that already presented a frame keeps it across the hide; revealing it must not force a blocking redraw"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

#if DEBUG
    /// Whether a reveal forces a redraw depends on whether the renderer has
    /// presented a frame (#14044). The test pins that state while the portal
    /// is hidden instead of inheriting whatever the GPU presented during setup.
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
        if expected == 0 {
            // The deferred refresh re-checks the presented frame, so a wrongly
            // scheduled one would not show up in the refresh count below.
            XCTAssertFalse(
                hostedView.hasVisibilityRevealRefreshScheduled,
                "A warm reveal must not schedule a deferred refresh",
                file: file,
                line: line
            )
        }
        drainMainQueue()
        if expected > 0 {
            // The reveal redraw runs on a later main-queue turn; wait for it.
            _ = waitUntil(timeout: 2.0) { surface.debugForceRefreshCount() >= expected }
        } else {
            // Give a wrongly scheduled deferred redraw the same turns to land.
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            drainMainQueue()
        }

        XCTAssertEqual(surface.debugForceRefreshCount(), expected, message, file: file, line: line)
    }
#endif

}
