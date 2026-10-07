import CmuxiOSSettingsCore
import CmuxTerminalRenderCore
import CmuxTheme
import Foundation
import Testing

@Suite struct TerminalPreferencesTests {
    @Test func defaultsMatchTheRenderer() {
        let appearance = TerminalPreferences().appearance
        #expect(appearance.theme == nil)
        #expect(appearance.fontFamily == nil)
        #expect(appearance.baseFontSize == TerminalFontSizing().baseSize)
        #expect(appearance.followsDynamicType)
        #expect(appearance.cursorStyle == .block)
        #expect(!appearance.cursorBlink)
        #expect(appearance.keyBarKeyIDs == KeyBarKeyID.defaultOrder.map(\.rawValue))
    }

    @Test func codableRoundTrip() throws {
        let value = TerminalPreferences(theme: .paper, font: .menlo, fontSize: 16, followsDynamicType: false,
                                        cursorStyle: .underline, cursorBlink: true, keyBarKeys: [.escape, .tab, .paste])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(TerminalPreferences.self, from: data) == value)
    }

    @Test func unknownValuesFallBackPerField() throws {
        let json = #"{"theme":"solarized","font":"menlo","fontSize":"big","cursorStyle":"beam","keyBarKeys":["esc","f13","tab"]}"#
        let value = try JSONDecoder().decode(TerminalPreferences.self, from: Data(json.utf8))
        #expect(value.theme == .matchMac)
        #expect(value.font == .menlo)
        #expect(value.fontSize == TerminalPreferences.defaultFontSize)
        #expect(value.cursorStyle == .block)
        #expect(value.keyBarKeys == [.escape, .tab])
    }

    @Test func normalizationClampsAndDedupes() {
        let value = TerminalPreferences(fontSize: 99.4, keyBarKeys: [.tab, .tab, .escape]).normalized()
        #expect(value.fontSize == TerminalPreferences.fontSizeRange.upperBound)
        #expect(value.keyBarKeys == [.tab, .escape])
        #expect(TerminalPreferences(fontSize: 1).normalized().fontSize == 9)
        #expect(TerminalPreferences(fontSize: 14.6).normalized().fontSize == 15)
        #expect(TerminalPreferences(keyBarKeys: []).normalized().keyBarKeys == KeyBarKeyID.defaultOrder)
    }

    @Test func themeChoicesMapToThemeInputs() {
        #expect(TerminalThemeChoice.matchMac.themeInput == nil)
        #expect(TerminalThemeChoice.ghosttyDefault.themeInput == .ghosttyDefault)
        #expect(TerminalThemeChoice.monokai.themeInput?.background == ThemeRGB(hex: 0x272822))
        for choice in TerminalThemeChoice.allCases where choice != .matchMac {
            #expect(choice.themeInput?.palette.count == 16, "\(choice)")
        }
        // Paper is light, Ink is dark.
        let paper = TerminalThemeChoice.paper.themeInput!.background
        let ink = TerminalThemeChoice.ink.themeInput!.background
        #expect(paper.red > 0.9 && ink.red < 0.1)
    }

    @Test func appearanceFeedsGhosttyConfig() {
        let appearance = TerminalPreferences(theme: .ink, font: .courierNew, cursorStyle: .bar, cursorBlink: true).appearance
        let config = TerminalGhosttyConfig(fontSize: appearance.baseFontSize, theme: appearance.theme,
                                           cursorBlink: appearance.cursorBlink, fontFamily: appearance.fontFamily,
                                           cursorStyle: appearance.cursorStyle)
        let lines = config.text.split(separator: "\n").map(String.init)
        #expect(lines.contains("font-family = Courier New"))
        #expect(lines.contains("cursor-style = bar"))
        #expect(lines.contains("cursor-style-blink = true"))
        #expect(lines.contains("background = #0E0E10"))
    }
}
