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
    func parsesResolvedShowConfigOutput() throws {
        let configuration = try #require(CmuxGhosttyViewConfiguration.parseResolvedOutput(
            """
            font-family = Menlo
            font-size = 12
            background = #272822
            foreground = #fdfff1
            selection-foreground = #fdfff1
            selection-background = #57584f
            palette = 0=#272822
            palette = 1=#f92672
            palette = 255=#eeeeee
            cursor-style = bar
            cursor-style-blink = false
            """
        ))

        #expect(configuration.fontFamily == "Menlo")
        #expect(configuration.fontSize == 12)
        #expect(configuration.background == "#272822")
        #expect(configuration.foreground == "#fdfff1")
        #expect(configuration.palette == [
            0: "#272822",
            1: "#f92672",
            255: "#eeeeee",
        ])
        #expect(configuration.selectionBackground == "#57584f")
        #expect(configuration.selectionForeground == "#fdfff1")
        #expect(configuration.cursorStyle == "bar")
        #expect(configuration.cursorBlink == false)
    }

    @Test
    func fallbackKeepsTheLastLoadableThemeWhenALaterThemeIsMissing() {
        let configuration = CmuxGhosttyViewConfiguration.parseFallback(
            """
            theme = "Monokai Classic"
            theme = "Aizen Light"
            cursor-style = bar
            """
        ) { name in
            guard name == "Monokai Classic" else { return nil }
            return """
            background = #272822
            foreground = #fdfff1
            palette = 1=#f92672
            """
        }

        #expect(configuration.background == "#272822")
        #expect(configuration.foreground == "#fdfff1")
        #expect(configuration.palette[1] == "#f92672")
        #expect(configuration.cursorStyle == "bar")
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
