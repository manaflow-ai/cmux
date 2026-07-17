import AppKit
import CmuxLiteCore
import CoreText

@MainActor
struct CmuxRenderFontMetrics {
    let regularFont: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    let boldItalicFont: NSFont
    let cellWidthPoints: CGFloat
    let cellHeightPoints: CGFloat

    init(configuration: CmuxGhosttyViewConfiguration) {
        let size = CGFloat(configuration.fontSize)
        let regular = NSFont(name: configuration.fontFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let manager = NSFontManager.shared
        regularFont = regular
        boldFont = manager.convert(regular, toHaveTrait: .boldFontMask)
        italicFont = manager.convert(regular, toHaveTrait: .italicFontMask)
        boldItalicFont = manager.convert(
            manager.convert(regular, toHaveTrait: .boldFontMask),
            toHaveTrait: .italicFontMask
        )

        cellWidthPoints = max(1, Self.printableASCIIWidth(font: regular as CTFont))
        cellHeightPoints = max(1, regular.ascender - regular.descender + regular.leading)
    }

    func cellWidthPixels(backingScale: CGFloat) -> UInt32 {
        UInt32(max(1, (cellWidthPoints * backingScale).rounded()))
    }

    func cellHeightPixels(backingScale: CGFloat) -> UInt32 {
        UInt32(max(1, (cellHeightPoints * backingScale).rounded()))
    }

    func alignedCellWidthPoints(backingScale: CGFloat) -> CGFloat {
        CGFloat(cellWidthPixels(backingScale: backingScale)) / backingScale
    }

    func alignedCellHeightPoints(backingScale: CGFloat) -> CGFloat {
        CGFloat(cellHeightPixels(backingScale: backingScale)) / backingScale
    }

    func topToBaselinePoints(backingScale: CGFloat) -> CGFloat {
        let cellHeight = CGFloat(cellHeightPixels(backingScale: backingScale))
        let faceHeight = cellHeightPoints * backingScale
        let faceBaselineFromBottom = (regularFont.leading / 2 - regularFont.descender) * backingScale
        let cellBaselineFromBottom = (
            faceBaselineFromBottom - (cellHeight - faceHeight) / 2
        ).rounded()
        return (cellHeight - cellBaselineFromBottom) / backingScale
    }

    func font(for style: CmuxRenderStyle) -> NSFont {
        switch (style.bold, style.italic) {
        case (true, true): boldItalicFont
        case (true, false): boldFont
        case (false, true): italicFont
        case (false, false): regularFont
        }
    }

    func glyphAdvance(_ text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func printableASCIIWidth(font: CTFont) -> CGFloat {
        var characters = (32...126).map(UniChar.init)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        var advances = Array(repeating: CGSize.zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)
        return advances.map(\.width).max() ?? 1
    }
}
