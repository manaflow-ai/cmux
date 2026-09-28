import AppKit
import CmuxFoundation
import CmuxTerminalCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Ghostty split divider color", .serialized)
struct GhosttySplitDividerColorTests {
    @Test
    func parseSplitDividerColorAcceptsGhosttyNamedColor() {
        var config = GhosttyConfig()

        config.parse("split-divider-color = orange")

        #expect(config.splitDividerColor?.hexString() == "#FFA500")
    }

    @Test
    func applyGhosttyChromeUsesConfiguredSplitDividerColor() {
        var config = GhosttyConfig()
        config.parse("""
        background = #272822
        split-divider-color = #78a9ff
        """)

        let workspace = Workspace(title: "Tests")
        defer { workspace.teardownAllPanels() }
        workspace.applyGhosttyChrome(from: config, reason: "test-split-divider-color")

        #expect(workspace.bonsplitController.configuration.appearance.chromeColors.borderHex == "#78A9FF")
    }

    @Test
    func explicitPaneBorderColorOverridesGhosttySplitDividerColor() {
        let colors = Workspace.bonsplitChromeColors(
            backgroundColor: NSColor(hex: "#272822")!,
            backgroundOpacity: 1,
            paneBorderColorHex: "#123456",
            splitDividerColor: .orange
        )

        #expect(colors.borderHex == "#123456")
    }

    // Without an explicit split-divider-color or pane border setting, dividers
    // must keep the 0.64.25 colors (#15091).
    @Test
    func defaultDividerColorsOnBlackBackgroundMatch0_64_25() throws {
        var config = GhosttyConfig()
        config.parse("background = #000000")
        let suiteName = "GhosttySplitDividerColorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(title: "Tests")
        defer { workspace.teardownAllPanels() }
        workspace.applyGhosttyChrome(from: config, reason: "test-default-divider-color")

        #expect(workspace.bonsplitController.configuration.appearance.chromeColors.borderHex == "#2828285B")
        #expect(config.resolvedSplitDividerColor.hexString() == "#000000")
        #expect(PaneChromeSettings.paneBorderColorHex(defaults: defaults) == nil)
        #expect(PaneChromeSettings.activePaneBorderColorHex(defaults: defaults) == nil)
    }

    @Test(arguments: zip(
        ["#FEFFFF", "#FFFFFF", "#FDF6E3"],
        ["#DFE0E042", "#E0E0E042", "#DED7C442"]
    ))
    func defaultDividerColorOnLightBackgroundMatches0_64_25(backgroundHex: String, expectedBorderHex: String) throws {
        let colors = Workspace.bonsplitChromeColors(
            backgroundColor: try #require(NSColor(hex: backgroundHex)),
            backgroundOpacity: 1
        )

        #expect(colors.borderHex == expectedBorderHex)
    }
}
