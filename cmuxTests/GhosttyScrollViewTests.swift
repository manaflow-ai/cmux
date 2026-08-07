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

        #expect(documentView.frame.height == 800)
        #expect(scrollView.contentView.documentVisibleRect.origin.y == 200)
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
            hostedView.hitTest(pointInContainer) === surfaceView,
            "offset portal and renderer frames must preserve terminal pointer routing"
        )
    }

    @Test func reconnectOverlayRoutesOffsetCardAndButtonHits() throws {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 800))
        let overlay = CloudTerminalReconnectOverlayView(
            frame: NSRect(x: 300, y: 200, width: 800, height: 240)
        )
        containerView.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()

        let cardView = try #require(
            overlay.subviews.compactMap { $0 as? NSVisualEffectView }.first
        )
        let stackView = try #require(
            cardView.subviews.compactMap { $0 as? NSStackView }.first
        )
        let reconnectButton = try #require(
            stackView.arrangedSubviews.compactMap { $0 as? NSButton }.first
        )

        let cardPointInOverlay = NSPoint(x: cardView.frame.minX + 8, y: cardView.frame.midY)
        let cardPointInContainer = overlay.convert(cardPointInOverlay, to: containerView)
        #expect(
            overlay.hitTest(cardPointInContainer) === overlay,
            "an offset reconnect card must retain its background hit region"
        )

        let buttonPointInOverlay = reconnectButton.convert(
            NSPoint(x: reconnectButton.bounds.midX, y: reconnectButton.bounds.midY),
            to: overlay
        )
        let buttonPointInContainer = overlay.convert(buttonPointInOverlay, to: containerView)
        #expect(
            overlay.hitTest(buttonPointInContainer) === reconnectButton,
            "an offset reconnect button must receive its own hit"
        )
    }
}
