import AppKit
import CmuxSettings
import CmuxTerminalCore
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
        surfaceView.cellSize = CGSize(width: 8, height: 10)
        let rendererFrame = surfaceView.frame

        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            userInfo: [
                GhosttyNotificationKey.scrollbar: GhosttyScrollbar(
                    total: 80,
                    offset: 48,
                    len: 12
                )
            ]
        )

        let didApplyScrollbar = waitForMainRunLoop {
            abs(documentView.frame.height - 800) <= 0.5 &&
                abs(scrollView.contentView.documentVisibleRect.origin.y - 200) <= 0.5
        }
        #expect(didApplyScrollbar, "the production scrollbar notification must settle before assertions")
        #expect(
            surfaceView.frame == rendererFrame,
            "scrollback must not relocate the viewport-sized Metal renderer"
        )
        #expect(
            surfaceView.superview === hostedView,
            "the renderer must stay outside AppKit's blit-scrolled document subtree"
        )
        #expect(
            hostedView.hitTest(NSPoint(x: 40, y: 40)) === surfaceView,
            "the transparent virtual scroll document must forward viewport hits to the renderer"
        )
    }

    @Test func virtualDocumentForwardsHitsAcrossOffsetCoordinateSpaces() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 800))
        let surfaceView = GhosttyNSView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 240)
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = NSRect(x: 300, y: 200, width: 800, height: 240)
        containerView.addSubview(hostedView)
        hostedView.layoutSubtreeIfNeeded()
        hostedView.setSessionContentWidthPresentation(SessionContentWidthPresentation(
            storedMaximumWidth: 600,
            storedAlignment: SessionContentAlignment.center.rawValue
        ))

        let pointInHostedView = NSPoint(x: 150, y: 50)
        let pointInContainer = hostedView.convert(pointInHostedView, to: containerView)

        #expect(surfaceView.frame.origin == NSPoint(x: 100, y: 0))
        #expect(
            containerView.hitTest(pointInContainer) === surfaceView,
            "offset portal and renderer frames must preserve terminal pointer routing"
        )
    }

    private func waitForMainRunLoop(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date(timeIntervalSinceNow: 0.01))
            )
        }
        return condition()
    }
}
