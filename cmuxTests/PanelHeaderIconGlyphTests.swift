import AppKit
import CmuxAppKitSupportUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Panel header icon glyphs")
struct PanelHeaderIconGlyphTests {
    /// Every SF Symbol shown in a panel file-path header (markdown viewer and
    /// file preview), plus the default leading icons.
    private static let headerSymbols: [String] = [
        "textformat.size",
        "arrow.clockwise",
        "arrow.counterclockwise",
        "square.and.arrow.down",
        "square.and.arrow.up",
        "doc.plaintext",
        "eye",
        "doc.on.doc",
        "chevron.left.forwardslash.chevron.right",
        "doc.richtext",
        "doc.viewfinder",
    ]

    @Test @MainActor func requestUsesExplicitTintAndSymbolSource() throws {
        let tint = NSColor(srgbRed: 0.9, green: 0.8, blue: 0.7, alpha: 1)
        let request = PanelHeaderIconGlyph.request(
            systemName: "textformat.size",
            tint: tint,
            isEnabled: true
        )
        guard case .systemSymbol(let name, _) = request.source else {
            Issue.record("expected a system symbol source")
            return
        }
        #expect(name == "textformat.size")
        #expect(request.size == NSSize(width: 13, height: 13))
        #expect(request.tintColor == tint)
    }

    @Test @MainActor func requestFallsBackToSecondaryLabelTint() {
        let request = PanelHeaderIconGlyph.request(
            systemName: "arrow.clockwise",
            tint: nil,
            isEnabled: true
        )
        #expect(request.tintColor == NSColor.secondaryLabelColor)
    }

    @Test @MainActor func disabledRequestReducesTintAlpha() throws {
        let tint = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8)
        let request = PanelHeaderIconGlyph.request(
            systemName: "square.and.arrow.down",
            tint: tint,
            isEnabled: false
        )
        let resolvedTint = try #require(request.tintColor)
        #expect(abs(resolvedTint.alphaComponent - 0.8 * 0.45) < 0.001)
    }

    @Test @MainActor func headerForegroundTintKeepsColorAtSecondaryEmphasis() {
        let foreground = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let tint = PanelHeaderIconGlyph.tint(headerForeground: foreground)
        #expect(abs(tint.alphaComponent - 0.55) < 0.001)
        #expect(abs(tint.redComponent - 0.2) < 0.001)
        #expect(abs(tint.greenComponent - 0.4) < 0.001)
        #expect(abs(tint.blueComponent - 0.6) < 0.001)
    }

    /// Renders every header symbol through the appearance-resolved renderer in
    /// both light and dark appearances. The renderer fails with `.blankOutput`
    /// when the drawn bitmap has no visible pixels, so a returned image proves
    /// the glyph is actually visible — the regression behind #8352.
    @Test(arguments: headerSymbols)
    @MainActor func headerSymbolRendersVisiblyInBothAppearances(symbolName: String) throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            let request = PanelHeaderIconGlyph.request(
                systemName: symbolName,
                tint: nil,
                isEnabled: true
            )
            let rendered = CmuxResolvedIconRenderer().render(for: request, appearance: appearance)
            switch rendered {
            case .success(let image):
                #expect(image.size.width > 0)
                #expect(image.size.height > 0)
            case .failure(let failure):
                Issue.record("\(symbolName) failed to render under \(appearanceName.rawValue): \(failure)")
            }
        }
    }
}
