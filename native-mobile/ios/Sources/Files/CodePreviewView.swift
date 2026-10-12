import SwiftUI

/// Highlighted lines of a text file, built off the main actor.
struct CodeDocument: Sendable {
    var lines: [AttributedString]
    var maxColumns: Int

    /// Above this many lines highlighting is skipped (plain ink text).
    static let highlightLimit = 20_000

    static func make(text: String, path: String, language: SyntaxHighlighter.Language? = nil) -> CodeDocument {
        let language = language ?? SyntaxHighlighter.language(forPath: path)
        let raw = UnifiedDiffParser.splitLines(text)
        let highlight = raw.count <= highlightLimit
        var maxColumns = 1
        let lines = raw.map { line -> AttributedString in
            maxColumns = max(maxColumns, line.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) })
            if highlight { return SyntaxHighlighter.attributed(line, language: language) }
            var plain = AttributedString(line)
            plain.foregroundColor = Theme.ink
            return plain
        }
        return CodeDocument(lines: lines.isEmpty ? [AttributedString()] : lines, maxColumns: maxColumns)
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
