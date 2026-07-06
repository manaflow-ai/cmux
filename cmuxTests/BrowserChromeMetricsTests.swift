import CoreGraphics
import CmuxBrowserUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserChromeMetricsTests {
    /// The legacy hardcoded chrome sizes the layout must reproduce exactly at the
    /// default tab bar font size, so default appearance stays byte-identical.
    private static let legacy = (
        omnibarFontSize: CGFloat(12),
        omnibarFieldHeight: CGFloat(18),
        navigationIconFontSize: CGFloat(12),
        secureBadgeFontSize: CGFloat(10),
        accessoryIconFontSize: CGFloat(11),
        buttonIconSize: CGFloat(22),
        buttonHitSize: CGFloat(26)
    )

    @Test func defaultFontSizeReproducesLegacySizesByteIdentical() {
        let metrics = BrowserChromeMetrics(tabBarFontSize: BrowserChromeMetrics.referenceFontSize)

        #expect(metrics.scale == 1)
        #expect(metrics.omnibarFontSize == Self.legacy.omnibarFontSize)
        #expect(metrics.omnibarFieldHeight == Self.legacy.omnibarFieldHeight)
        #expect(metrics.navigationIconFontSize == Self.legacy.navigationIconFontSize)
        #expect(metrics.secureBadgeFontSize == Self.legacy.secureBadgeFontSize)
        #expect(metrics.accessoryIconFontSize == Self.legacy.accessoryIconFontSize)
        #expect(metrics.buttonIconSize == Self.legacy.buttonIconSize)
        #expect(metrics.buttonHitSize == Self.legacy.buttonHitSize)
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
        #expect(metrics.omnibarFontSize == Self.legacy.omnibarFontSize * expectedScale)
        #expect(metrics.buttonIconSize == Self.legacy.buttonIconSize * expectedScale)
        #expect(metrics.buttonHitSize == Self.legacy.buttonHitSize * expectedScale)
        #expect(metrics.accessoryIconFontSize == Self.legacy.accessoryIconFontSize * expectedScale)
    }

    @Test func smallerFontScalesEverySizeDownProportionally() {
        let smaller = BrowserChromeMetrics.referenceFontSize - 3 // 8: the minimum valid tab bar font size
        let metrics = BrowserChromeMetrics(tabBarFontSize: smaller)
        let expectedScale = smaller / BrowserChromeMetrics.referenceFontSize

        #expect(metrics.scale < 1)
        #expect(metrics.scale == expectedScale)
        #expect(metrics.omnibarFontSize == Self.legacy.omnibarFontSize * expectedScale)
        #expect(metrics.buttonHitSize == Self.legacy.buttonHitSize * expectedScale)
    }

    @Test func absurdlyLargeFontClampsToMaximumScale() {
        let metrics = BrowserChromeMetrics(tabBarFontSize: 10_000)
        #expect(metrics.scale == BrowserChromeMetrics.maximumScale)
        #expect(metrics.buttonIconSize == Self.legacy.buttonIconSize * BrowserChromeMetrics.maximumScale)
    }

    @Test func nearZeroFontClampsToMinimumScale() {
        let metrics = BrowserChromeMetrics(tabBarFontSize: 0.001)
        #expect(metrics.scale == BrowserChromeMetrics.minimumScale)
        #expect(metrics.omnibarFontSize == Self.legacy.omnibarFontSize * BrowserChromeMetrics.minimumScale)
    }

    @Test(arguments: [CGFloat(0), CGFloat(-5), CGFloat.nan, CGFloat.infinity, -CGFloat.infinity])
    func nonPositiveOrNonFiniteFontFallsBackToNeutralScale(_ value: CGFloat) {
        let metrics = BrowserChromeMetrics(tabBarFontSize: value)
        #expect(metrics.scale == 1)
        #expect(metrics.buttonIconSize == Self.legacy.buttonIconSize)
    }
}
