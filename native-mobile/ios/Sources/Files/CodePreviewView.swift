import SwiftUI

/// Highlighted lines of a text file, built off the main actor.
struct CodeDocument: Sendable {
    var lines: [AttributedString]
    var maxColumns: Int

    /// Above this many lines highlighting is skipped (plain ink text).
    static let highlightLimit = 20_000

    /// A minified bundle can be one multi-megabyte line: one row that wide
    /// stalls layout and highlighting, so rows are cut here.
    static let maximumLineCharacters = 4000
    /// Lines longer than this are shown without highlighting.
    static let highlightLineLimit = 1000

    static func make(text: String, path: String, language: SyntaxHighlighter.Language? = nil) -> CodeDocument {
        let language = language ?? SyntaxHighlighter.language(forPath: path)
        let raw = UnifiedDiffParser.splitLines(text)
        let highlight = raw.count <= highlightLimit
        var maxColumns = 1
        // Block comments and multi-line strings carry across lines.
        var carry = SyntaxHighlighter.Carry.none
        let lines = raw.map { full -> AttributedString in
            let line = clipped(full)
            maxColumns = max(maxColumns, line.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) })
            if highlight, line.count <= highlightLineLimit { return SyntaxHighlighter.attributed(line, language: language, carry: &carry) }
            var plain = AttributedString(line)
            plain.foregroundColor = Theme.ink
            return plain
        }
        return CodeDocument(lines: lines.isEmpty ? [AttributedString()] : lines, maxColumns: maxColumns)
    }

    static func clipped(_ line: String) -> String {
        guard line.count > maximumLineCharacters else { return line }
        let rest = line.count - maximumLineCharacters
        return String(line.prefix(maximumLineCharacters)) + " … " + String(localized: "\(rest) more characters")
    }
}

/// Monospaced code with a line-number gutter, horizontal scrolling, and an
/// optional wrap mode. Rows are lazy; nothing heavy runs in `body`.
struct CodePreviewView: View {
    let document: CodeDocument
    let wrap: Bool
    @State private var viewportWidth: CGFloat = 390

    private var gutterWidth: CGFloat {
        CGFloat(max(String(document.lines.count).count, 2)) * DiffMetrics.numberCharWidth + 18
    }

    private var contentWidth: CGFloat {
        guard !wrap else { return viewportWidth }
        return max(viewportWidth, gutterWidth + DiffMetrics.textWidth(columns: document.maxColumns) + 8)
    }

    var body: some View {
        ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.lines.indices, id: \.self) { index in
                    CodeLineRow(number: index + 1, text: document.lines[index], gutterWidth: gutterWidth, wrap: wrap)
                }
            }
            .padding(.vertical, 8)
            .frame(width: contentWidth, alignment: .leading)
        }
        .scrollIndicators(.hidden, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .background(Theme.background)
    }
}

struct CodeLineRow: View {
    let number: Int
    let text: AttributedString
    let gutterWidth: CGFloat
    let wrap: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: String(number))
                .font(.system(size: DiffMetrics.numberFontSize, design: .monospaced))
                .foregroundStyle(Theme.tertiaryInk)
                .frame(width: gutterWidth - 10, alignment: .trailing)
                .padding(.trailing, 10)
                .accessibilityHidden(true)
            DiffLineText(text: text, wrap: wrap)
        }
        .padding(.vertical, 1)
    }
}
