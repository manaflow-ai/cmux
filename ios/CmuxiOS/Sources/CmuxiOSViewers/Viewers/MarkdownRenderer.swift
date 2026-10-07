import CmuxiOSViewersCore
import Foundation
import UIKit

/// Renders `MarkdownDocument` blocks into one attributed string for a
/// TextKit 2 text view: Dynamic Type fonts per block, inline emphasis,
/// code spans, links and strikethrough from Foundation's inline Markdown,
/// highlighted code blocks on a tinted background, quotes, nested lists
/// with task boxes, and tables as aligned monospaced rows.
@MainActor
struct MarkdownRenderer {
    let style: ViewerStyle
    let traits: UITraitCollection

    init(traits: UITraitCollection) {
        self.traits = traits
        style = ViewerStyle(traits: traits)
    }

    func render(_ document: MarkdownDocument) -> NSAttributedString {
        let out = NSMutableAttributedString()
        render(document.blocks, depth: 0, quoted: false, into: out)
        while out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    private func font(_ style: UIFont.TextStyle, bold: Bool = false) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        guard bold, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
        return UIFont(descriptor: descriptor, size: 0)
    }

    private func paragraph(indent: CGFloat, spacing: CGFloat, first: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = first ?? indent
        style.headIndent = indent
        style.paragraphSpacing = spacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private func render(_ blocks: [MarkdownBlock], depth: Int, quoted: Bool, into out: NSMutableAttributedString) {
        let indent = CGFloat(depth) * 18 + (quoted ? 14 : 0)
        let color: UIColor = quoted ? .secondaryLabel : .label
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                let textStyle: UIFont.TextStyle = [.title1, .title2, .title3, .headline, .subheadline, .footnote][min(level, 6) - 1]
                out.append(inline(text, font: font(textStyle, bold: true), color: color))
                out.append(newline(paragraph(indent: indent, spacing: 10)))
                out.addAttribute(.accessibilityTextHeadingLevel, value: level, range: lastParagraph(out))
                out.addAttribute(.paragraphStyle, value: paragraph(indent: indent, spacing: 10), range: lastParagraph(out))
            case .paragraph(let text):
                out.append(inline(text, font: font(.body), color: color))
                out.append(newline(nil))
                out.addAttribute(.paragraphStyle, value: paragraph(indent: indent, spacing: 10), range: lastParagraph(out))
            case .code(let language, let text):
                let detected = language.map { SyntaxLanguage.detect(fileName: "x." + $0) } ?? .plain
                let tokens = SyntaxHighlighter(language: detected).highlight(text)
                let code = NSMutableAttributedString(attributedString: style.highlighted(text, tokens: tokens))
                code.append(NSAttributedString(string: "\n", attributes: [.font: style.code]))
                let range = NSRange(location: 0, length: code.length)
                code.addAttribute(.backgroundColor, value: ViewerStyle.codeBlockBackground, range: range)
                code.addAttribute(.paragraphStyle, value: paragraph(indent: indent + 8, spacing: 0), range: range)
                out.append(code)
                out.append(newline(paragraph(indent: indent, spacing: 4)))
            case .quote(let inner):
                render(inner, depth: depth, quoted: true, into: out)
            case .list(let list):
                for (offset, item) in list.items.enumerated() {
                    renderItem(item, marker: marker(list, offset: offset, item: item), depth: depth, quoted: quoted, into: out)
                }
            case .table(let table):
                renderTable(table, indent: indent, into: out)
            case .thematicBreak:
                out.append(NSAttributedString(string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n", attributes: [
                    .font: font(.body), .foregroundColor: UIColor.separator,
                    .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; p.paragraphSpacing = 10; return p }(),
                ]))
            }
        }
    }

    private func marker(_ list: MarkdownList, offset: Int, item: MarkdownListItem) -> String {
        if let checked = item.isChecked { return checked ? "\u{2611}\u{FE0E}" : "\u{2610}\u{FE0E}" }
        return list.ordered ? "\(list.start + offset)." : "\u{2022}"
    }

    private func renderItem(_ item: MarkdownListItem, marker: String, depth: Int, quoted: Bool, into out: NSMutableAttributedString) {
        let indent = CGFloat(depth + 1) * 18 + (quoted ? 14 : 0)
        let color: UIColor = quoted ? .secondaryLabel : .label
        var rest = item.blocks[...]
        let line = NSMutableAttributedString(string: marker + "\t", attributes: [.font: font(.body), .foregroundColor: ViewerStyle.gutterText])
        if let checked = item.isChecked {
            line.addAttribute(.foregroundColor, value: checked ? UIColor.systemGreen : UIColor.secondaryLabel,
                              range: NSRange(location: 0, length: (marker as NSString).length))
        }
        if case .paragraph(let text)? = rest.first {
            let body = inline(text, font: font(.body), color: color)
            let mutable = NSMutableAttributedString(attributedString: body)
            if item.isChecked == true {
                mutable.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: NSRange(location: 0, length: mutable.length))
            }
            line.append(mutable)
            rest = rest.dropFirst()
        }
        let style = paragraph(indent: indent, spacing: 4, first: indent - 18)
        let tabbed = style.mutableCopy() as! NSMutableParagraphStyle
        tabbed.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        tabbed.defaultTabInterval = 18
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(.paragraphStyle, value: tabbed, range: NSRange(location: 0, length: line.length))
        out.append(line)
        render(Array(rest), depth: depth + 1, quoted: quoted, into: out)
    }

    private func renderTable(_ table: MarkdownTable, indent: CGFloat, into out: NSMutableAttributedString) {
        let rows = [table.header] + table.rows
        let widths = table.header.indices.map { column in rows.map { ($0[column] as NSString).length }.max() ?? 0 }
        func pad(_ cell: String, _ column: Int) -> String {
            let gap = widths[column] - (cell as NSString).length
            switch table.alignments[column] {
            case .leading: return cell + String(repeating: " ", count: gap)
            case .trailing: return String(repeating: " ", count: gap) + cell
            case .center: return String(repeating: " ", count: gap / 2) + cell + String(repeating: " ", count: gap - gap / 2)
            }
        }
        let block = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            let line = row.indices.map { pad(row[$0], $0) }.joined(separator: "  \u{2502}  ")
            block.append(NSAttributedString(string: line + "\n", attributes: [
                .font: index == 0 ? style.codeBold : style.code, .foregroundColor: UIColor.label,
            ]))
            if index == 0 {
                let rule = widths.map { String(repeating: "\u{2500}", count: $0) }.joined(separator: "\u{2500}\u{2500}\u{253C}\u{2500}\u{2500}")
                block.append(NSAttributedString(string: rule + "\n", attributes: [.font: style.code, .foregroundColor: UIColor.separator]))
            }
        }
        let range = NSRange(location: 0, length: block.length)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.lineBreakMode = .byClipping
        block.addAttribute(.paragraphStyle, value: style, range: range)
        out.append(block)
        out.append(newline(paragraph(indent: indent, spacing: 6)))
    }

    /// Inline Markdown (emphasis, strong, code, strikethrough, links) via
    /// Foundation, mapped onto UIKit fonts.
    private func inline(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if intent.contains(.code) {
                    runFont = UIFontMetrics(forTextStyle: .body).scaledFont(
                        for: .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular), compatibleWith: self.traits)
                    attributes[.backgroundColor] = ViewerStyle.codeBlockBackground
                }
                if !traits.isEmpty, let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits)) {
                    runFont = UIFont(descriptor: descriptor, size: 0)
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attributes[.link] = link
            }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }

    private func newline(_ style: NSParagraphStyle?) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(.body)]
        if let style { attributes[.paragraphStyle] = style }
        return NSAttributedString(string: "\n", attributes: attributes)
    }

    /// The range of the paragraph that ends at the string's end.
    private func lastParagraph(_ out: NSMutableAttributedString) -> NSRange {
        let string = out.string as NSString
        let end = out.length
        let searchEnd = max(0, end - 1)
        let found = string.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: searchEnd))
        let start = found.location == NSNotFound ? 0 : found.location + 1
        return NSRange(location: start, length: end - start)
    }
}
