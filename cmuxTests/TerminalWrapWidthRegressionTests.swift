import AppKit
import CmuxTerminal
import CmuxTerminalCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalWrapWidthRegressionTests {
    private func withHostedTerminal(
        _ body: (GhosttySurfaceScrollView, NSScrollView) throws -> Void
    ) throws {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        defer { surface.releaseSurfaceForTesting() }
        let hostedView = surface.hostedView
        hostedView.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        let scrollView = try #require(hostedView.subviews.compactMap { $0 as? NSScrollView }.first)
        hostedView.surfaceView.cellSize = CGSize(width: 8, height: 16)
        setScrollback(100, in: hostedView)
        try #require(scrollView.hasVerticalScroller)
        try body(hostedView, scrollView)
    }

    private func setScrollback(_ total: UInt64, in hostedView: GhosttySurfaceScrollView) {
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: hostedView.surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: GhosttyScrollbar(total: total, offset: total - 10, len: 10)]
        )
        let deadline = Date().addingTimeInterval(1)
        while hostedView.surfaceView.scrollbar?.total != total, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        #expect(hostedView.surfaceView.scrollbar?.total == total)
    }

    private func expectViewportSizing(
        _ hostedView: GhosttySurfaceScrollView,
        _ scrollView: NSScrollView,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let viewport = scrollView.contentView.bounds.size
        let pending = try #require(hostedView.debugPendingSurfaceSize(), sourceLocation: sourceLocation)
        #expect(abs(hostedView.surfaceView.bounds.width - viewport.width) <= 0.5, sourceLocation: sourceLocation)
        #expect(abs(hostedView.surfaceView.bounds.height - viewport.height) <= 0.5, sourceLocation: sourceLocation)
        #expect(abs(pending.width - viewport.width) <= 0.5, sourceLocation: sourceLocation)
        #expect(abs(pending.height - viewport.height) <= 0.5, sourceLocation: sourceLocation)
        let documentView = try #require(scrollView.documentView, sourceLocation: sourceLocation)
        #expect(abs(documentView.frame.width - viewport.width) <= 0.5, sourceLocation: sourceLocation)
    }

    @Test(arguments: [NSScroller.Style.legacy, .overlay])
    func independentSurfaceLayoutKeepsViewportWidth(style: NSScroller.Style) throws {
        try withHostedTerminal { hostedView, scrollView in
            scrollView.scrollerStyle = style
            scrollView.tile()
            hostedView.reconcileGeometryNow()
            if style == .legacy {
                #expect(scrollView.contentSize.width < scrollView.bounds.width)
            } else {
                #expect(scrollView.contentSize.width == scrollView.bounds.width)
            }
            try expectViewportSizing(hostedView, scrollView)
            hostedView.surfaceView.layout()
            try expectViewportSizing(hostedView, scrollView)
        }
    }

    @Test func dividerSizedLayoutDoesNotRestoreFullWidthAfterStyleChange() throws {
        try withHostedTerminal { hostedView, scrollView in
            scrollView.scrollerStyle = .legacy
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            try expectViewportSizing(hostedView, scrollView)
            for width in [CGFloat(177), 423, 238, 360] {
                hostedView.setFrameSize(NSSize(width: width, height: 240))
                hostedView.reconcileGeometryNow()
                hostedView.surfaceView.layout()
                #expect(scrollView.bounds.width == width)
                #expect(scrollView.contentSize.width < width)
                try expectViewportSizing(hostedView, scrollView)
            }
        }
    }

    @Test func scrollbackVisibilityRestoresAndReservesViewportWidth() throws {
        try withHostedTerminal { hostedView, scrollView in
            scrollView.scrollerStyle = .legacy
            scrollView.tile()
            hostedView.reconcileGeometryNow()
            try expectViewportSizing(hostedView, scrollView)
            setScrollback(10, in: hostedView)
            #expect(!scrollView.hasVerticalScroller)
            #expect(scrollView.contentSize.width == scrollView.bounds.width)
            hostedView.surfaceView.layout()
            try expectViewportSizing(hostedView, scrollView)
            setScrollback(100, in: hostedView)
            #expect(scrollView.hasVerticalScroller)
            #expect(scrollView.contentSize.width < scrollView.bounds.width)
            hostedView.surfaceView.layout()
            try expectViewportSizing(hostedView, scrollView)
        }
    }

    @Test func repeatedScrollerStyleChangesKeepSubsequentLayoutsConsistent() throws {
        try withHostedTerminal { hostedView, scrollView in
            for style in [NSScroller.Style.legacy, .overlay, .legacy, .overlay] {
                scrollView.scrollerStyle = style
                NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
                try expectViewportSizing(hostedView, scrollView)
                hostedView.reconcileGeometryNow()
                hostedView.surfaceView.layout()
                #expect(scrollView.scrollerStyle == style)
                try expectViewportSizing(hostedView, scrollView)
            }
        }
    }
}
