import Foundation
import Testing

@testable import CMUXMobileCore

@Suite struct TerminalThemeTests {
    @Test func monokaiDefaultIsValid() {
        #expect(TerminalTheme.monokai.isValid)
        #expect(TerminalTheme.monokai.palette.count == TerminalTheme.paletteCount)
    }

    @Test func jsonRoundTripPreservesColors() throws {
        let theme = TerminalTheme.monokai
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(TerminalTheme.self, from: data)
        #expect(decoded == theme)
    }

    @Test func decodesArbitraryThemeFromJSON() throws {
        // A non-Monokai theme (Solarized Dark-ish) supplied as JSON, proving the
        // app is no longer locked to a single hardcoded palette.
        let json = """
        {
          "background": "#002b36",
          "foreground": "#839496",
          "cursor": "#93a1a1",
          "cursorText": "#002b36",
          "selectionBackground": "#073642",
          "selectionForeground": "#93a1a1",
          "palette": [
            "#073642", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83",
            "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"
          ]
        }
        """
        let theme = try JSONDecoder().decode(TerminalTheme.self, from: Data(json.utf8))
        #expect(theme.isValid)
        #expect(theme.background == "#002b36")
        #expect(theme.palette[1] == "#dc322f")
        #expect(theme.cursorText == "#002b36")
    }

    @Test func invalidThemeFallsBackToMonokai() {
        let shortPalette = TerminalTheme(
            background: "#000000",
            foreground: "#ffffff",
            cursor: "#ffffff",
            selectionBackground: "#333333",
            selectionForeground: "#ffffff",
            palette: ["#000000", "#ffffff"]
        )
        #expect(!shortPalette.isValid)
        #expect(shortPalette.validatedOrDefault() == .monokai)

        let badHex = TerminalTheme(
            background: "not-a-color",
            foreground: "#ffffff",
            cursor: "#ffffff",
            selectionBackground: "#333333",
            selectionForeground: "#ffffff",
            palette: Array(repeating: "#101010", count: TerminalTheme.paletteCount)
        )
        #expect(!badHex.isValid)
        #expect(badHex.validatedOrDefault() == .monokai)
    }

    @Test func rgbComponentsParseHex() {
        #expect(TerminalTheme.rgbComponents("#ff8000")! == (255, 128, 0))
        #expect(TerminalTheme.rgbComponents("ff8000")! == (255, 128, 0))
        #expect(TerminalTheme.rgbComponents("#fff") == nil)
        #expect(TerminalTheme.rgbComponents("zzzzzz") == nil)
        #expect(TerminalTheme.rgbComponents(nil) == nil)
    }

    @Test func ghosttyDirectivesCoverAllColors() {
        let directives = TerminalTheme.monokai.ghosttyColorDirectives
        #expect(directives.contains("background = #272822"))
        #expect(directives.contains("foreground = #fdfff1"))
        #expect(directives.contains("cursor-color = #c0c1b5"))
        #expect(directives.contains("selection-background = #57584f"))
        #expect(directives.contains("selection-foreground = #fdfff1"))
        for index in 0..<TerminalTheme.paletteCount {
            #expect(directives.contains("palette = \(index)="))
        }
        // No cursor-text directive when the theme leaves it nil.
        #expect(!directives.contains("cursor-text ="))
    }

    @Test func ghosttyDirectivesEmitCursorTextWhenPresent() {
        var theme = TerminalTheme.monokai
        theme.cursorText = "#8d8e82"
        #expect(theme.ghosttyColorDirectives.contains("cursor-text = #8d8e82"))
    }

    @Test func ghosttyDirectivesPreserveExtendedPaletteAndCellRelativeColors() {
        var theme = TerminalTheme.monokai
        theme.palette = (0..<TerminalTheme.extendedPaletteCount).map {
            String(format: "#%06x", $0)
        }
        theme.cursorColorSemantic = .foreground
        theme.cursorTextSemantic = .background
        theme.selectionBackgroundSemantic = .foreground
        theme.selectionForegroundSemantic = .background

        let directives = theme.ghosttyColorDirectives

        #expect(theme.isValid)
        #expect(directives.contains("palette = 255=#0000ff"))
        #expect(directives.contains("cursor-color = cell-foreground"))
        #expect(directives.contains("cursor-text = cell-background"))
        #expect(directives.contains("selection-background = cell-foreground"))
        #expect(directives.contains("selection-foreground = cell-background"))
    }

    @Test func ghosttyDirectivesNormalizeBareHexToCanonical() {
        // A bare `rrggbb` (no `#`) still parses via rgbComponents, but the
        // emitted directive must be canonical `#rrggbb` for the theme contract.
        let theme = TerminalTheme(
            background: "ff8000",
            foreground: "#FDFFF1",
            cursor: "#c0c1b5",
            selectionBackground: "#57584f",
            selectionForeground: "#fdfff1",
            palette: Array(repeating: "aabbcc", count: TerminalTheme.paletteCount)
        )
        let directives = theme.ghosttyColorDirectives
        #expect(directives.contains("background = #ff8000"))
        // Uppercase input is normalized to lowercase canonical form.
        #expect(directives.contains("foreground = #fdfff1"))
        #expect(directives.contains("palette = 0=#aabbcc"))
        #expect(!directives.contains("background = ff8000"))
    }

    @Test func decodedThemeCarriesCustomBoldColorIntoGhosttyConfig() throws {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(TerminalTheme.monokai)) as? [String: Any]
        )
        var themeObject = object
        themeObject["boldColor"] = "#4e2a84"
        let data = try JSONSerialization.data(withJSONObject: themeObject)

        let theme = try JSONDecoder().decode(TerminalTheme.self, from: data)

        #expect(theme.ghosttyColorDirectives.contains("bold-color = #4e2a84"))
    }

    @Test func decodedThemeCarriesBrightBoldColorIntoGhosttyConfig() throws {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(TerminalTheme.monokai)) as? [String: Any]
        )
        var themeObject = object
        themeObject["boldColor"] = "bright"
        let data = try JSONSerialization.data(withJSONObject: themeObject)

        let theme = try JSONDecoder().decode(TerminalTheme.self, from: data)

        #expect(theme.ghosttyColorDirectives.contains("bold-color = bright"))
    }

}
