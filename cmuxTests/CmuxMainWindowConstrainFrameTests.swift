import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
final class CmuxMainWindowConstrainFrameTests: XCTestCase {
    // On a display/system sleep→wake, AppKit re-runs its constrain pass over
    // every window and repositions even windows that are already fully
    // on-screen; cmux never re-asserts its saved frame afterward, so the window
    // creeps each sleep cycle. CmuxMainWindow.constrainFrameRect must leave an
    // on-screen frame untouched so AppKit can no longer move it. A titlebar
    // flush under the menu bar is one such on-screen frame (and an easy,
    // deterministic one to construct), but it is not the only triggering
    // arrangement — see the screen-agnostic helper cases below.
    func testConstrainPreservesOnScreenFrameOverlappingMenuBar() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available for constrainFrameRect regression")
        }
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

        XCTAssertEqual(constrained.origin.x, proposed.origin.x, accuracy: 0.5)
        XCTAssertEqual(constrained.origin.y, proposed.origin.y, accuracy: 0.5)
        XCTAssertEqual(constrained.size.width, proposed.size.width, accuracy: 0.5)
        XCTAssertEqual(constrained.size.height, proposed.size.height, accuracy: 0.5)
    }

    // The decision helper is screen-agnostic, so these cases run deterministically
    // on CI regardless of the test host's display configuration.

    func testPreservesFrameFullyInsideVisibleArea() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible])
        )
    }

    func testPreservesFrameWhoseTitlebarOverlapsMenuBarBand() {
        // The visible area excludes a 37pt menu-bar band at the top; the window's
        // titlebar pokes into it — the placement AppKit would otherwise push down.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 863)
        let frame = NSRect(x: 320, y: 263, width: 800, height: 637) // maxY 900 > 863
        XCTAssertTrue(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible])
        )
    }

    func testDoesNotPreserveFrameStrandedOffScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 3000, y: 2000, width: 800, height: 600)
        XCTAssertFalse(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible])
        )
    }

    func testDoesNotPreserveBarelyPeekingFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Only ~20pt of the window overlaps the bottom-left corner — not grabbable.
        let frame = NSRect(x: -780, y: -580, width: 800, height: 600)
        XCTAssertFalse(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible])
        )
    }

    func testDoesNotPreserveWhenNoScreensAvailable() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [])
        )
    }

    // MARK: - Inactive display-transition frame restore (issue #5492)
    //
    // While the app is in another app and the display sleeps/wakes, a main
    // window can come back genuinely resized to a ~2/3 (default-sized) frame
    // via a path constrainFrameRect can't undo. Because a frame change while
    // the app is inactive is never user-driven, reverting to the frame the user
    // last left it at is safe.

    func testRestoresFrameThatShrankWhileInactive() {
        // 1000×700 ≈ the default window, ~2/3 the width of a 1512pt MacBook display.
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let maximized = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let shrunkToDefault = NSRect(x: 256, y: 122, width: 1000, height: 700)
        XCTAssertEqual(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: shrunkToDefault,
                beforeDeactivation: maximized,
                visibleFrames: [visible]
            ),
            maximized
        )
    }

    func testDoesNotRestoreWhenFrameUnchanged() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 944)
        XCTAssertNil(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: frame,
                beforeDeactivation: frame,
                visibleFrames: [visible]
            )
        )
    }

    func testDoesNotRestoreWhenWindowGrewWhileInactive() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let small = NSRect(x: 100, y: 100, width: 800, height: 600)
        let large = NSRect(x: 0, y: 0, width: 1400, height: 900)
        XCTAssertNil(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: large,
                beforeDeactivation: small,
                visibleFrames: [visible]
            )
        )
    }

    func testDoesNotRestorePreviousFrameStrandedOffScreen() {
        // The window was maximized on an external display that is now unplugged;
        // its previous frame no longer overlaps any current screen, so leave the
        // already-on-screen shrunken frame alone rather than push it off-screen.
        let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let onExternal = NSRect(x: 3000, y: 0, width: 2560, height: 1440)
        let clampedToBuiltIn = NSRect(x: 256, y: 122, width: 1000, height: 700)
        XCTAssertNil(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: clampedToBuiltIn,
                beforeDeactivation: onExternal,
                visibleFrames: [builtIn]
            )
        )
    }

    func testDoesNotRestoreOnNegligibleShrink() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let before = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let tinyShrink = NSRect(x: 0, y: 0, width: 1500, height: 936) // <40pt in both dims
        XCTAssertNil(
            CmuxMainWindow.restoredFrameAfterInactiveDisplayTransition(
                current: tinyShrink,
                beforeDeactivation: before,
                visibleFrames: [visible]
            )
        )
    }

    func testApplyRestoresShrunkWindowFrame() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available for inactive-display-transition restore")
        }
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

        XCTAssertTrue(didRestore)
        XCTAssertEqual(window.frame.width, restoredTarget.width, accuracy: 1.0)
        XCTAssertEqual(window.frame.height, restoredTarget.height, accuracy: 1.0)
    }
}
#endif
