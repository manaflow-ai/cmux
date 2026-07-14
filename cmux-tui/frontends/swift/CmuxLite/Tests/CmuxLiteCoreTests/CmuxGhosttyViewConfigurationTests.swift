@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxGhosttyViewConfigurationTests {
    @Test
    func parsesSupportedGhosttyViewSettings() {
        let configuration = CmuxGhosttyViewConfiguration.parse(
            """
            font-family = "JetBrains Mono"
            font-size = 15.5
            selection-background = #112233
            selection-foreground = GhostWhite
            cursor-style = bar
            cursor-style-blink = false
            """
        )

        #expect(configuration.fontFamily == "JetBrains Mono")
        #expect(configuration.fontSize == 15.5)
        #expect(configuration.selectionBackground == "#112233")
        #expect(configuration.selectionForeground == "GhostWhite")
        #expect(configuration.cursorStyle == "bar")
        #expect(configuration.cursorBlink == false)
    }

    @Test
    func laterValidEntriesWinAndLaterInvalidEntriesAreIgnored() {
        let configuration = CmuxGhosttyViewConfiguration.parse(
            """
            font-family = Menlo
            font-family = "Berkeley Mono"
            font-family = "unterminated
            font-size = 12
            font-size = 17
            font-size = enormous
            selection-background = #123
            selection-background = #abcdef
            selection-background = not-a-color!
            cursor-style = underline
            cursor-style = beam
            cursor-style-blink = true
            cursor-style-blink = sometimes
            """
        )

        #expect(configuration.fontFamily == "Berkeley Mono")
        #expect(configuration.fontSize == 17)
        #expect(configuration.selectionBackground == "#abcdef")
        #expect(configuration.cursorStyle == "underline")
        #expect(configuration.cursorBlink == true)
    }

    @Test
    func missingOrInvalidFontSettingsUseStableFallbacks() {
        let configuration = CmuxGhosttyViewConfiguration.parse(
            """
            font-family =
            font-size = -2
            """
        )

        #expect(configuration.fontFamily == CmuxGhosttyViewConfiguration.fallbackFontFamily)
        #expect(configuration.fontSize == CmuxGhosttyViewConfiguration.fallbackFontSize)
    }
}
