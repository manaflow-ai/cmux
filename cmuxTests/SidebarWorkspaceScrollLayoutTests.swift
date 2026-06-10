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
    @Test func unmeasuredRowsCollapseEmptyAreaWithoutForcingOverflow() {
        // Before a measurement arrives, the empty area collapses to 0. The
        // content's `minHeight` frame still fills the viewport, so the document
        // view does not overflow and the overlay scroller stays hidden.
        let contentMinHeight: CGFloat = 480
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaHeight(
            contentMinHeight: contentMinHeight,
            rowsHeight: nil
        )

        #expect(abs(emptyAreaHeight) <= 0.001)
        // The content frame is pinned to contentMinHeight, so it never exceeds
        // the viewport: no overflow, overlay scroller stays hidden.
        #expect(max(contentMinHeight, emptyAreaHeight) <= contentMinHeight)
    }

    @Test func rowsMeasurementIgnoresStaleWorkspaceIds() {
        let measurement = SidebarWorkspaceRowsMeasurement(
            workspaceIds: ["a", "b"],
            rowsHeight: 240
        )

        #expect(measurement.rowsHeight(for: ["b", "c"]) == nil)
        #expect(abs((measurement.rowsHeight(for: ["a", "b"]) ?? -1) - 240) <= 0.001)
    }

    @Test func rowsMeasurementDedupesSubPixelJitterForSameWorkspaceIds() {
        // The livelock-safety invariant: the single whole-content measurement
        // is deduped so sub-pixel height jitter from constant agent-driven row
        // re-renders does NOT write @State, so it cannot re-feed a
        // preference/layout transaction cycle (the #2586 class of bug).
        let base = SidebarWorkspaceRowsMeasurement(workspaceIds: ["a", "b"], rowsHeight: 240)
        let jittered = SidebarWorkspaceRowsMeasurement(workspaceIds: ["a", "b"], rowsHeight: 240.3)
        let moved = SidebarWorkspaceRowsMeasurement(workspaceIds: ["a", "b"], rowsHeight: 256)
        let differentRows = SidebarWorkspaceRowsMeasurement(workspaceIds: ["a"], rowsHeight: 240)

        #expect(base.isEquivalent(to: jittered))
        #expect(!base.isEquivalent(to: moved))
        #expect(!base.isEquivalent(to: differentRows))
    }

    @Test func emptyAreaFillsOnlyRemainingViewportSpaceWhenRowsFit() {
        let contentMinHeight = SidebarWorkspaceScrollLayout.contentMinHeight(
            viewportHeight: 720,
            insets: SidebarWorkspaceScrollInsets(top: 28, bottom: 48)
        )
        let rowsHeight: CGFloat = 96
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaHeight(
            contentMinHeight: contentMinHeight,
            rowsHeight: rowsHeight
        )

        #expect(abs(emptyAreaHeight - (contentMinHeight - rowsHeight)) <= 0.001)
        // Rows + filled empty area exactly equals the viewport: content fits,
        // so the overlay scroller stays hidden (the #3241 phantom-scrollbar fix).
        #expect(abs((rowsHeight + emptyAreaHeight) - contentMinHeight) <= 0.001)
    }

    @Test func emptyAreaCollapsesWhenRowsAlreadyOverflowViewport() {
        let contentMinHeight: CGFloat = 300
        let rowsHeight: CGFloat = 420
        let emptyAreaHeight = SidebarWorkspaceScrollLayout.emptyAreaHeight(
            contentMinHeight: contentMinHeight,
            rowsHeight: rowsHeight
        )

        #expect(abs(emptyAreaHeight) <= 0.001)
        // The empty area adds nothing, so the document view stays at the rows'
        // natural height and genuinely overflows the viewport — a real scroll.
        #expect(rowsHeight + emptyAreaHeight > contentMinHeight)
    }
}
