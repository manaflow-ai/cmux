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
}
