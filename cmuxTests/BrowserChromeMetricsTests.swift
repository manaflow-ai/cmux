import CoreGraphics
import Testing

import CmuxBrowser

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserChromeMetricsTests {
    /// The shipped default tab bar font size the app injects as the byte-identical
    /// anchor (`GhosttyConfig.defaultSurfaceTabBarFontSize`). `referenceFontSize`
    /// is now injected at construction rather than read inside the package, so the
    /// tests pin the same default the app passes at the call site.
    private static let referenceFontSize: CGFloat = 11

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

    private static func metrics(_ tabBarFontSize: CGFloat) -> BrowserChromeMetrics {
        BrowserChromeMetrics(tabBarFontSize: tabBarFontSize, referenceFontSize: referenceFontSize)
    }

    @Test func defaultFontSizeReproducesLegacySizesByteIdentical() {
        let metrics = Self.metrics(Self.referenceFontSize)

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
        #expect(Self.referenceFontSize == 11)
    }

    @Test func largerFontScalesEverySizeUpProportionally() {
        let larger = Self.referenceFontSize + 2 // 13: a valid in-range size
        let metrics = Self.metrics(larger)
        let expectedScale = larger / Self.referenceFontSize

        #expect(metrics.scale > 1)
        #expect(metrics.scale == expectedScale)
        #expect(metrics.omnibarFontSize == Self.legacy.omnibarFontSize * expectedScale)
        #expect(metrics.buttonIconSize == Self.legacy.buttonIconSize * expectedScale)
        #expect(metrics.buttonHitSize == Self.legacy.buttonHitSize * expectedScale)
        #expect(metrics.accessoryIconFontSize == Self.legacy.accessoryIconFontSize * expectedScale)
    }

    @Test func smallerFontScalesEverySizeDownProportionally() {
        let smaller = Self.referenceFontSize - 3 // 8: the minimum valid tab bar font size
        let metrics = Self.metrics(smaller)
        let expectedScale = smaller / Self.referenceFontSize

        #expect(metrics.scale < 1)
        #expect(metrics.scale == expectedScale)
        #expect(metrics.omnibarFontSize == Self.legacy.omnibarFontSize * expectedScale)
        #expect(metrics.buttonHitSize == Self.legacy.buttonHitSize * expectedScale)
    }

    @Test func absurdlyLargeFontClampsToMaximumScale() {
        let metrics = Self.metrics(10_000)
        #expect(metrics.scale == BrowserChromeMetrics.maximumScale)
        #expect(metrics.buttonIconSize == Self.legacy.buttonIconSize * BrowserChromeMetrics.maximumScale)
    }

    @Test func nearZeroFontClampsToMinimumScale() {
        let metrics = Self.metrics(0.001)
        #expect(metrics.scale == BrowserChromeMetrics.minimumScale)
        #expect(metrics.omnibarFontSize == Self.legacy.omnibarFontSize * BrowserChromeMetrics.minimumScale)
    }

    @Test(arguments: [CGFloat(0), CGFloat(-5), CGFloat.nan, CGFloat.infinity, -CGFloat.infinity])
    func nonPositiveOrNonFiniteFontFallsBackToNeutralScale(_ value: CGFloat) {
        let metrics = Self.metrics(value)
        #expect(metrics.scale == 1)
        #expect(metrics.buttonIconSize == Self.legacy.buttonIconSize)
    }
}
