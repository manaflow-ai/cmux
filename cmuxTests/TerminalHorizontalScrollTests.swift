@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalHorizontalScrollTests: XCTestCase {
    func testElasticHorizontalScrollCannotMoveRendererOrigin() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = NSRect(x: 0, y: 0, width: 480, height: 280)
        window.contentView?.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(hostedView.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let documentView = try XCTUnwrap(scrollView.documentView)
        documentView.frame.size = NSSize(width: 1000, height: 1000)
        scrollView.contentView.scroll(to: CGPoint(x: 137, y: 24))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        RunLoop.main.run(until: Date())

        XCTAssertEqual(hostedView.surfaceView.frame.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 0, accuracy: 0.001)
    }
}
