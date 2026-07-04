import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor @Suite
struct CmuxMainWindowConstrainFrameTests {
    // On a display/system sleep→wake, AppKit re-runs its constrain pass over
    // every window and repositions even windows that are already fully
    // on-screen; cmux never re-asserts its saved frame afterward, so the window
    // creeps each sleep cycle. CmuxMainWindow.constrainFrameRect must leave an
    // on-screen frame untouched so AppKit can no longer move it. A titlebar
    // flush under the menu bar is one such on-screen frame (and an easy,
    // deterministic one to construct), but it is not the only triggering
    // arrangement — see the screen-agnostic helper cases below.
    @Test
    func constrainPreservesOnScreenFrameOverlappingMenuBar() throws {
        let screen = try #require(NSScreen.main, "No screen available for constrainFrameRect regression")
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        let size = NSSize(width: 800, height: 600)
        // Flush against the very top of the physical screen so the titlebar
        // overlaps the menu bar — one on-screen placement AppKit's default
        // constrain pass would push downward.
        let proposed = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        let constrained = window.constrainFrameRect(proposed, to: screen)

        #expect(abs(constrained.origin.x - proposed.origin.x) <= 0.5)
        #expect(abs(constrained.origin.y - proposed.origin.y) <= 0.5)
        #expect(abs(constrained.size.width - proposed.size.width) <= 0.5)
        #expect(abs(constrained.size.height - proposed.size.height) <= 0.5)
    }

    // The decision helper is screen-agnostic, so these cases run deterministically
    // on CI regardless of the test host's display configuration.

