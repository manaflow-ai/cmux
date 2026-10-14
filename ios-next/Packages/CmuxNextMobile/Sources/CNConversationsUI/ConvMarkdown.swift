#if os(iOS)
import Foundation
import UIKit

/// Inline Markdown for conversation text: bubbles render `**bold**`,
/// `*italic*`, `` `code` ``, `~~strike~~` and links; previews show the text
/// with the markup removed. Block syntax (lists, headings, fences) stays as
/// typed, like Messages.
struct ConvMarkdown {
    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)

    static func parse(_ text: String) -> AttributedString? {
        // Cheap exit: nothing that inline Markdown would change.
        guard text.contains(where: { "*_`~[\\".contains($0) }) else { return nil }
        return try? AttributedString(markdown: text, options: options)
    }

    /// Text without inline markup, newlines folded to spaces (list previews).
    static func plain(_ text: String, foldNewlines: Bool = false) -> String {
        let s = parse(text).map { String($0.characters) } ?? text
        guard foldNewlines else { return s }
        return s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Styled text: `base` attributes everywhere, with bold/italic/code/strike/link runs.
    static func attributed(_ text: String, base: [NSAttributedString.Key: Any], font: UIFont) -> NSAttributedString {
        guard let md = parse(text) else { return NSAttributedString(string: text, attributes: base) }
        let out = NSMutableAttributedString()
        for run in md.runs {
            var attrs = base
            let piece = String(md[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            var f = font
            if intent.contains(.code) {
                f = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: traits.contains(.traitBold) ? .semibold : .regular)
            } else if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(traits) {
                f = UIFont(descriptor: d, size: font.pointSize)
            }
            attrs[.font] = f
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // Links are underlined in the bubble's own ink (no accent hue).
            if run.link != nil { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}
#endif
