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
    let baselinePoints: CGFloat

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

        let ctFont = regular as CTFont
        var glyph = CTFontGetGlyphWithName(ctFont, "M" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        cellWidthPoints = max(1, ceil(advance.width * 64) / 64)
        let rawHeight = regular.ascender - regular.descender + regular.leading
        cellHeightPoints = max(1, ceil(rawHeight * 64) / 64)
        baselinePoints = regular.ascender
    }

    func cellWidthPixels(backingScale: CGFloat) -> UInt32 {
        UInt32(max(1, ceil(cellWidthPoints * backingScale)))
    }

    func cellHeightPixels(backingScale: CGFloat) -> UInt32 {
        UInt32(max(1, ceil(cellHeightPoints * backingScale)))
    }

    func font(for style: CmuxRenderStyle) -> NSFont {
        switch (style.bold, style.italic) {
        case (true, true): boldItalicFont
        case (true, false): boldFont
        case (false, true): italicFont
        case (false, false): regularFont
        }
    }
}
