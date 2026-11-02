import CoreGraphics
import CmuxFoundation
import Foundation
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
        #expect(metrics.plusFrame == SidebarWorkspaceGroupHeaderMetrics.basePlusFrame)
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

    @Test func groupPlusAndWorkspaceCloseShareTrailingXPositions() {
        let closeButtonWidth = SidebarTrailingAccessoryWidthPolicy().closeButtonWidth
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: 1)

        #expect(SidebarWorkspaceListMetrics.rowContentHorizontalPadding == 10)
        #expect(SidebarWorkspaceListMetrics.rowOuterHorizontalPadding == 6)
        #expect(metrics.plusFrame == closeButtonWidth)
        #expect(SidebarWorkspaceListMetrics.trailingAccessoryRightEdgeOffset == 16)
        #expect(SidebarWorkspaceListMetrics.trailingAccessoryCenterOffset(controlWidth: metrics.plusFrame) == 24)
        #expect(
            SidebarWorkspaceListMetrics.trailingAccessoryCenterOffset(controlWidth: metrics.plusFrame)
                == SidebarWorkspaceListMetrics.trailingAccessoryCenterOffset(controlWidth: closeButtonWidth)
        )
    }

    @Test func groupScopedHeaderBottomIndicatorAlignsWithMemberRows() {
        for scale in [CGFloat(0.5), CGFloat(1), CGFloat(2)] {
            let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: scale)

            #expect(
                metrics.groupScopedBottomDropIndicatorLeadingInset
                    == SidebarWorkspaceGroupingMetrics.memberIndent
            )
        }
    }

    @Test func groupPlusAndWorkspaceCloseStayAlignedWhenFontScaleChanges() {
        for scale in [CGFloat(0.5), CGFloat(1), CGFloat(2)] {
            let closeButtonWidth = max(
                SidebarTrailingAccessoryWidthPolicy().closeButtonWidth,
                SidebarWorkspaceGroupHeaderMetrics.basePlusFrame * scale
            )
            let plusButtonWidth = SidebarWorkspaceGroupHeaderMetrics(fontScale: scale).plusFrame

            #expect(plusButtonWidth == closeButtonWidth)
            #expect(
                SidebarWorkspaceListMetrics.trailingAccessoryCenterOffset(controlWidth: plusButtonWidth)
                    == SidebarWorkspaceListMetrics.trailingAccessoryCenterOffset(controlWidth: closeButtonWidth)
            )
        }
    }

    @Test func nameSizeGrowsWithDividersOnAndKeepsBaselineOff() {
        let on = SidebarWorkspaceGroupHeaderMetrics(fontScale: 1, showsGroupDividers: true)
        let off = SidebarWorkspaceGroupHeaderMetrics(fontScale: 1, showsGroupDividers: false)

        #expect(on.nameFontSize == 12.5)
        #expect(off.nameFontSize == 11)
        #expect(off.nameFontSize == SidebarWorkspaceGroupHeaderMetrics.baseNameFontSize)
    }

    @Test func nameSizeScalesWithFontScaleInBothDividerStates() {
        for scale in [CGFloat(0.5), CGFloat(1), CGFloat(2)] {
            #expect(
                SidebarWorkspaceGroupHeaderMetrics(fontScale: scale, showsGroupDividers: true).nameFontSize
                    == SidebarWorkspaceGroupHeaderMetrics.baseNameFontSizeWithDividers * scale
            )
            #expect(
                SidebarWorkspaceGroupHeaderMetrics(fontScale: scale, showsGroupDividers: false).nameFontSize
                    == SidebarWorkspaceGroupHeaderMetrics.baseNameFontSize * scale
            )
        }
    }

    @Test func topGapScalesWithFontScaleWhenDividersOn() {
        for scale in [CGFloat(0.5), CGFloat(1), CGFloat(2)] {
            let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: scale, showsGroupDividers: true)

            #expect(metrics.topGap == SidebarWorkspaceGroupHeaderMetrics.baseTopGap * scale)
            #expect(
                metrics.topGap(isFirstRenderedRow: false)
                    == SidebarWorkspaceGroupHeaderMetrics.baseTopGap * scale
            )
        }
    }

    @Test func topGapIsZeroForFirstRenderedRowAndWhenDividersOff() {
        let on = SidebarWorkspaceGroupHeaderMetrics(fontScale: 2, showsGroupDividers: true)
        #expect(on.topGap(isFirstRenderedRow: true) == 0)

        let off = SidebarWorkspaceGroupHeaderMetrics(fontScale: 2, showsGroupDividers: false)
        #expect(off.topGap(isFirstRenderedRow: false) == 0)
        #expect(off.topGap(isFirstRenderedRow: true) == 0)
    }
}

@Suite struct SidebarWorkspaceGroupingMetricsTests {
    @Test func guideWidthIsTwoPoints() {
        #expect(SidebarWorkspaceGroupingMetrics.guideWidth == 2)
    }

    @Test func guideCenterXSitsInTheMiddleOfTheMemberIndent() {
        #expect(
            SidebarWorkspaceGroupingMetrics.guideCenterX
                == SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
                    + SidebarWorkspaceGroupingMetrics.memberIndent / 2
        )
    }

    @Test func guideEndRunBottomInsetScalesWithFontScale() {
        for scale in [CGFloat(0.5), CGFloat(1), CGFloat(2)] {
            #expect(
                SidebarWorkspaceGroupingMetrics.guideEndRunBottomInset(fontScale: scale)
                    == SidebarWorkspaceGroupingMetrics.baseGuideEndRunBottomInset * scale
            )
        }
    }

    @Test func showsGuideFollowsTheMinimumIndent() {
        #expect(SidebarWorkspaceGroupingMetrics.guideMinimumIndent == 6)
        #expect(
            SidebarWorkspaceGroupingMetrics.showsGuide
                == (SidebarWorkspaceGroupingMetrics.memberIndent
                    >= SidebarWorkspaceGroupingMetrics.guideMinimumIndent)
        )
        // Today's 12 pt member indent clears the 6 pt minimum, so the guide is
        // declared visible; it is declared hidden only below the minimum.
        #expect(SidebarWorkspaceGroupingMetrics.showsGuide)
    }
}

@Suite struct SidebarGroupDividersSettingTests {
    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarGroupDividersSettingTests.\(UUID().uuidString)")!
    }

    @Test func snapshotDefaultsGroupDividersOnAndFollowsDefaultsKey() {
        let defaultSnapshot = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        #expect(defaultSnapshot.showsGroupDividers)

        let offDefaults = Self.makeDefaults()
        offDefaults.set(false, forKey: "sidebarGroupDividers")
        #expect(!SidebarTabItemSettingsSnapshot(defaults: offDefaults).showsGroupDividers)

        let onDefaults = Self.makeDefaults()
        onDefaults.set(true, forKey: "sidebarGroupDividers")
        #expect(SidebarTabItemSettingsSnapshot(defaults: onDefaults).showsGroupDividers)
    }
}
