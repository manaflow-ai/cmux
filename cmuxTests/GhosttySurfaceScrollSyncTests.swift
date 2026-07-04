import AppKit
import CmuxTerminalCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct GhosttySurfaceScrollSyncTests {
    private func waitUntil(
        timeout: TimeInterval = 1,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        return predicate()
    }

    private func waitForScrollOrigin(
        _ expectedY: CGFloat,
        in scrollView: NSScrollView,
        tolerance: CGFloat = 0.01
    ) -> Bool {
        waitUntil {
            abs(scrollView.contentView.bounds.origin.y - expectedY) <= tolerance
        }
    }

    private func makeScrollbar(total: UInt64, offset: UInt64, len: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(
            c: ghostty_action_scrollbar_s(
                total: total,
                offset: offset,
                len: len
            )
        )
    }

    private func makeFixture() throws -> (
        window: NSWindow,
        surfaceView: GhosttyNSView,
        scrollView: NSScrollView
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        var shouldKeepWindow = false
        defer {
            if !shouldKeepWindow {
                window.orderOut(nil)
            }
        }

        let contentView = try #require(window.contentView)
        let surfaceView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        surfaceView.cellSize = CGSize(width: 10, height: 10)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        let scrollView = try #require(hostedView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView)
        #expect(waitUntil {
            hostedView.layoutSubtreeIfNeeded()
            return scrollView.documentView != nil && scrollView.contentView.bounds.height > 0
        })
        shouldKeepWindow = true
        return (window, surfaceView, scrollView)
    }

    private func postScrollbar(
        _ scrollbar: GhosttyScrollbar,
        from surfaceView: GhosttyNSView
    ) {
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
        )
    }

    private func simulateNativeScrollerDrag(
        on scrollView: NSScrollView,
        to originY: CGFloat
    ) {
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: originY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
    }

    @Test
    func nativeScrollerDragToBottomRestoresPassiveScrollbarFollowing() throws {
        let fixture = try makeFixture()
        defer { fixture.window.orderOut(nil) }

        postScrollbar(
            makeScrollbar(total: 100, offset: 90, len: 10),
            from: fixture.surfaceView
        )
        #expect(waitForScrollOrigin(0, in: fixture.scrollView))

        simulateNativeScrollerDrag(on: fixture.scrollView, to: 500)
        #expect(waitForScrollOrigin(500, in: fixture.scrollView))

        simulateNativeScrollerDrag(on: fixture.scrollView, to: 0)
        #expect(waitForScrollOrigin(0, in: fixture.scrollView))

        postScrollbar(
            makeScrollbar(total: 100, offset: 80, len: 10),
            from: fixture.surfaceView
        )

        #expect(
            waitForScrollOrigin(100, in: fixture.scrollView),
            "Dragging the native scroller back to the non-flipped document bottom should restore passive scrollbar following"
        )
    }

    @Test
    func nativeScrollerDragToTopKeepsScrollbackPinnedAgainstPassiveBottomPacket() throws {
        let fixture = try makeFixture()
        defer { fixture.window.orderOut(nil) }

        postScrollbar(
            makeScrollbar(total: 100, offset: 90, len: 10),
            from: fixture.surfaceView
        )
        #expect(waitForScrollOrigin(0, in: fixture.scrollView))

        let documentView = try #require(fixture.scrollView.documentView)
        let topOriginY = documentView.frame.height - fixture.scrollView.contentView.bounds.height
        simulateNativeScrollerDrag(on: fixture.scrollView, to: topOriginY)
        #expect(waitForScrollOrigin(topOriginY, in: fixture.scrollView))

        postScrollbar(
            makeScrollbar(total: 100, offset: 90, len: 10),
            from: fixture.surfaceView
        )

        #expect(
            waitForScrollOrigin(topOriginY, in: fixture.scrollView),
            "Dragging the native scroller to the top of scrollback should keep passive bottom packets from yanking the viewport"
        )
    }
}
