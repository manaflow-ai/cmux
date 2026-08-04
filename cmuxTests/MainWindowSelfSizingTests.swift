@preconcurrency import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class OversizedIntrinsicView: NSView {
    private let reportedSize: NSSize

    init(reportedSize: NSSize) {
        self.reportedSize = reportedSize
        super.init(frame: NSRect(origin: .zero, size: reportedSize))
    }

    override var intrinsicContentSize: NSSize { reportedSize }
    override var fittingSize: NSSize { reportedSize }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class MainWindowSelfSizingTests: XCTestCase {
    /// The main window must never resize itself to fit descendant content.
    /// This pins that contract with content whose intrinsic size is far larger
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
        let oversized = OversizedIntrinsicView(
            reportedSize: NSSize(width: 4_000, height: 3_000)
        )
        window.contentView = MainWindowContentView(contentView: oversized)
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: true)
        window.makeKeyAndOrderFront(nil)

        // Several display cycles catch deferred AppKit constraint resolution.
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
        let overReporting = OversizedIntrinsicView(
            reportedSize: NSSize(width: 4_000, height: 3_000)
        )
        let contentView = MainWindowContentView(contentView: overReporting)
        window.contentView = contentView
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
            contentView.frame.width, window.frame.width + 1.0,
            "The content view's frame must track the window, never the descendant's reported width"
        )
        XCTAssertLessThanOrEqual(
            contentView.frame.height, window.frame.height + 1.0,
            "The content view's frame must track the window, never the descendant's reported height"
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
        let wide = OversizedIntrinsicView(
            reportedSize: NSSize(width: 900, height: 700)
        )
        window.contentView = MainWindowContentView(contentView: wide)
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

    /// The content view must refuse a frame beyond its window outright. The
    /// tests above cover descendants that over-report through intrinsic sizing;
    /// the live claim explosion took the other
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
        let contentView = MainWindowContentView()
        window.contentView = contentView
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: true)
        window.makeKeyAndOrderFront(nil)

        // What the live engine did: set the content view's frame far past the
        // window (observed at 6373pt in a 1728pt window).
        contentView.setFrameSize(NSSize(width: 6_373, height: 3_000))

        XCTAssertLessThanOrEqual(
            contentView.frame.width, window.frame.width + 1.0,
            "The content view accepted a frame wider than its window — every space-filling descendant inherits this width"
        )
        XCTAssertLessThanOrEqual(
            contentView.frame.height, window.frame.height + 1.0,
            "The content view accepted a frame taller than its window"
        )
    }
}
