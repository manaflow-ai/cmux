import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The selected workspace row is always a neutral glass patch with a hairline
/// edge, never the accent colour; multi-selection is the same glass, weaker.
/// A configured `sidebarSelectionColorHex` still wins as a solid fill.
@Suite
struct SidebarGlassSelectionTests {
    @Test
    func darkSolidFillSelectionIsNeutralTranslucentGlass() throws {
        let color = try #require(sidebarSelectedWorkspaceBackgroundNSColor(
            for: .dark,
            sidebarSelectionColorHex: nil,
            activeTabIndicatorStyle: .solidFill
        ).usingColorSpace(.sRGB))
        let glass = try #require(SidebarGlassSelection.fill(for: .dark).usingColorSpace(.sRGB))

        #expect(color.hexString(includeAlpha: true) == glass.hexString(includeAlpha: true))
        #expect(abs(color.redComponent - 1) < 0.001)
        #expect(abs(color.greenComponent - 1) < 0.001)
        #expect(abs(color.blueComponent - 1) < 0.001)
        #expect(color.alphaComponent > 0)
        #expect(color.alphaComponent < 0.5, "Glass selection is translucent")
    }

    /// Light mode on the stock tint is Aside's light look: a near-white pill
    /// (white at 90%) with a dark hairline. A chosen tint keeps the neutral
    /// translucent patch (black, under half opacity).
    @Test
    func lightSelectionIsAsidePillOnTheStockTintAndGlassOtherwise() throws {
        let suite = "SidebarGlassSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let pill = try #require(SidebarGlassSelection.fill(for: .light, defaults: defaults).usingColorSpace(.sRGB))
        #expect(pill.redComponent > 0.999 && pill.greenComponent > 0.999 && pill.blueComponent > 0.999)
        #expect(abs(pill.alphaComponent - 0.9) < 0.001)
        let hairline = try #require(SidebarGlassSelection.edge(for: .light, defaults: defaults).usingColorSpace(.sRGB))
        #expect(hairline.redComponent < 0.001 && abs(hairline.alphaComponent - 0.25) < 0.001)

        defaults.set("#FF0000", forKey: "sidebarTintHex")
        let glass = try #require(SidebarGlassSelection.fill(for: .light, defaults: defaults).usingColorSpace(.sRGB))
        #expect(glass.redComponent < 0.001 && glass.greenComponent < 0.001 && glass.blueComponent < 0.001)
        #expect(glass.alphaComponent > 0 && glass.alphaComponent < 0.5, "Glass selection is translucent")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func selectionIsGlassUnlessSubtleSelectionOrAConfiguredColor(scheme: ColorScheme) {
        #expect(!SettingCatalog().workspaceColors.subtleSelection.defaultValue)
        let glass = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRail,
            isActive: true,
            isMultiSelected: false,
            customColorHex: nil,
            colorScheme: scheme,
            sidebarSelectionColorHex: nil
        )
        #expect(glass.color?.hexString(includeAlpha: true) == SidebarGlassSelection.fill(for: scheme).hexString(includeAlpha: true))
        #expect(glass.color?.hexString() != CmuxAccentColor().nsColor(for: scheme).hexString())
        #expect(abs(glass.opacity - 1) < 0.001)
        #expect(glass.edgeColor?.hexString(includeAlpha: true) == SidebarGlassSelection.edge(for: scheme).hexString(includeAlpha: true))

        // Multi-selection members wear the same glass, weaker, so the active
        // row stays the anchor.
        let multi = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRail,
            isActive: false,
            isMultiSelected: true,
            customColorHex: nil,
            colorScheme: scheme,
            sidebarSelectionColorHex: nil
        )
        #expect(multi.color?.hexString(includeAlpha: true) == glass.color?.hexString(includeAlpha: true))
        #expect(multi.opacity < glass.opacity)
        #expect((multi.edgeColor?.alphaComponent ?? 1) < (glass.edgeColor?.alphaComponent ?? 0))

        // A configured selection colour still wins as a solid fill with no
        // glass edge, even with subtle selection on.
        let configured = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRail,
            isActive: true,
            isMultiSelected: false,
            customColorHex: nil,
            colorScheme: scheme,
            sidebarSelectionColorHex: "#123456",
            subtleSelection: true
        )
        #expect(configured.color?.hexString() == "#123456")
        #expect(configured.edgeColor == nil)
    }

    /// Text on the glass patch keeps the pane's own label colour: the patch is
    /// a tint, not a surface, so there is no accent to contrast against.
    @Test(arguments: [(ColorScheme.light, CGFloat(0)), (.dark, CGFloat(1))])
    func glassSelectionForegroundKeepsThePaneLabelColor(scheme: ColorScheme, expectedWhite: CGFloat) throws {
        let color = try #require(sidebarSelectedWorkspaceForegroundNSColor(
            on: sidebarSelectedWorkspaceBackgroundNSColor(
                for: scheme,
                sidebarSelectionColorHex: nil,
                activeTabIndicatorStyle: .solidFill
            ),
            opacity: 0.65
        ).usingColorSpace(.sRGB))

        #expect(abs(color.redComponent - expectedWhite) < 0.001)
        #expect(abs(color.greenComponent - expectedWhite) < 0.001)
        #expect(abs(color.blueComponent - expectedWhite) < 0.001)
        #expect(abs(color.alphaComponent - 0.65) < 0.001)
    }
}
