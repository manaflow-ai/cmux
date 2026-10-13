#if os(iOS)
import CnxDesign
import SwiftUI
import UIKit

/// Native markdown for transcripts (SPEC 2.2, 4.6, 4.7, 6.3). Display math and
/// paragraphs with inline math go through the pooled web renderer, the only
/// complete TeX layout available on iOS.
public struct MarkdownView: View {
    let document: MarkdownDocument
    /// Horizontal margin of the column; tables bleed past it to the screen edge.
    var margin: CGFloat
    var isStreaming: Bool

    public init(_ document: MarkdownDocument, margin: CGFloat = 20, isStreaming: Bool = false) {
        self.document = document
        self.margin = margin
        self.isStreaming = isStreaming
    }

    public init(markdown: String, margin: CGFloat = 20) {
        self.init(MarkdownDocument(parsing: markdown), margin: margin)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
                MarkdownBlockView(block: block, margin: margin)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let margin: CGFloat

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            InlineText(source: text, font: headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            if MarkdownInlineMath.contains(text) {
                WebMarkdownView(markdown: text, style: .body)
            } else {
                InlineText(source: text)
                    .textSelection(.enabled)
            }
        case .list(let list):
            MarkdownListView(list: list)
        case .code(let language, let code, _):
            CodeCard(language: language, code: code)
        case .table(let table):
            MarkdownTableView(table: table, margin: margin)
        case .quote(let text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(uiColor: .separator)).frame(width: 3)
                InlineText(source: text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .math(let tex):
            WebMarkdownView(markdown: "$$\n\(tex)\n$$", style: .body)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.bold()
        case 2: .headline
        default: .subheadline.bold()
        }
    }
}

struct MarkdownListView: View {
    let list: MarkdownList

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(item)
                        .frame(minWidth: 14, alignment: .trailing)
                    InlineText(source: item.text)
                }
                .padding(.leading, CGFloat(item.depth) * 20 + 4)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownList.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.subheadline)
                .foregroundStyle(checked ? Color.cnxSuccess : .secondary)
        } else if let ordinal = item.ordinal {
            Text("\(ordinal).").font(.body.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text(item.depth == 0 ? "•" : "◦").font(.body).foregroundStyle(.secondary)
        }
    }
}

/// SPEC 4.7: grid in a horizontal scroll view that bleeds to the screen edges.
struct MarkdownTableView: View {
    let table: MarkdownTable
    let margin: CGFloat

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(table.header[safe: column] ?? "", column: column, header: true)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cell(row[safe: column] ?? "", column: column, header: false)
                        }
                    }
                }
            }
            .padding(.horizontal, margin - 12)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -margin)
        .contextMenu {
            Button("Copy Table", systemImage: "doc.on.doc") { UIPasteboard.general.string = table.plainText }
        }
    }

    private func cell(_ text: String, column: Int, header: Bool) -> some View {
        InlineText(source: text, font: header ? .subheadline.weight(.semibold) : .subheadline)
            .frame(minWidth: 96 - 24, maxWidth: 260 - 24, alignment: alignment(column))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private func alignment(_ column: Int) -> Alignment {
        switch table.alignments[safe: column] ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
