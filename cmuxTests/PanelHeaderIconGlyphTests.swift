import AppKit
import CmuxAppKitSupportUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Panel header icon glyphs")
struct PanelHeaderIconGlyphTests {
    /// Every symbol the markdown viewer and file preview headers render.
    private static let headerSymbols = [
        "doc.richtext",
        "textformat.size",
        "arrow.clockwise",
        "arrow.counterclockwise",
        "square.and.arrow.down",
        "square.and.arrow.up",
        "doc.plaintext",
        "doc.on.doc",
        "chevron.left.forwardslash.chevron.right",
        "eye",
    ]

    @Test func requestCarriesAnExplicitTintAtGlyphSize() {
        let tint = NSColor.systemTeal
        let request = PanelHeaderIconGlyph.request(systemName: "eye", tint: tint, isEnabled: true)

        #expect(request.size == NSSize(width: 13, height: 13))
        #expect(request.tintColor == tint)
        guard case .systemSymbol(let name, _) = request.source else {
            Issue.record("expected a system symbol source")
            return
        }
        #expect(name == "eye")
    }

    @Test func requestFallsBackToSecondaryLabelWhenHeaderTintIsMissing() {
        let request = PanelHeaderIconGlyph.request(systemName: "eye", tint: nil, isEnabled: true)

        #expect(request.tintColor == NSColor.secondaryLabelColor)
    }

    @Test func disabledRequestKeepsTheColorAndDropsAlpha() throws {
        let tint = NSColor.white.withAlphaComponent(0.8)
        let request = PanelHeaderIconGlyph.request(systemName: "eye", tint: tint, isEnabled: false)
        let resolved = try #require(request.tintColor)

        #expect(abs(resolved.alphaComponent - 0.8 * 0.45) < 0.0001)
    }

    @Test func themeTintKeepsSecondaryEmphasis() {
        let foreground = NSColor(calibratedWhite: 0.9, alpha: 1)
        let tint = PanelHeaderIconGlyph.tint(headerForeground: foreground)

        #expect(abs(tint.alphaComponent - 0.55) < 0.0001)
    }

    /// Regression guard for #8558: the SwiftUI symbol path rasterized these
    /// glyphs fully transparent while their buttons stayed clickable. The
    /// resolved renderer must produce visible pixels in either appearance.
    @Test(arguments: headerSymbols)
    func headerSymbolsRenderVisiblePixels(symbol: String) throws {
        let renderer = CmuxResolvedIconRenderer()
        let request = PanelHeaderIconGlyph.request(
            systemName: symbol,
            tint: PanelHeaderIconGlyph.tint(headerForeground: .white),
            isEnabled: true
        )

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            switch renderer.render(for: request, appearance: appearance) {
            case .success(let image):
                #expect(visiblePixelCount(in: image) > 0)
            case .failure(let failure):
                Issue.record("\(symbol) failed to render in \(appearanceName.rawValue): \(failure)")
            }
        }
    }

    private func visiblePixelCount(in image: NSImage) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        var count = 0
        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                if let color = representation.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    count += 1
                }
            }
        }
        return count
    }
}
