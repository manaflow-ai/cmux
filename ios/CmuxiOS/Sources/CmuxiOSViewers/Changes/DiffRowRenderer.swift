import CmuxiOSViewersCore
import UIKit

/// Builds and caches the attributed text of diff rows, one line at a time
/// as cells appear (a 50k-line diff highlights only what is on screen).
/// Lines are highlighted independently: a diff shows fragments, so block
/// state from outside the hunk is unknown anyway.
@MainActor
final class DiffRowRenderer {
    private let highlighter: SyntaxHighlighter
    private var style: ViewerStyle
    private var cache: [DiffLine: NSAttributedString] = [:]

    init(language: SyntaxLanguage, traits: UITraitCollection) {
        highlighter = SyntaxHighlighter(language: language)
        style = ViewerStyle(traits: traits)
    }

    var codeFont: UIFont { style.code }
    var gutterFont: UIFont { style.gutter }

    func traitsChanged(_ traits: UITraitCollection) {
        style = ViewerStyle(traits: traits)
        cache.removeAll()
    }

    func text(_ line: DiffLine) -> NSAttributedString {
        if let cached = cache[line] { return cached }
        let rendered: NSAttributedString
        if line.kind == .noNewlineMarker {
            rendered = NSAttributedString(string: ViewersText.noNewline, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: UIColor.secondaryLabel,
            ])
        } else {
            let (tokens, _) = highlighter.highlight(line: line.text)
            let emphasis: UIColor? = switch line.kind {
            case .addition: ViewerStyle.additionEmphasis
            case .removal: ViewerStyle.removalEmphasis
            default: nil
            }
            rendered = style.highlighted(line.text, tokens: tokens, emphasis: line.emphasis, emphasisColor: emphasis)
        }
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[line] = rendered
        return rendered
    }

    static func background(_ line: DiffLine?) -> UIColor {
        switch line?.kind {
        case .addition?: ViewerStyle.additionBackground
        case .removal?: ViewerStyle.removalBackground
        case nil: .secondarySystemBackground
        default: .clear
        }
    }

    static func accessibility(_ line: DiffLine?) -> String {
        guard let line else { return ViewersText.emptySide }
        switch line.kind {
        case .addition: return ViewersText.addedLine(line.newNumber ?? 0, line.text)
        case .removal: return ViewersText.removedLine(line.oldNumber ?? 0, line.text)
        case .context: return ViewersText.contextLine(line.newNumber ?? 0, line.text)
        case .noNewlineMarker: return ViewersText.noNewline
        }
    }
}
