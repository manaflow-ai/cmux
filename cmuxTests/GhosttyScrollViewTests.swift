import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Ghostty terminal scroll view")
struct GhosttyScrollViewTests {
    @Test func terminalViewportOwnsItsContentInsets() {
        let scrollView = GhosttyScrollView(frame: .zero)

        #expect(
            !scrollView.automaticallyAdjustsContentInsets,
            "the terminal viewport must not inherit a second top inset from window chrome"
        )
        #expect(scrollView.contentInsets.top == 0)
        #expect(scrollView.contentInsets.left == 0)
        #expect(scrollView.contentInsets.bottom == 0)
        #expect(scrollView.contentInsets.right == 0)
    }

    @Test func scrollingInvalidatesTheRelocatedTerminalViewport() throws {
        let documentView = ScrollDamageRecordingView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 800)
        )
        let surfaceView = GhosttyNSView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 120)
        )
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: surfaceView,
            documentView: documentView
        )
        hostedView.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        hostedView.layoutSubtreeIfNeeded()

        let scrollView = try #require(
            hostedView.subviews.compactMap { $0 as? GhosttyScrollView }.first
        )
        documentView.frame.size.height = 800
        documentView.invalidatedRects.removeAll()

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        #expect(surfaceView.frame.origin == scrollView.contentView.documentVisibleRect.origin)
        #expect(
            documentView.invalidatedRects.contains { $0.contains(surfaceView.frame) },
            "moving the viewport-sized Metal surface must invalidate its complete new footprint"
        )
    }
}

@MainActor
private final class ScrollDamageRecordingView: NSView {
    var invalidatedRects: [NSRect] = []

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        invalidatedRects.append(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }
}
