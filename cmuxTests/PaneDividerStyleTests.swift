import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Pane divider style resolution")
struct PaneDividerStyleTests {
    private func hex(_ string: String) -> NSColor {
        NSColor(cmuxPaneDividerHex: string)!
    }

    @Test("cmux config color overrides the Ghostty split-divider-color")
    func cmuxColorWinsOverGhostty() {
        let override = CmuxPaneDividerOverride(color: hex("#ff0000"))
        let style = PaneDividerStyle.resolved(
            override: override,
            ghosttyDividerColor: hex("#00ff00")
        )
        #expect(style.color?.hexString() == "#FF0000")
    }

    @Test("Ghostty divider color is used when cmux config has no color")
    func ghosttyColorUsedWhenNoCmuxColor() {
        let style = PaneDividerStyle.resolved(
            override: .none,
            ghosttyDividerColor: hex("#78a9ff")
        )
        #expect(style.color?.hexString() == "#78A9FF")
    }

    @Test("With no configured color the explicit color stays nil so it derives from chrome")
    func defaultColorDerivesFromChrome() {
        let style = PaneDividerStyle.resolved(override: .none, ghosttyDividerColor: nil)
        #expect(style.color == nil)
        // A derived color is produced for a given background, and it is more
        // opaque than the legacy hairline separator for the same background.
        let background = hex("#272822")
        let derived = style.resolvedColor(forChromeBackground: background)
        let legacy = WindowChromeSeparatorColor.color(forChromeBackground: background)
        #expect(derived.alphaComponent > legacy.alphaComponent)
    }

    @Test("Default thickness is the more-visible 2pt, not the legacy 1pt hairline")
    func defaultThicknessIsTwo() {
        let style = PaneDividerStyle.resolved(override: .none, ghosttyDividerColor: nil)
        #expect(style.thickness == 2)
    }

    @Test("cmux config thickness overrides the default and is clamped to range")
    func cmuxThicknessWinsAndClamps() {
        #expect(
            PaneDividerStyle.resolved(
                override: CmuxPaneDividerOverride(thickness: 4),
                ghosttyDividerColor: nil
            ).thickness == 4
        )
        #expect(
            PaneDividerStyle.resolved(
                override: CmuxPaneDividerOverride(thickness: 999),
                ghosttyDividerColor: nil
            ).thickness == PaneDividerStyle.maximumThickness
        )
        #expect(
            PaneDividerStyle.resolved(
                override: CmuxPaneDividerOverride(thickness: -3),
                ghosttyDividerColor: nil
            ).thickness == PaneDividerStyle.minimumThickness
        )
    }
}

@Suite("Pane divider config decoding")
struct CmuxConfigPaneDividerTests {
    private func decode(_ json: String) throws -> CmuxConfigPaneDivider {
        try JSONDecoder().decode(CmuxConfigPaneDivider.self, from: Data(json.utf8))
    }

    @Test("Decodes a 6-digit hex color and a thickness")
    func decodesColorAndThickness() throws {
        let config = try decode(##"{ "color": "#3478f6", "thickness": 2.5 }"##)
        #expect(config.color == "#3478f6")
        #expect(config.thickness == 2.5)
    }

    @Test("Accepts an 8-digit color with alpha and exposes it as a translucent NSColor")
    func decodesColorWithAlpha() throws {
        let config = try decode(##"{ "color": "#3478f680" }"##)
        let override = CmuxPaneDividerOverride(config: config)
        let parsed = try #require(override.color)
        #expect(abs(parsed.alphaComponent - (128.0 / 255.0)) < 0.01)
    }

    @Test("Rejects a malformed color")
    func rejectsBadColor() {
        #expect(throws: DecodingError.self) {
            _ = try decode(##"{ "color": "not-a-color" }"##)
        }
    }

    @Test("Rejects a negative thickness")
    func rejectsNegativeThickness() {
        #expect(throws: DecodingError.self) {
            _ = try decode(##"{ "thickness": -1 }"##)
        }
    }

    @Test("Empty override defers to lower configuration layers")
    func emptyOverride() {
        let override = CmuxPaneDividerOverride(config: try? decode("{}"))
        #expect(override.color == nil)
        #expect(override.thickness == nil)
    }
}
