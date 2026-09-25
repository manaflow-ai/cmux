import AppKit
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarRowPaletteTests {
    @Test(arguments: [false, true])
    func rowPaletteSemanticColorsFollowRowSchemeAcrossAppearances(colorSchemeIsDark: Bool) throws {
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))
        let semanticColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .white
                : .black
        }
        let palette = SidebarRowPalette(model: SidebarAppKitRowCellTests.makeModel(colorSchemeIsDark: colorSchemeIsDark))
        // cmux's theme can differ from AppKit's appearance when the row is configured or drawn.
        let constructionAppearance = colorSchemeIsDark ? lightAppearance : darkAppearance
        var colors: [(NSColor, CGFloat)] = []
        constructionAppearance.performAsCurrentDrawingAppearance {
            colors = [
                (palette.semantic(semanticColor), 1),
                (palette.semantic(semanticColor, opacity: 0.6), 0.6),
            ]
        }
        let expectedComponent: CGFloat = colorSchemeIsDark ? 1 : 0
        let expectedColor = NSColor(
            srgbRed: expectedComponent,
            green: expectedComponent,
            blue: expectedComponent,
            alpha: 1
        )

        for (color, expectedAlpha) in colors {
            let light = try SidebarAppKitRowCellTests.resolvedColor(color, in: lightAppearance)
            let dark = try SidebarAppKitRowCellTests.resolvedColor(color, in: darkAppearance)

            #expect(SidebarAppKitRowCellTests.distance(light, expectedColor) < 0.001)
            #expect(SidebarAppKitRowCellTests.distance(dark, expectedColor) < 0.001)
            #expect(abs(light.alphaComponent - expectedAlpha) < 0.001)
            #expect(abs(dark.alphaComponent - expectedAlpha) < 0.001)
        }
    }
}
