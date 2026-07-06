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

    // Regression repro for the "window hangs way too high, titlebar unreachable,
    // and I can't drag it back down" report after disconnecting an external
    // monitor that sat ABOVE the built-in display.
    //
    // Layout while docked: built-in display visibleFrame = {0,0 1512x944}; an
    // external monitor sits directly above it ({0,944 1920x1080}). The window
    // straddles the boundary — its body extends up into the external monitor and
    // its titlebar is high in that monitor's space.
    //
    // On disconnect only the built-in display remains. The window's frame is now
    // {300,884 1000x700}: its bottom 60pt still overlaps the built-in display, but
    // its titlebar (top 64pt) is at y≈1520, far above the built-in's visible top
    // (944) — i.e. off the top of every remaining screen and unreachable. Because
    // the window is non-movable (isMovable=false) and only draggable via the
    // titlebar handle, the user cannot pull it back down.
    //
    // AppKit's default constrain pass would clamp this window back onto the
    // built-in display. The #6305 override must NOT veto that clamp here: a frame
    // is only safely "reachable" if a grabbable strip of its TOP is on-screen.
    // This asserts the desired behavior and therefore FAILS on the current
    // 60x60-anywhere predicate, reproducing the bug.
    func testDoesNotPreserveFrameWhoseTitlebarIsStrandedAboveTheOnlyScreen() {
        let builtInVisible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let strandedAbove = NSRect(x: 300, y: 884, width: 1000, height: 700)
        // The bottom 60pt overlap with the built-in display is what the current
        // predicate latches onto; verify the repro geometry is the intended one.
        let overlap = strandedAbove.intersection(builtInVisible)
        XCTAssertEqual(overlap.height, 60, accuracy: 0.5)
        XCTAssertGreaterThan(strandedAbove.maxY, builtInVisible.maxY + 500)

        XCTAssertFalse(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(
                strandedAbove,
                visibleFrames: [builtInVisible]
            ),
            "A frame whose titlebar is stranded above the only screen must not be "
                + "preserved; AppKit needs to re-clamp it so the titlebar stays grabbable."
        )
    }

    // Guards against re-introducing the #6305 sleep/wake drift for a window
    // deliberately parked mostly off a side edge. Only ~90pt of the titlebar
    // width is on-screen — comfortably grabbable — so the frame must be
    // preserved rather than yanked back on the next constrain pass.
    func testPreservesFrameParkedAtSideEdgeWithGrabbableTitlebar() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let parkedLeft = NSRect(x: -910, y: 200, width: 1000, height: 600) // 90pt on-screen
        XCTAssertTrue(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(parkedLeft, visibleFrames: [visible])
        )
    }

    // Guards against re-introducing the #6305 drift on a large-menu-bar / notch
    // display: a window flush to the physical top has only a thin slice of its
    // titlebar clearing the ~44pt menu-bar inset, but it is fully on-screen and
    // must be preserved.
    func testPreservesFlushTopFrameOnLargeMenuBarDisplay() {
        // 44pt top inset (physical height 982, visible height 938).
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 938)
        let flushTop = NSRect(x: 300, y: 382, width: 1000, height: 600) // maxY 982 == physical top
        XCTAssertTrue(
            CmuxMainWindow.shouldPreserveFrameDuringConstrain(flushTop, visibleFrames: [visible])
        )
    }
}
#endif
