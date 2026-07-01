import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar workspace scroll layout")
struct SidebarWorkspaceScrollLayoutTests {
    @Test func contentMinHeightSubtractsInsetsFromViewport() {
        let contentMinHeight = SidebarWorkspaceScrollLayout.contentMinHeight(
            viewportHeight: 720,
            insets: SidebarWorkspaceScrollInsets(top: 28, bottom: 48)
        )
        #expect(abs(contentMinHeight - (720 - 76)) <= 0.001)
    }

    @Test func contentMinHeightNeverGoesNegative() {
        let contentMinHeight = SidebarWorkspaceScrollLayout.contentMinHeight(
            viewportHeight: 20,
            insets: SidebarWorkspaceScrollInsets(top: 28, bottom: 48)
        )
        #expect(contentMinHeight == 0)
    }

    @Test func contentHeightStaysWithinViewportAfterPixelRounding() {
        // Real sidebar viewport heights are frequently fractional on
        // Retina/scaled displays and with fractional window heights. SwiftUI
        // lays the scroll content out to `contentMinHeight`, but AppKit aligns
        // the document view's frame to the backing store (rounding up). If
        // `contentMinHeight` is fractional, that round-up pushes
        // `document + insets` a sub-point past the viewport, so the content
        // becomes (barely) scrollable and the auto-hiding overlay scroller is
        // shown even when only a single workspace is present — the phantom
        // sidebar scrollbar (https://github.com/manaflow-ai/cmux/issues/3241).
        //
        // Guard the invariant directly: the content height must stay point
        // aligned. Rounding up to a whole point is a conservative
        // over-approximation of AppKit's backing-store alignment (which is
        // finer on Retina), so if `content + insets` survives a whole-point
        // round-up it survives the real, finer one too.
        let insets = SidebarWorkspaceScrollInsets(top: 28, bottom: 48)
        let fractionalViewportHeights: [CGFloat] = [948.7, 720.5, 1033.25, 600.999]

        for viewportHeight in fractionalViewportHeights {
            let contentMinHeight = SidebarWorkspaceScrollLayout.contentMinHeight(
                viewportHeight: viewportHeight,
                insets: insets
            )
            // Simulate AppKit rounding the laid-out document view up to the next
            // whole point. This is conservative (AppKit aligns to backing-store
            // pixels, which are <= 1 pt on Retina displays), so the assertion
            // holds regardless of the display scale factor.
            let roundedDocumentHeight = contentMinHeight.rounded(.up)
            #expect(roundedDocumentHeight + insets.total <= viewportHeight)
        }
    }
}
