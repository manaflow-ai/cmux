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

    @Test func scrollbackMovesOnlyTheVirtualDocument() throws {
        let surfaceView = GhosttyNSView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 120)
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        hostedView.layoutSubtreeIfNeeded()

        let scrollView = try #require(
            hostedView.subviews.compactMap { $0 as? GhosttyScrollView }.first
        )
        let documentView = try #require(scrollView.documentView)
        documentView.frame.size.height = 800
        let rendererFrame = surfaceView.frame

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        #expect(scrollView.contentView.documentVisibleRect.origin.y == 200)
        #expect(
            surfaceView.frame == rendererFrame,
            "scrollback must not relocate the viewport-sized Metal renderer"
        )
        #expect(
            surfaceView.superview === hostedView,
            "the renderer must stay outside AppKit's blit-scrolled document subtree"
        )
    }
}
