import CoreGraphics
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#else
import ImageIO
#endif

/// A fake web page: enough structure to look like a site in a frame.
struct MockPage: Sendable {
    struct Section: Sendable {
        var title: String
        var body: String
    }

    var url: String
    var title: String
    var site: String
    var accent: (Double, Double, Double)
    var dark: Bool
    var headline: String
    var subtitle: String
    var sections: [Section]
    var code: String?

    static let headerHeight = 56.0
    static let heroHeight = 230.0
    static let sectionHeight = 168.0
    static let codeHeight = 190.0
    static let footerHeight = 120.0

    var heroTop: Double { Self.headerHeight }
    var sectionsTop: Double { Self.headerHeight + Self.heroHeight }
    var codeTop: Double { sectionsTop + Double(sections.count) * Self.sectionHeight }
    var contentHeight: Double { codeTop + (code == nil ? 0 : Self.codeHeight) + Self.footerHeight }

    /// Index of the section at page-space `y`.
    func section(atPageY y: Double) -> Int? {
        guard y >= sectionsTop else { return nil }
        let i = Int((y - sectionsTop) / Self.sectionHeight)
        return i < sections.count ? i : nil
    }
}

/// Draws a `MockPage` and encodes it as JPEG.
struct MockPageRenderer {
    var page: MockPage
    var scrollY: Double
    var typed: String
    var loadingProgress: Double?
    var highlightedSection: Int?
    var tick: Int

