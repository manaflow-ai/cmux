import CoreGraphics
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

    @Test("title width receives space after stable trailing content")
    func titleWidthReservesControls() {
        #expect(metrics.titleWidth(rowWidth: 420, leadingContentWidth: 92, trailingContentWidth: 76) == 240)
        #expect(metrics.titleWidth(rowWidth: 180, leadingContentWidth: 92, trailingContentWidth: 76) == 0)
    }

    @Test("the content inset matches the former setup entry")
    func referenceInsetIsTwelvePoints() {
        #expect(metrics.referenceInset == 12)
        #expect(CloudTreeRowGrid.trailingPadding == metrics.referenceInset)
    }
}
