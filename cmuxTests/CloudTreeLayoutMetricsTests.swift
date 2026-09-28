import CmuxCloud
import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud tree layout metrics")
struct CloudTreeLayoutMetricsTests {
    private let metrics = CloudTreeLayoutMetrics()

    @Test("document width fills narrow and wide viewports")
    func documentWidthTracksViewport() {
        #expect(metrics.documentWidth(viewportWidth: 180) == 180)
        #expect(metrics.documentWidth(viewportWidth: 420) == 420)
        #expect(metrics.documentWidth(viewportWidth: -1) == 0)
    }

    @Test("document height stays usable before rows load")
    func documentHeightTracksViewport() {
        #expect(metrics.documentHeight(viewportHeight: 300, contentHeight: 0) == 300)
        #expect(metrics.documentHeight(viewportHeight: 300, contentHeight: 520) == 520)
    }

    @Test("title width receives space after stable trailing content")
    func titleWidthReservesControls() {
        // Written against the inset rather than a literal: the trailing column
        // is now the sidebar's, so a number here would have to be rewritten
        // every time the sidebar's chrome moves.
        #expect(
            metrics.titleWidth(rowWidth: 420, leadingContentWidth: 92, trailingContentWidth: 76)
                == 420 - 92 - 76 - metrics.referenceInset
        )
        #expect(
            metrics.titleWidth(rowWidth: 180, leadingContentWidth: 92, trailingContentWidth: 76)
                == 180 - 92 - 76 - metrics.referenceInset
        )
        // The clamp, stated on its own. Before this the narrow case happened to
        // come out at exactly zero with the old 12pt inset, so it read like a
        // clamp test and was really more arithmetic: moving the inset to the
        // sidebar's 6pt turned it into 6 and the assertion failed without any
        // clamping behaviour having changed.
        #expect(metrics.titleWidth(rowWidth: 140, leadingContentWidth: 92, trailingContentWidth: 76) == 0)
    }

    /// CmuxCloud cannot import the app target, so `CloudSidebarChromeMetrics`
    /// restates the sidebar's chrome numbers for the Cloud surfaces. This test
    /// runs in the app target, where both types are visible, and is the only
    /// thing stopping the copy from drifting from the original.
    @Test("the Cloud package's copy of the sidebar chrome matches the original")
    func cloudChromeMatchesSidebarChrome() {
        #expect(CloudSidebarChromeMetrics.sidebar.barHorizontalPadding == RightSidebarChromeMetrics.barHorizontalPadding)
        #expect(CloudSidebarChromeMetrics.sidebar.barVerticalPadding == RightSidebarChromeMetrics.barVerticalPadding)
        #expect(CloudSidebarChromeMetrics.sidebar.headerTrailingPadding == RightSidebarChromeMetrics.headerTrailingPadding)
    }

    @Test("the tree's trailing column is the sidebar's trailing column")
    func trailingColumnFollowsSidebarChrome() {
        #expect(CloudTreeStyle.compact.rowGrid.trailingPadding == RightSidebarChromeMetrics.headerTrailingPadding)
        // `CloudTreeLayoutMetrics` states the same column a second time and has
        // no production reader today, so nothing would catch it sitting at the
        // old 12 until someone wires `titleWidth` up and gets titles that
        // truncate 6pt early. Pinned here instead.
        #expect(metrics.referenceInset == CloudTreeStyle.compact.rowGrid.trailingPadding)
    }

    @Test("compact rows keep the established disclosure and icon grid")
    func compactGeometryUsesEstablishedGrid() {
        let style = CloudTreeStyle.compact
        #expect(style.rowHeight == 22)
        #expect(style.indentPerLevel == 10)
        #expect(style.iconSlot == 16)
        #expect(style.iconGap == 4)
        #expect(style.rowGrid.disclosureSlot == 16)
        #expect(style.rowGrid.disclosureGap == 2)
        #expect(style.rowGrid.detailGap == 5)
        #expect(style.rowGrid.trailingGap == 10)
        #expect(style.machineVerticalPadding == 2)
    }

#if DEBUG
    /// The spacing lab starts from the shipped geometry, so opening it must not
    /// be what moves the trailing column.
    @Test("the spacing lab starts on the shipped trailing column")
    func debugMetricsStartOnShippedInset() {
        #expect(
            CloudSidebarDebugMetrics.default.referenceInset
                == Double(CloudTreeStyle.compact.rowGrid.trailingPadding)
        )
    }

    @MainActor
    @Test("Tuning snapshots stay independent and survive reopening")
    func tuningSnapshots() throws {
        let suite = "CloudSidebarSpacingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CloudSidebarDebugSettings(defaults: defaults)
        settings.metrics.rowHeight = 32
        settings.metrics.disclosureGap = 9
        let first = settings.metrics.resolvedStyle(.compact)
        settings.metrics.disclosureGap = 3
        let second = settings.metrics.resolvedStyle(.compact)
        #expect(first.rowGrid.disclosureGap == 9)
        #expect(second.rowGrid.disclosureGap == 3)
        #expect(first.rowHeight == second.rowHeight)
        #expect(first != second)
        let reopened = CloudSidebarDebugSettings(defaults: defaults)
        #expect(reopened.metrics == settings.metrics)
        settings.metrics.disclosureGap = CloudSidebarDebugMetrics.default.disclosureGap
        #expect(settings.metrics.rowHeight == 32)
        #expect(settings.metrics.resolvedStyle(.compact).rowGrid.disclosureGap == 2)
    }
#endif
}
