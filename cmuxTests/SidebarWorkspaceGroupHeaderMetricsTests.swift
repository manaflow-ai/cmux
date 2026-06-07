import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarWorkspaceGroupHeaderMetricsTests {
    @Test func metricsMatchBaseSizesAtDefaultScale() {
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: 1)

        #expect(metrics.chevronFontSize == SidebarWorkspaceGroupHeaderMetrics.baseChevronFontSize)
        #expect(metrics.chevronFrame == SidebarWorkspaceGroupHeaderMetrics.baseChevronFrame)
        #expect(metrics.iconFontSize == SidebarWorkspaceGroupHeaderMetrics.baseIconFontSize)
        #expect(metrics.iconFrame == SidebarWorkspaceGroupHeaderMetrics.baseIconFrame)
        #expect(metrics.nameFontSize == SidebarWorkspaceGroupHeaderMetrics.baseNameFontSize)
        #expect(metrics.unreadFontSize == SidebarWorkspaceGroupHeaderMetrics.baseUnreadFontSize)
        #expect(metrics.unreadHorizontalPadding == SidebarWorkspaceGroupHeaderMetrics.baseUnreadHorizontalPadding)
        #expect(metrics.unreadVerticalPadding == SidebarWorkspaceGroupHeaderMetrics.baseUnreadVerticalPadding)
        #expect(metrics.plusFontSize == SidebarWorkspaceGroupHeaderMetrics.basePlusFontSize)
        #expect(metrics.plusFrame == SidebarWorkspaceGroupHeaderMetrics.basePlusFrame)
    }

    @Test func metricsScaleProportionallyWhenSidebarFontEnlarged() {
        let scale: CGFloat = 2
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: scale)

        #expect(metrics.chevronFontSize == SidebarWorkspaceGroupHeaderMetrics.baseChevronFontSize * scale)
        #expect(metrics.chevronFrame == SidebarWorkspaceGroupHeaderMetrics.baseChevronFrame * scale)
        #expect(metrics.iconFontSize == SidebarWorkspaceGroupHeaderMetrics.baseIconFontSize * scale)
        #expect(metrics.iconFrame == SidebarWorkspaceGroupHeaderMetrics.baseIconFrame * scale)
        #expect(metrics.nameFontSize == SidebarWorkspaceGroupHeaderMetrics.baseNameFontSize * scale)
        #expect(metrics.unreadFontSize == SidebarWorkspaceGroupHeaderMetrics.baseUnreadFontSize * scale)
        #expect(metrics.unreadHorizontalPadding == SidebarWorkspaceGroupHeaderMetrics.baseUnreadHorizontalPadding * scale)
        #expect(metrics.unreadVerticalPadding == SidebarWorkspaceGroupHeaderMetrics.baseUnreadVerticalPadding * scale)
        #expect(metrics.plusFontSize == SidebarWorkspaceGroupHeaderMetrics.basePlusFontSize * scale)
        #expect(metrics.plusFrame == SidebarWorkspaceGroupHeaderMetrics.basePlusFrame * scale)
    }

    @Test func metricsScaleProportionallyWhenSidebarFontShrunk() {
        let scale: CGFloat = 0.5
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: scale)

        #expect(metrics.chevronFontSize == SidebarWorkspaceGroupHeaderMetrics.baseChevronFontSize * scale)
        #expect(metrics.chevronFrame == SidebarWorkspaceGroupHeaderMetrics.baseChevronFrame * scale)
        #expect(metrics.iconFontSize == SidebarWorkspaceGroupHeaderMetrics.baseIconFontSize * scale)
        #expect(metrics.iconFrame == SidebarWorkspaceGroupHeaderMetrics.baseIconFrame * scale)
        #expect(metrics.nameFontSize == SidebarWorkspaceGroupHeaderMetrics.baseNameFontSize * scale)
        #expect(metrics.unreadFontSize == SidebarWorkspaceGroupHeaderMetrics.baseUnreadFontSize * scale)
        #expect(metrics.unreadHorizontalPadding == SidebarWorkspaceGroupHeaderMetrics.baseUnreadHorizontalPadding * scale)
        #expect(metrics.unreadVerticalPadding == SidebarWorkspaceGroupHeaderMetrics.baseUnreadVerticalPadding * scale)
        #expect(metrics.plusFontSize == SidebarWorkspaceGroupHeaderMetrics.basePlusFontSize * scale)
        #expect(metrics.plusFrame == SidebarWorkspaceGroupHeaderMetrics.basePlusFrame * scale)
    }

    @Test func headerAndRowFontScaleShareOneScalingPath() {
        // The header must grow at the same rate as the workspace rows, which
        // derive their scale from SidebarTabItemFontScale. Reusing that scale
        // keeps the two in lockstep instead of introducing a second path.
        let enlargedSize = GhosttyConfig.defaultSidebarFontSize * 1.6
        let rowScale = SidebarTabItemFontScale.scale(for: enlargedSize)
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: rowScale)

        #expect(metrics.nameFontSize == SidebarWorkspaceGroupHeaderMetrics.baseNameFontSize * rowScale)
        #expect(rowScale > 1)
    }
}
