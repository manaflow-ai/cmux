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

    // MARK: - WindowTitlebarReachability (shared predicate)

    func testReachabilityFullyInsideVisibleAreaPassesBothThresholds() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [visible], thresholds: .lenient)
        )
        XCTAssertTrue(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [visible], thresholds: .strict)
        )
    }

    func testReachabilityTitlebarAboveScreenTopFailsBothThresholds() {
        // 200pt of the window body is visible at the bottom of the screen, but
        // the whole top strip sits above the physical screen — the stranded
        // shape a monitor disconnect produces.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 100, y: 700, width: 800, height: 600)
        XCTAssertFalse(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [visible], thresholds: .lenient)
        )
        XCTAssertFalse(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [visible], thresholds: .strict)
        )
    }

    func testReachabilityTuckedUnderMenuBarIsLenientOnlyReachable() {
        // Menu-bar band is 863..900. The titlebar band (top 28pt, 865..893) is
        // fully inside it — grabbable by nothing — while the lenient 64pt strip
        // still has 34pt visible below the menu bar.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 863)
        let frame = NSRect(x: 320, y: 293, width: 800, height: 600) // maxY 893
        XCTAssertTrue(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [visible], thresholds: .lenient)
        )
        XCTAssertFalse(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [visible], thresholds: .strict)
        )
    }

    func testReachabilityStrictWidthBoundary() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Window hangs off the left edge; exactly 120pt of the band remains visible.
        let atBoundary = NSRect(x: -680, y: 100, width: 800, height: 600)
        XCTAssertTrue(
            WindowTitlebarReachability.isTopStripReachable(atBoundary, onAnyOf: [visible], thresholds: .strict)
        )
        // One point less than the 120pt floor: not reachable.
        let belowBoundary = NSRect(x: -681, y: 100, width: 800, height: 600)
        XCTAssertFalse(
            WindowTitlebarReachability.isTopStripReachable(belowBoundary, onAnyOf: [visible], thresholds: .strict)
        )
    }

    func testReachabilityNarrowWindowRequiresOnlyItsFullWidth() {
        // A 100pt-wide window is narrower than the 120pt floor; its full width
        // being visible is enough.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 10, y: 100, width: 100, height: 400)
        XCTAssertTrue(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [visible], thresholds: .strict)
        )
    }

    func testReachabilityConsidersEveryScreen() {
        // Unreachable on the first screen, reachable on the second.
        let left = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let right = NSRect(x: 1440, y: 0, width: 2560, height: 1415)
        let frame = NSRect(x: 1500, y: 600, width: 800, height: 600)
        XCTAssertTrue(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [left, right], thresholds: .strict)
        )
        XCTAssertFalse(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [left], thresholds: .strict)
        )
    }

    func testReachabilityEmptyScreenListIsUnreachable() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [], thresholds: .lenient)
        )
        XCTAssertFalse(
            WindowTitlebarReachability.isTopStripReachable(frame, onAnyOf: [], thresholds: .strict)
        )
    }
}
#endif
