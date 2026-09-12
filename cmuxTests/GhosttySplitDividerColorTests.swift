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
}