    /// Returns JPEG bytes and the pixel size.
    func renderJPEG(cssWidth: Double, cssHeight: Double, scale: Double, quality: Double = 0.68) -> (Data, Int, Int)? {
        let s = min(max(scale, 1), 3)
        var pxW = Int((cssWidth * s).rounded())
        var pxH = Int((cssHeight * s).rounded())
        // Keep frames modest.
        let maxPixels = 1_600_000.0
        var effectiveScale = s
        if Double(pxW * pxH) > maxPixels {
            effectiveScale = s * sqrt(maxPixels / Double(pxW * pxH))
            pxW = Int((cssWidth * effectiveScale).rounded())
            pxH = Int((cssHeight * effectiveScale).rounded())
        }
        guard pxW > 0, pxH > 0 else { return nil }
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pxW, height: pxH), format: format)
        let data = renderer.jpegData(withCompressionQuality: quality) { ctx in
            ctx.cgContext.scaleBy(x: effectiveScale, y: effectiveScale)
            draw(in: ctx.cgContext, width: cssWidth, height: cssHeight)
        }
        return (data, pxW, pxH)
        #else
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: effectiveScale, y: -effectiveScale)
        draw(in: ctx, width: cssWidth, height: cssHeight)
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, pxW, pxH)
        #endif
    }

    // MARK: Drawing (top-left origin, CSS px)

    private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private var background: CGColor { page.dark ? rgb(0.05, 0.07, 0.09) : rgb(1, 1, 1) }
    private var foreground: CGColor { page.dark ? rgb(0.90, 0.93, 0.95) : rgb(0.07, 0.08, 0.10) }
    private var secondary: CGColor { page.dark ? rgb(0.55, 0.60, 0.66) : rgb(0.40, 0.42, 0.46) }
    private var card: CGColor { page.dark ? rgb(0.09, 0.11, 0.14) : rgb(0.965, 0.968, 0.975) }
    private var accent: CGColor { rgb(page.accent.0, page.accent.1, page.accent.2) }

    func draw(in ctx: CGContext, width w: Double, height h: Double) {
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -scrollY)
        let pad = 20.0

        // Site header.
        ctx.setFillColor(accent)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: MockPage.headerHeight))
        text(ctx, page.site, CGRect(x: pad, y: 16, width: w - 120, height: 26), size: 19, weight: .bold, color: rgb(1, 1, 1))
        text(ctx, "☰", CGRect(x: w - 44, y: 14, width: 30, height: 28), size: 20, weight: .regular, color: rgb(1, 1, 1))

        // Hero.
        let heroY = page.heroTop + 22
        text(ctx, page.headline, CGRect(x: pad, y: heroY, width: w - pad * 2, height: 72), size: 26, weight: .bold, color: foreground)
        text(ctx, page.subtitle, CGRect(x: pad, y: heroY + 78, width: w - pad * 2, height: 48), size: 15, weight: .regular, color: secondary)
        // Search field with typed text and caret.
        let field = CGRect(x: pad, y: heroY + 136, width: w - pad * 2, height: 40)
        roundRect(ctx, field, radius: 10, fill: card, stroke: page.dark ? rgb(0.2, 0.23, 0.27) : rgb(0.85, 0.86, 0.88))
        let caret = tick % 2 == 0 ? "|" : " "
        text(ctx, typed.isEmpty ? "Search \(page.site)…" : typed + caret, field.insetBy(dx: 12, dy: 10), size: 15, weight: .regular,
             color: typed.isEmpty ? secondary : foreground)

        // Sections.
        for (i, section) in page.sections.enumerated() {
            let y = page.sectionsTop + Double(i) * MockPage.sectionHeight
            let box = CGRect(x: pad, y: y + 8, width: w - pad * 2, height: MockPage.sectionHeight - 16)
            let highlighted = highlightedSection == i
            roundRect(ctx, box, radius: 14, fill: highlighted ? rgb(page.accent.0, page.accent.1, page.accent.2, 0.18) : card, stroke: nil)
            ctx.setFillColor(accent)
            ctx.fill(CGRect(x: box.minX + 14, y: box.minY + 16, width: 6, height: 22))
            text(ctx, section.title, CGRect(x: box.minX + 28, y: box.minY + 14, width: box.width - 42, height: 26), size: 17, weight: .semibold, color: foreground)
            text(ctx, section.body, CGRect(x: box.minX + 14, y: box.minY + 48, width: box.width - 28, height: box.height - 58), size: 14, weight: .regular, color: secondary)
        }

        // Code block.
        if let code = page.code {
            let box = CGRect(x: pad, y: page.codeTop + 10, width: w - pad * 2, height: MockPage.codeHeight - 20)
            roundRect(ctx, box, radius: 12, fill: rgb(0.11, 0.12, 0.15), stroke: nil)
            text(ctx, code, box.insetBy(dx: 14, dy: 14), size: 13, weight: .regular, color: rgb(0.80, 0.86, 0.92), monospaced: true)
        }

        // Footer.
        let footerY = page.contentHeight - MockPage.footerHeight
        ctx.setFillColor(card)
        ctx.fill(CGRect(x: 0, y: footerY, width: w, height: MockPage.footerHeight))
        text(ctx, "\(page.url)\nRendered by the cmux demo host · \(MockShell.clock())", CGRect(x: pad, y: footerY + 24, width: w - pad * 2, height: 60),
             size: 12, weight: .regular, color: secondary)
        ctx.restoreGState()

        // Loading bar (fixed to the viewport).
        if let p = loadingProgress {
            ctx.setFillColor(accent)
            ctx.fill(CGRect(x: 0, y: 0, width: w * max(0.05, min(1, p)), height: 3))
        }
        // Scroll indicator.
        let contentH = page.contentHeight
        if contentH > h {
            let barH = max(30, h * h / contentH)
            let barY = (h - barH) * scrollY / (contentH - h)
            roundRect(ctx, CGRect(x: w - 5, y: barY, width: 3, height: barH), radius: 1.5, fill: rgb(0.5, 0.5, 0.5, 0.5), stroke: nil)
        }
    }

    private func roundRect(_ ctx: CGContext, _ r: CGRect, radius: Double, fill: CGColor, stroke: CGColor?) {
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
    }

    private enum Weight { case regular, semibold, bold }

    private func text(_ ctx: CGContext, _ string: String, _ rect: CGRect, size: Double, weight: Weight, color: CGColor, monospaced: Bool = false) {
        let font: CTFont
        if monospaced {
            font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        } else {
            let base = CTFontCreateUIFontForLanguage(weight == .regular ? .system : .emphasizedSystem, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            font = base
        }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attributed = NSAttributedString(string: string, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
