import AppKit
import CmuxWindowing
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite(.serialized)
struct CmuxMainWindowConstrainFrameTests {
    private static let constrainVetoReachability = WindowTitlebarReachability(thresholds: .constrainVeto)
    private static let strictReachability = WindowTitlebarReachability(
        thresholds: WindowTitlebarReachabilityThresholds(
            topStripHeight: WindowChromeMetrics.sharedChromeBarHeight,
            minimumVisibleWidth: 120,
            minimumVisibleHeight: 20
        )
    )

    // On a display/system sleep->wake, AppKit re-runs its constrain pass over
    // every window and repositions even windows that are already fully
    // on-screen; cmux never re-asserts the saved frame afterward, so the window
    // creeps each sleep cycle. CmuxMainWindow.constrainFrameRect must leave an
    // on-screen frame untouched so AppKit can no longer move it. A titlebar
    // flush under the menu bar is one such on-screen frame (and an easy,
    // deterministic one to construct), but it is not the only triggering
    // arrangement - see the screen-agnostic helper cases below.
    @Test func constrainPreservesOnScreenFrameOverlappingMenuBar() {
        guard let screen = NSScreen.main else { return }
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
        // overlaps the menu bar - one on-screen placement AppKit's default
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

    @Test func preservesFrameFullyInsideVisibleArea() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 100, y: 100, width: 800, height: 600)
        #expect(CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible]))
    }

    @Test func preservesFrameWhoseTitlebarOverlapsMenuBarBand() {
        // The visible area excludes a 37pt menu-bar band at the top; the window's
        // titlebar pokes into it - the placement AppKit would otherwise push down.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 863)
        let frame = NSRect(x: 320, y: 263, width: 800, height: 637) // maxY 900 > 863
        #expect(CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible]))
    }

    @Test func doesNotPreserveFrameStrandedOffScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 3000, y: 2000, width: 800, height: 600)
        #expect(!CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible]))
    }

    @Test func doesNotPreserveBarelyPeekingFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Only ~20pt of the window overlaps the bottom-left corner - not grabbable.
        let frame = NSRect(x: -780, y: -580, width: 800, height: 600)
        #expect(!CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible]))
    }

    @Test func doesNotPreserveFrameWithTitlebarStrandedAboveScreen() {
        // A monitor disconnect can leave a window with 200pt of body visible at
        // the bottom of the surviving screen while its entire titlebar - the
        // only drag surface, since cmux main windows are not otherwise movable -
        // sits above the screen top. The veto must NOT preserve this frame;
        // AppKit's default constrain is the rescue path that pulls it back.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 100, y: 700, width: 800, height: 600) // maxY 1300
        #expect(!CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible]))
    }

    @Test func preservesFrameWithNarrowVisibleTitlebarBand() {
        // A window deliberately parked mostly off the right edge with only
        // 80pt of titlebar visible is still grabbable and was protected by the
        // historical 60pt veto tolerance - sleep/wake must not reposition it.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 1360, y: 100, width: 800, height: 600) // 80pt visible
        #expect(CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: [visible]))

        // Below the 60pt floor the veto declines and AppKit may constrain.
        let barelyVisible = NSRect(x: 1381, y: 100, width: 800, height: 600) // 59pt visible
        #expect(!CmuxMainWindow.shouldPreserveFrameDuringConstrain(barelyVisible, visibleFrames: [visible]))
    }

    @Test func doesNotPreserveWhenNoScreensAvailable() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        #expect(!CmuxMainWindow.shouldPreserveFrameDuringConstrain(frame, visibleFrames: []))
    }

    // MARK: - WindowTitlebarReachability (shared predicate)

    @Test func reachabilityFullyInsideVisibleAreaPassesBothThresholds() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 100, y: 100, width: 800, height: 600)
        #expect(Self.constrainVetoReachability.isTopStripReachable(frame, onAnyOf: [visible]))
        #expect(Self.strictReachability.isTopStripReachable(frame, onAnyOf: [visible]))
    }

    @Test func reachabilityTitlebarAboveScreenTopFailsBothThresholds() {
        // 200pt of the window body is visible at the bottom of the screen, but
        // the whole top strip sits above the physical screen - the stranded
        // shape a monitor disconnect produces.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 100, y: 700, width: 800, height: 600)
        #expect(!Self.constrainVetoReachability.isTopStripReachable(frame, onAnyOf: [visible]))
        #expect(!Self.strictReachability.isTopStripReachable(frame, onAnyOf: [visible]))
    }

    @Test func reachabilityTuckedUnderMenuBarIsVetoOnlyReachable() {
        // Menu-bar band is 863..900. The titlebar band (top 28pt, 865..893) is
        // fully inside it - grabbable by nothing - while the veto's 64pt strip
        // still has 34pt visible below the menu bar.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 863)
        let frame = NSRect(x: 320, y: 293, width: 800, height: 600) // maxY 893
        #expect(Self.constrainVetoReachability.isTopStripReachable(frame, onAnyOf: [visible]))
        #expect(!Self.strictReachability.isTopStripReachable(frame, onAnyOf: [visible]))
    }

    @Test func reachabilityStrictWidthBoundary() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Window hangs off the left edge; exactly 120pt of the band remains visible.
        let atBoundary = NSRect(x: -680, y: 100, width: 800, height: 600)
        #expect(Self.strictReachability.isTopStripReachable(atBoundary, onAnyOf: [visible]))

        // One point less than the 120pt floor: not reachable.
        let belowBoundary = NSRect(x: -681, y: 100, width: 800, height: 600)
        #expect(!Self.strictReachability.isTopStripReachable(belowBoundary, onAnyOf: [visible]))
    }

    @Test func reachabilityNarrowWindowRequiresOnlyItsFullWidth() {
        // A 100pt-wide window is narrower than the 120pt floor; its full width
        // being visible is enough.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 10, y: 100, width: 100, height: 400)
        #expect(Self.strictReachability.isTopStripReachable(frame, onAnyOf: [visible]))
    }

    @Test func reachabilityConsidersEveryScreen() {
        // Unreachable on the first screen, reachable on the second.
        let left = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let right = NSRect(x: 1440, y: 0, width: 2560, height: 1415)
        let frame = NSRect(x: 1500, y: 600, width: 800, height: 600)
        #expect(Self.strictReachability.isTopStripReachable(frame, onAnyOf: [left, right]))
        #expect(!Self.strictReachability.isTopStripReachable(frame, onAnyOf: [left]))
    }

    @Test func reachabilityEmptyScreenListIsUnreachable() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        #expect(!Self.constrainVetoReachability.isTopStripReachable(frame, onAnyOf: []))
        #expect(!Self.strictReachability.isTopStripReachable(frame, onAnyOf: []))
    }
}
#endif
