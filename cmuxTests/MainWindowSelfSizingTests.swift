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
}
