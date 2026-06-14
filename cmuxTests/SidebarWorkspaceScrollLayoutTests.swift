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

    @Test func emptyAreaFillsOnlyRemainingContainerSpaceWhenRowsFit() {
        // SidebarRowsFillLayout places the empty area below the rows, sized to
        // the space remaining in its concrete container. When the rows fit, rows
        // + filled empty area exactly equal the container, so the content fits
        // the viewport and the overlay scroller stays hidden (the #3241
        // phantom-scrollbar fix) — without ever measuring the rows into @State.
        let containerHeight: CGFloat = 644
        let rowsHeight: CGFloat = 96
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaFillHeight(
            containerHeight: containerHeight,
            rowsHeight: rowsHeight
        )

        #expect(abs(emptyAreaHeight - (containerHeight - rowsHeight)) <= 0.001)
        #expect(abs((rowsHeight + emptyAreaHeight) - containerHeight) <= 0.001)
    }

    @Test func emptyAreaCollapsesWhenRowsAlreadyFillContainer() {
        // When the rows reach or exceed the container (the viewport), the empty
        // area adds nothing, so the document view stays at the rows' natural
        // height and genuinely scrolls.
        let containerHeight: CGFloat = 300
        let rowsHeight: CGFloat = 420
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaFillHeight(
            containerHeight: containerHeight,
            rowsHeight: rowsHeight
        )

        #expect(abs(emptyAreaHeight) <= 0.001)
    }

    @Test func emptyAreaIsZeroWhenRowsExactlyFillContainer() {
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaFillHeight(
            containerHeight: 480,
            rowsHeight: 480
        )
        #expect(abs(emptyAreaHeight) <= 0.001)
    }

    @Test func emptyAreaFillsEntireContainerWhenNoRows() {
        // No workspaces: the empty drop/tap area fills the entire viewport so
        // the empty sidebar is still a drop/tap target and the content fills the
        // visible height (no phantom scrollbar).
        let containerHeight: CGFloat = 612
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaFillHeight(
            containerHeight: containerHeight,
            rowsHeight: 0
        )
        #expect(abs(emptyAreaHeight - containerHeight) <= 0.001)
    }

    // SidebarRowsFillLayout sizes the empty area from the *explicit* viewport,
    // not from a layout proposal. A vertical ScrollView leaves the scroll-axis
    // height unspecified, so deriving the viewport from the proposal would
    // collapse the empty area to a placeholder height when the rows fit, dropping
    // the blank area below the last row out of the drop/tap target. These cover
    // the viewport-based path directly (the regression Codex flagged on #6033).

    @Test func emptyAreaFromViewportFillsRemainderWhenRowsFit() {
        // Mirrors the observed runtime values (viewport 628, rows 421 -> 207).
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaFillHeight(
            viewportHeight: 628,
            rowsHeight: 421
        )
        #expect(abs(emptyAreaHeight - 207) <= 0.001)
        // rows + empty exactly fill the viewport, so the blank area below the
        // last row stays a drop/tap target and the overlay scroller stays hidden.
        #expect(abs((421 + emptyAreaHeight) - 628) <= 0.001)
    }

    @Test func emptyAreaFromViewportCollapsesWhenRowsOverflow() {
        // Mirrors the observed overflow values (viewport 628, rows 676 -> 0).
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaFillHeight(
            viewportHeight: 628,
            rowsHeight: 676
        )
        #expect(abs(emptyAreaHeight) <= 0.001)
    }

    @Test func emptyAreaFromViewportFillsEntireViewportWhenNoRows() {
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaFillHeight(
            viewportHeight: 612,
            rowsHeight: 0
        )
        #expect(abs(emptyAreaHeight - 612) <= 0.001)
    }
}
