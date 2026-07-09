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
}
