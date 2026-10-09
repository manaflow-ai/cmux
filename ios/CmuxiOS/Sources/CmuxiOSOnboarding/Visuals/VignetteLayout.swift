import UIKit

/// Geometry of the vignette for a font and width.
struct VignetteLayout {
    let font: UIFont
    let width: CGFloat
    let inset: CGFloat = 14
    let top: CGFloat = 36
    let corner: CGFloat = 14
    let lineCount = 5

    var lineHeight: CGFloat { ceil(font.lineHeight * 1.4) }
    var characterWidth: CGFloat { ("M" as NSString).size(withAttributes: [.font: font]).width }
    var cardHeight: CGFloat { ceil(font.lineHeight * 1.4 + 30) }
    var windowHeight: CGFloat { top + CGFloat(lineCount) * lineHeight + 12 + cardHeight + 12 }

    func lineFrame(_ index: Int, x: CGFloat = 0) -> CGRect {
        CGRect(x: inset + x, y: top + CGFloat(index) * lineHeight, width: width - inset * 2 - x, height: lineHeight)
    }

    var cardFrame: CGRect {
        CGRect(x: 12, y: windowHeight - cardHeight - 12, width: width - 24, height: cardHeight)
    }
}
