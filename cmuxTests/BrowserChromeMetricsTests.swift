import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserChromeMetricsTests {
    /// The default chrome sizes at the reference tab bar font size. Most values
    /// preserve the legacy hardcoded layout; the navigation raster is normalized
    /// from measured SF Symbol bounds so all browser nav variants share one box.
    private static let reference = (
        omnibarFontSize: CGFloat(12),
        omnibarFieldHeight: CGFloat(18),
        navigationIconRasterSize: CGFloat(15),
        secureBadgeFontSize: CGFloat(10),
        accessoryIconFontSize: CGFloat(11),
        buttonIconSize: CGFloat(22),
        buttonHitSize: CGFloat(26)
    )

    @Test func defaultFontSizeUsesReferenceSizes() {
        let metrics = BrowserChromeMetrics(tabBarFontSize: BrowserChromeMetrics.referenceFontSize)

        #expect(metrics.scale == 1)
        #expect(metrics.omnibarFontSize == Self.reference.omnibarFontSize)
        #expect(metrics.omnibarFieldHeight == Self.reference.omnibarFieldHeight)
        #expect(metrics.navigationIconRasterSize == Self.reference.navigationIconRasterSize)
        #expect(metrics.secureBadgeFontSize == Self.reference.secureBadgeFontSize)
        #expect(metrics.accessoryIconFontSize == Self.reference.accessoryIconFontSize)
        #expect(metrics.buttonIconSize == Self.reference.buttonIconSize)
        #expect(metrics.buttonHitSize == Self.reference.buttonHitSize)
    }

    @Test func referenceFontSizeMatchesShippedDefault() {
        // The byte-identical anchor must be the actual shipped default (11.0),
        // not an arbitrary constant.
        #expect(BrowserChromeMetrics.referenceFontSize == 11)
    }

    @Test func largerFontScalesEverySizeUpProportionally() {
        let larger = BrowserChromeMetrics.referenceFontSize + 2 // 13: a valid in-range size
        let metrics = BrowserChromeMetrics(tabBarFontSize: larger)
        let expectedScale = larger / BrowserChromeMetrics.referenceFontSize

        #expect(metrics.scale > 1)
        #expect(metrics.scale == expectedScale)
        #expect(metrics.omnibarFontSize == Self.reference.omnibarFontSize * expectedScale)
        #expect(metrics.navigationIconRasterSize == Self.reference.navigationIconRasterSize * expectedScale)
        #expect(metrics.buttonIconSize == Self.reference.buttonIconSize * expectedScale)
        #expect(metrics.buttonHitSize == Self.reference.buttonHitSize * expectedScale)
        #expect(metrics.accessoryIconFontSize == Self.reference.accessoryIconFontSize * expectedScale)
    }

    @Test func smallerFontScalesEverySizeDownProportionally() {
        let smaller = BrowserChromeMetrics.referenceFontSize - 3 // 8: the minimum valid tab bar font size
        let metrics = BrowserChromeMetrics(tabBarFontSize: smaller)
        let expectedScale = smaller / BrowserChromeMetrics.referenceFontSize

        #expect(metrics.scale < 1)
        #expect(metrics.scale == expectedScale)
        #expect(metrics.omnibarFontSize == Self.reference.omnibarFontSize * expectedScale)
        #expect(metrics.navigationIconRasterSize == Self.reference.navigationIconRasterSize * expectedScale)
        #expect(metrics.buttonHitSize == Self.reference.buttonHitSize * expectedScale)
    }

    @Test func absurdlyLargeFontClampsToMaximumScale() {
        let metrics = BrowserChromeMetrics(tabBarFontSize: 10_000)
        #expect(metrics.scale == BrowserChromeMetrics.maximumScale)
        #expect(metrics.buttonIconSize == Self.reference.buttonIconSize * BrowserChromeMetrics.maximumScale)
        #expect(metrics.navigationIconRasterSize == Self.reference.navigationIconRasterSize * BrowserChromeMetrics.maximumScale)
    }

    @Test func nearZeroFontClampsToMinimumScale() {
        let metrics = BrowserChromeMetrics(tabBarFontSize: 0.001)
        #expect(metrics.scale == BrowserChromeMetrics.minimumScale)
        #expect(metrics.omnibarFontSize == Self.reference.omnibarFontSize * BrowserChromeMetrics.minimumScale)
        #expect(metrics.navigationIconRasterSize == Self.reference.navigationIconRasterSize * BrowserChromeMetrics.minimumScale)
    }

    @Test(arguments: [CGFloat(0), CGFloat(-5), CGFloat.nan, CGFloat.infinity, -CGFloat.infinity])
    func nonPositiveOrNonFiniteFontFallsBackToNeutralScale(_ value: CGFloat) {
        let metrics = BrowserChromeMetrics(tabBarFontSize: value)
        #expect(metrics.scale == 1)
        #expect(metrics.buttonIconSize == Self.reference.buttonIconSize)
        #expect(metrics.navigationIconRasterSize == Self.reference.navigationIconRasterSize)
    }

    @Test func navigationIconReferenceSizesMatchMeasuredSymbolBounds() {
        #expect(BrowserNavigationToolbarIcon.back.symbolName == "chevron.left")
        #expect(BrowserNavigationToolbarIcon.back.measuredReferenceSize == CGSize(width: 9, height: 13))
        #expect(BrowserNavigationToolbarIcon.forward.symbolName == "chevron.right")
        #expect(BrowserNavigationToolbarIcon.forward.measuredReferenceSize == CGSize(width: 9, height: 13))
        #expect(BrowserNavigationToolbarIcon.reload.symbolName == "arrow.clockwise")
        #expect(BrowserNavigationToolbarIcon.reload.measuredReferenceSize == CGSize(width: 13, height: 15))
        #expect(BrowserNavigationToolbarIcon.stop.symbolName == "xmark")
        #expect(BrowserNavigationToolbarIcon.stop.measuredReferenceSize == CGSize(width: 13, height: 12))
    }

    @Test func navigationIconVariantsUseOneScaledRasterSize() {
        let metrics = BrowserChromeMetrics(tabBarFontSize: BrowserChromeMetrics.referenceFontSize + 2)
        let sizes = BrowserNavigationToolbarIcon.allCases.map {
            metrics.navigationIconRasterSize(for: $0)
        }

        #expect(Set(sizes).count == 1)
        #expect(sizes.first == metrics.navigationIconRasterSize)
        #expect(BrowserNavigationToolbarIcon.reloadOrStop(isLoading: false) == .reload)
        #expect(BrowserNavigationToolbarIcon.reloadOrStop(isLoading: true) == .stop)
    }
}
