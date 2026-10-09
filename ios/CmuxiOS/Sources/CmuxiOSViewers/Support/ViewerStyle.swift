import CmuxiOSViewersCore
import UIKit

/// Fonts and colors of the viewers. Fonts scale with Dynamic Type through
/// `UIFontMetrics`; colors are system colors, so they follow light, dark and
/// Increase Contrast. Diff tints are subtle grays-plus-hue, never accents.
@MainActor
struct ViewerStyle {
    let traits: UITraitCollection

    init(traits: UITraitCollection) {
        self.traits = traits
    }

    var code: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                                      compatibleWith: traits)
    }

    var codeBold: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .semibold),
                                                      compatibleWith: traits)
    }

    var gutter: UIFont {
        UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                          compatibleWith: traits)
    }

    func color(_ kind: SyntaxTokenKind) -> UIColor {
        switch kind {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .secondaryLabel
        case .number: .systemPurple
        case .type: .systemTeal
        case .tag: .systemPink
        case .attribute: .systemOrange
        case .heading: .label
        }
    }

    static let additionBackground = UIColor.systemGreen.withAlphaComponent(0.12)
    static let removalBackground = UIColor.systemRed.withAlphaComponent(0.12)
    static let additionEmphasis = UIColor.systemGreen.withAlphaComponent(0.32)
    static let removalEmphasis = UIColor.systemRed.withAlphaComponent(0.32)
    static let hunkBackground = UIColor.tertiarySystemFill
    static let gutterText = UIColor.tertiaryLabel
    static let codeBlockBackground = UIColor.secondarySystemBackground

    /// `text` in the code font with syntax colors and, optionally, a
    /// background over `emphasis` (UTF-16 offsets).
    func highlighted(_ text: String, tokens: [SyntaxToken], emphasis: Range<Int>? = nil, emphasisColor: UIColor? = nil,
                     font: UIFont? = nil) -> NSAttributedString {
        let font = font ?? code
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label])
        let length = result.length
        for token in tokens where token.range.lowerBound < length {
            let range = NSRange(location: token.range.lowerBound, length: min(token.range.upperBound, length) - token.range.lowerBound)
            result.addAttribute(.foregroundColor, value: color(token.kind), range: range)
            if token.kind == .heading { result.addAttribute(.font, value: codeBold, range: range) }
        }
        if let emphasis, let emphasisColor, emphasis.lowerBound < length {
            let range = NSRange(location: emphasis.lowerBound, length: min(emphasis.upperBound, length) - emphasis.lowerBound)
            result.addAttribute(.backgroundColor, value: emphasisColor, range: range)
        }
        return result
    }
}