    @Test
    func preservesFrameFullyInsideVisibleArea() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 100, y: 100, width: 800, height: 600)
        #expect(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible])
        )
    }

    @Test
    func preservesFrameWhoseTitlebarOverlapsMenuBarBand() {
        // The visible area excludes a 37pt menu-bar band at the top; the window's
        // titlebar pokes into it — the placement AppKit would otherwise push down.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 863)
        let frame = NSRect(x: 320, y: 263, width: 800, height: 637) // maxY 900 > 863
        #expect(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible])
        )
    }

    @Test
    func doesNotPreserveFrameStrandedOffScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 3000, y: 2000, width: 800, height: 600)
        #expect(
            !CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible])
        )
    }

    @Test
    func doesNotPreserveBarelyPeekingFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Only ~20pt of the window overlaps the bottom-left corner — not grabbable.
        let frame = NSRect(x: -780, y: -580, width: 800, height: 600)
        #expect(
            !CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible])
        )
    }

    @Test
    func doesNotPreserveWhenNoScreensAvailable() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        #expect(
            !CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [])
        )
    }

    // MARK: - Inactive display-transition frame restore (issue #5492)
    //
    // While the app is in another app and the display sleeps/wakes, a main
    // window can come back genuinely resized to a ~2/3 (default-sized) frame
    // via a path constrainFrameRect can't undo. Because a frame change while
    // the app is inactive is never user-driven, reverting to the frame the user
    // last left it at is safe.

    @Test
    func restoresFrameThatShrankWhileInactive() {
        // 1000×700 ≈ the default window, ~2/3 the width of a 1512pt MacBook display.
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let maximized = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let shrunkToDefault = NSRect(x: 256, y: 122, width: 1000, height: 700)
        #expect(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: shrunkToDefault,
                beforeDeactivation: maximized,
                visibleFrames: [visible]
            ) == maximized
        )
    }

    @Test
    func doesNotRestoreWhenFrameUnchanged() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 944)
        #expect(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: frame,
                beforeDeactivation: frame,
                visibleFrames: [visible]
            ) == nil
        )
    }

    @Test
    func doesNotRestoreWhenWindowGrewWhileInactive() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let small = NSRect(x: 100, y: 100, width: 800, height: 600)
        let large = NSRect(x: 0, y: 0, width: 1400, height: 900)
        #expect(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: large,
                beforeDeactivation: small,
                visibleFrames: [visible]
            ) == nil
        )
    }

    @Test
    func doesNotRestorePreviousFrameStrandedOffScreen() {
        // The window was maximized on an external display that is now unplugged;
        // its previous frame no longer overlaps any current screen, so leave the
        // already-on-screen shrunken frame alone rather than push it off-screen.
        let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let onExternal = NSRect(x: 3000, y: 0, width: 2560, height: 1440)
        let clampedToBuiltIn = NSRect(x: 256, y: 122, width: 1000, height: 700)
        #expect(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: clampedToBuiltIn,
                beforeDeactivation: onExternal,
                visibleFrames: [builtIn]
            ) == nil
        )
    }

    @Test
    func doesNotRestorePreviousFrameMostlyOffScreen() {
        // Old frame straddled an adjacent external display that is now unplugged:
        // it still overlaps the built-in by >60pt (passes the constrain
        // reachability bar) but only ~7% of its area is on-screen, so restoring
        // it would push the window mostly off-screen. Must refuse.
        let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let mostlyOffScreen = NSRect(x: 1400, y: 0, width: 1500, height: 900)
        let current = NSRect(x: 256, y: 122, width: 1000, height: 700)
        #expect(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: current,
                beforeDeactivation: mostlyOffScreen,
                visibleFrames: [builtIn]
            ) == nil
        )
    }

    @Test
    func doesNotRestorePreviousFrameLargerThanCurrentDisplay() {
        // Display woke at a smaller mode; the old maximized frame no longer fits,
        // so restoring it would overflow the current display. Must refuse.
        let smallerMode = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let oldLarge = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let current = NSRect(x: 140, y: 90, width: 1000, height: 620)
        #expect(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: current,
                beforeDeactivation: oldLarge,
                visibleFrames: [smallerMode]
            ) == nil
        )
    }

    @Test
    func doesNotRestoreOnNegligibleShrink() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let before = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let tinyShrink = NSRect(x: 0, y: 0, width: 1500, height: 936) // <40pt in both dims
        #expect(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: tinyShrink,
                beforeDeactivation: before,
                visibleFrames: [visible]
            ) == nil
        )
    }

    @Test
    func applyRestoresShrunkWindowFrame() throws {
        let screen = try #require(NSScreen.main, "No screen available for inactive-display-transition restore")
        let visible = screen.visibleFrame
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        // A "shrunk to ~2/3" frame fully inside the visible area.
        let shrunk = NSRect(
            x: visible.minX + 40,
            y: visible.minY + 40,
            width: min(900, visible.width - 80),
            height: min(600, visible.height - 80)
        )
        window.setFrame(shrunk, display: false)

        // The larger frame the user left it at (the full visible area).
        let restoredTarget = visible
        let didRestore = CmuxMainWindow.applyRestoredFrameAfterInactiveDisplayTransition(
            to: window,
            frameBeforeDeactivation: restoredTarget,
            visibleFrames: [visible]
        )

        #expect(didRestore)
        #expect(abs(window.frame.width - restoredTarget.width) <= 1.0)
        #expect(abs(window.frame.height - restoredTarget.height) <= 1.0)
    }

    // MARK: - MainWindowFrameRestorer gating (issue #5492)

    private func makeTestMainWindow() -> CmuxMainWindow {
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func shrunkFrame(in visible: NSRect) -> NSRect {
        NSRect(
            x: visible.minX + 40,
            y: visible.minY + 40,
            width: min(900, visible.width - 80),
            height: min(600, visible.height - 80)
        )
    }

    @Test
    func restorerRestoresShrunkWindowAfterInactiveDisplayTransition() throws {
        let screen = try #require(NSScreen.main, "No screen available for MainWindowFrameRestorer")
        let visible = screen.visibleFrame
        let window = makeTestMainWindow()
        defer { window.orderOut(nil); window.close() }

        window.setFrame(visible, display: false)
        let restorer = MainWindowFrameRestorer()
        restorer.captureFrames(of: [window])
        restorer.noteDisplayTransition(appIsActive: false) // display slept while away

        window.setFrame(shrunkFrame(in: visible), display: false)
        restorer.restoreIfNeeded(windows: [window], visibleFrames: [visible])

        #expect(abs(window.frame.width - visible.width) <= 1.0)
        #expect(abs(window.frame.height - visible.height) <= 1.0)
    }

    @Test
    func restorerLeavesWindowAloneWithoutDisplayTransition() throws {
        // The regression the review caught: a background resize NOT tied to a
        // display transition (keyboard window manager, AppleScript, macOS window
        // management) must be left alone, not reverted on the next activation.
        let screen = try #require(NSScreen.main, "No screen available for MainWindowFrameRestorer")
        let visible = screen.visibleFrame
        let window = makeTestMainWindow()
        defer { window.orderOut(nil); window.close() }

        window.setFrame(visible, display: false)
        let restorer = MainWindowFrameRestorer()
        restorer.captureFrames(of: [window])
        // No noteDisplayTransition: no display transition observed.

        let shrunk = shrunkFrame(in: visible)
        window.setFrame(shrunk, display: false)
        restorer.restoreIfNeeded(windows: [window], visibleFrames: [visible])

        #expect(
            abs(window.frame.width - shrunk.width) <= 1.0,
            "Without an observed display transition the window must not be resized"
        )
        #expect(abs(window.frame.height - shrunk.height) <= 1.0)
    }

    @Test
    func restorerIgnoresTransitionObservedWhileActive() throws {
        let screen = try #require(NSScreen.main, "No screen available for MainWindowFrameRestorer")
        let visible = screen.visibleFrame
        let window = makeTestMainWindow()
        defer { window.orderOut(nil); window.close() }

        window.setFrame(visible, display: false)
        let restorer = MainWindowFrameRestorer()
        restorer.captureFrames(of: [window])
        restorer.noteDisplayTransition(appIsActive: true) // transition while active is not armed

        let shrunk = shrunkFrame(in: visible)
        window.setFrame(shrunk, display: false)
        restorer.restoreIfNeeded(windows: [window], visibleFrames: [visible])

        #expect(abs(window.frame.width - shrunk.width) <= 1.0)
    }
}
#endif
