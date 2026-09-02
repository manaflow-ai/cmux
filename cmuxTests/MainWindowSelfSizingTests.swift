@preconcurrency import XCTest
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MainWindowSelfSizingTests: XCTestCase {
    /// The main window must never resize itself to fit its SwiftUI content.
    /// NSHostingView watches window layout and calls NSWindow.setFrame when
    /// the measured content size disagrees with the window
    /// (updateAnimatedWindowSize) — with content whose measured size tracks
    /// the container, that path grows the window a step per layout pass,
    /// without bound. MainWindowHostingView disables it (sizingOptions = []);
    /// this pins that contract with content whose ideal size is far larger
    /// than the window.
    @MainActor
    func testWindowDoesNotGrowTowardContentIdealSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        let oversized = Color.clear.frame(
            minWidth: 0, idealWidth: 4000, maxWidth: .infinity,
            minHeight: 0, idealHeight: 3000, maxHeight: .infinity
        )
        window.contentView = MainWindowHostingView(rootView: AnyView(oversized))
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: true)
        window.makeKeyAndOrderFront(nil)

        // Several display cycles: the hosting view's window-resize pass runs
        // from windowDidLayout, so one layout alone can read as a false pass.
        for _ in 0..<5 {
            window.displayIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(
            window.frame.width, 500, accuracy: 1.0,
            "Window width must stay where it was set — content ideal size must not grow the window"
        )
        XCTAssertEqual(
            window.frame.height, 400, accuracy: 1.0,
            "Window height must stay where it was set — content ideal size must not grow the window"
        )
    }

    /// The hosting view's OWN frame must track the window too, not just the
    /// window's frame. The live fuzz observed content that over-reports its
    /// width (a fixed-size subtree leaking through a flexible frame) marching
    /// the content view wider than the display-pinned window a step per
    /// layout pass — every space-filling descendant then inherits the
    /// inflated width. The root content here reports 4000pt to every
    /// proposal; the hosting view must stay at the window's content size.
    @MainActor
    func testContentViewFrameTracksWindowWhenContentOverReports() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        // A fixed-size child inside a topLeading flexible frame: the frame
        // reports the child's 4000pt whenever the proposal is smaller — the
        // same shape as the leak the fuzz caught.
        let overReporting = Color.clear
            .frame(width: 4000, height: 3000)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let hostingView = MainWindowHostingView(rootView: AnyView(overReporting))
        window.contentView = hostingView
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: true)
        window.makeKeyAndOrderFront(nil)

        for _ in 0..<5 {
            window.displayIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(
            window.frame.width, 500, accuracy: 1.0,
            "Window width must stay where it was set — over-reporting content must not grow the window"
        )
        XCTAssertLessThanOrEqual(
            hostingView.frame.width, window.frame.width + 1.0,
            "The hosting view's frame must track the window, never the content's reported width"
        )
        XCTAssertLessThanOrEqual(
            hostingView.frame.height, window.frame.height + 1.0,
            "The hosting view's frame must track the window, never the content's reported height"
        )
    }

    /// Same contract when the window sits BELOW the content's minimum size —
    /// the live trigger: a programmatic resize can place a window under the
    /// workspace chrome's minimum width, and the hosting view must not march
    /// the window frame toward (or past) the content minimum in response.
    @MainActor
    func testWindowDoesNotGrowWhenSetBelowContentMinimumSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        let wide = Color.clear.frame(
            minWidth: 900, maxWidth: .infinity,
            minHeight: 700, maxHeight: .infinity
        )
        window.contentView = MainWindowHostingView(rootView: AnyView(wide))
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: true)
        window.makeKeyAndOrderFront(nil)

        for _ in 0..<5 {
            window.displayIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(
            window.frame.width, 500, accuracy: 1.0,
            "Window width must stay where it was set even below the content minimum"
        )
        XCTAssertEqual(
            window.frame.height, 400, accuracy: 1.0,
            "Window height must stay where it was set even below the content minimum"
        )
    }

    /// The hosting view must refuse a frame beyond its window outright. The
    /// SwiftUI-side tests above cover content that over-reports through the
    /// hosting view's own measurement; the live claim explosion took the other
    /// door: AppKit's layout engine handed the content view an inflated frame
    /// directly — required constraints from hosted AppKit subtrees resolve by
    /// growing the frame that setFrameSize is asked to apply — and a 6373pt
    /// hosting view sat inside a 1728pt window, with every space-filling
    /// descendant (including terminal surfaces, whose rendered grids feed
    /// remote size claims) inheriting the inflated width. sizingOptions and
    /// the windowDidLayout shadow only govern the hosting view's own sizing
    /// paths; the frame setter is the last line, so it clamps to the window.
    @MainActor
    func testHostingViewRefusesFrameSizesBeyondItsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        let filler = Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        let hostingView = MainWindowHostingView(rootView: AnyView(filler))
        window.contentView = hostingView
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: true)
        window.makeKeyAndOrderFront(nil)

        // What the live engine did: set the content view's frame far past the
        // window (observed at 6373pt in a 1728pt window).
        hostingView.setFrameSize(NSSize(width: 6_373, height: 3_000))

        XCTAssertLessThanOrEqual(
            hostingView.frame.width, window.frame.width + 1.0,
            "The hosting view accepted a frame wider than its window — every space-filling descendant inherits this width"
        )
        XCTAssertLessThanOrEqual(
            hostingView.frame.height, window.frame.height + 1.0,
            "The hosting view accepted a frame taller than its window"
        )
    }

    /// `minSize`/`contentMinSize` bound only USER resizes; a programmatic
    /// `setFrame` (session restore math, display reconfiguration, automation)
    /// can still deliver a frame below the layout floor, where the sidebar
    /// footer, update pill, and tab bar overlap and clip. The window must
    /// enforce the floor on every setFrame path, keeping the top edge (the
    /// titlebar the user can grab) where the caller put it.
    @MainActor
    func testSetFrameRaisesUndersizedFrameToMinimumContentSize() {
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        let minimum = CmuxMainWindow.minimumContentSize
        let undersized = NSRect(x: 80, y: 500, width: 220, height: 120)
        window.setFrame(undersized, display: false)

        XCTAssertGreaterThanOrEqual(
            window.frame.width, minimum.width - 0.5,
            "A programmatic setFrame below the minimum width must be raised to the floor"
        )
        XCTAssertGreaterThanOrEqual(
            window.frame.height, minimum.height - 0.5,
            "A programmatic setFrame below the minimum height must be raised to the floor"
        )
        XCTAssertEqual(
            window.frame.maxY, undersized.maxY, accuracy: 0.5,
            "Raising an undersized frame must keep the top edge put and extend the window downward"
        )
    }

    /// Ordinary frames must flow through the undersized raise untouched so
    /// user-owned placement (partial off-screen, multi-display) is never
    /// perturbed by the floor.
    func testFrameRaiseReturnsFittingFramesByteForByte() {
        let fitting = NSRect(x: -120.5, y: 33.25, width: 901.5, height: 612.75)
        XCTAssertEqual(
            CmuxMainWindow.frameByRaisingUndersizedDimensions(
                fitting,
                minimumSize: CmuxMainWindow.minimumContentSize,
                currentFrame: NSRect(x: 0, y: 0, width: 1_000, height: 700),
                isLiveResize: true
            ),
            fitting,
            "A frame at or above the minimum must be returned unchanged"
        )
    }

    /// A top-edge drag keeps the window's bottom still and walks maxY down;
    /// once the proposal dips under the floor the raise must pin the kept
    /// bottom edge so the top edge stops — anchoring the top instead would
    /// make the whole window slide down with the cursor (observed live on
    /// macOS 26, whose edge drags deliver below-minSize frames to setFrame).
    func testFrameRaisePinsKeptBottomEdgeDuringTopEdgeDrag() {
        let current = NSRect(x: 100, y: 100, width: 1_000, height: 694)
        let proposed = NSRect(x: 100, y: 100, width: 1_000, height: 95)
        let minimum = NSSize(width: 300, height: 400)
        let raised = CmuxMainWindow.frameByRaisingUndersizedDimensions(
            proposed,
            minimumSize: minimum,
            currentFrame: current,
            isLiveResize: true
        )
        XCTAssertEqual(raised.minY, current.minY, accuracy: 0.01, "Kept bottom edge must stay pinned")
        XCTAssertEqual(raised.height, minimum.height, accuracy: 0.01)
    }

    /// A bottom-edge drag keeps the window's top still and walks minY up; the
    /// raise must pin the kept top edge so the bottom edge stops at the floor.
    func testFrameRaisePinsKeptTopEdgeDuringBottomEdgeDrag() {
        let current = NSRect(x: 100, y: 100, width: 1_000, height: 694)
        let proposed = NSRect(x: 100, y: 699, width: 1_000, height: 95)
        let minimum = NSSize(width: 300, height: 400)
        let raised = CmuxMainWindow.frameByRaisingUndersizedDimensions(
            proposed,
            minimumSize: minimum,
            currentFrame: current,
            isLiveResize: true
        )
        XCTAssertEqual(raised.maxY, current.maxY, accuracy: 0.01, "Kept top edge must stay pinned")
        XCTAssertEqual(raised.height, minimum.height, accuracy: 0.01)
    }

    /// Outside live resize a shrink that happens to share the window's
    /// current origin is not a drag — the raise must still keep the
    /// proposal's top edge (the titlebar) rather than pinning the bottom.
    func testFrameRaiseKeepsTopEdgeForProgrammaticShrinkSharingOrigin() {
        let current = NSRect(x: 100, y: 100, width: 1_000, height: 694)
        let proposed = NSRect(x: 100, y: 100, width: 1_000, height: 95)
        let minimum = NSSize(width: 300, height: 400)
        let raised = CmuxMainWindow.frameByRaisingUndersizedDimensions(
            proposed,
            minimumSize: minimum,
            currentFrame: current,
            isLiveResize: false
        )
        XCTAssertEqual(raised.maxY, proposed.maxY, accuracy: 0.01, "Programmatic raises keep the proposal's top edge")
        XCTAssertEqual(raised.height, minimum.height, accuracy: 0.01)
    }

    /// A left-edge drag keeps the window's right edge still; the raise must
    /// pin that kept right edge so the left edge stops at the width floor.
    func testFrameRaisePinsKeptRightEdgeDuringLeftEdgeDrag() {
        let current = NSRect(x: 100, y: 100, width: 1_000, height: 694)
        let proposed = NSRect(x: 1_020, y: 100, width: 80, height: 694)
        let minimum = NSSize(width: 300, height: 400)
        let raised = CmuxMainWindow.frameByRaisingUndersizedDimensions(
            proposed,
            minimumSize: minimum,
            currentFrame: current,
            isLiveResize: true
        )
        XCTAssertEqual(raised.maxX, current.maxX, accuracy: 0.01, "Kept right edge must stay pinned")
        XCTAssertEqual(raised.width, minimum.width, accuracy: 0.01)
    }
}
