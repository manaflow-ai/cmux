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
        #expect(metrics.titleWidth(rowWidth: 420, leadingContentWidth: 92, trailingContentWidth: 76) == 240)
        #expect(metrics.titleWidth(rowWidth: 180, leadingContentWidth: 92, trailingContentWidth: 76) == 0)
    }

    @Test("the content inset matches the former setup entry")
    func referenceInsetIsTwelvePoints() {
        #expect(metrics.referenceInset == 12)
        #expect(CloudTreeStyle.compact.rowGrid.trailingPadding == metrics.referenceInset)
    }

#if DEBUG
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
        #expect(settings.metrics.resolvedStyle(.compact).rowGrid.disclosureGap == 4)
    }
#endif
}
