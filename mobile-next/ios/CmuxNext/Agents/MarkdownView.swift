import SwiftUI

/// Block markdown for agent replies: paragraphs, headings, lists, quotes,
/// rules and fenced code with a copy button. Inline styling (bold, code,
/// links) uses Foundation's markdown parser.
struct MarkdownView: View {
    let text: String
    /// The reply is still arriving: its last paragraph fades new text in.
    var streaming = false

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if streaming, index == blocks.count - 1, case .paragraph(let paragraph) = block {
                    inline(paragraph).font(.system(size: 17)).lineSpacing(3)
                        .modifier(StreamingReveal(length: paragraph.count))
                } else {
                    view(for: block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).font(.system(size: 17)).lineSpacing(3)
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level == 1 ? 22 : level == 2 ? 20 : 17, weight: .semibold))
                .padding(.top, 4)
        case .bullets(let items, let ordered):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        inline(item).font(.system(size: 17)).lineSpacing(3)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(.separator)).frame(width: 3)
                inline(text).font(.system(size: 17)).foregroundStyle(.secondary)
            }
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func inline(_ raw: String) -> Text {
        // A reply that is still streaming may have an unclosed `code` or **bold**.
        var text = raw
        if text.filter({ $0 == "`" }).count % 2 == 1 { text += "`" }
        if text.components(separatedBy: "**").count % 2 == 0 { text += "**" }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if var attributed = try? AttributedString(markdown: text, options: options) {
            for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: 15, design: .monospaced)
                attributed[run.range].backgroundColor = Color(.tertiarySystemFill)
            }
            return Text(attributed)
        }
        return Text(text)
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case bullets([String], ordered: Bool)
    case quote(String)
    case code(String?, String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [String] = []
        var ordered = false
        var code: [String]?
        var language: String?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushList() {
            if !list.isEmpty { blocks.append(.bullets(list, ordered: ordered)) }
            list = []
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language, lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    flushList()
                    let name = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = name.isEmpty ? nil : name
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                flushList()
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).hasPrefix(" ") {
                    flushParagraph()
                    flushList()
                    blocks.append(.heading(level, String(line.dropFirst(level + 1))))
                    continue
                }
            }
            if line == "---" || line == "***" {
                flushParagraph()
                flushList()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                if !list.isEmpty, ordered { flushList() }
                ordered = false
                list.append(String(line.dropFirst(2)))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ")
            {
                flushParagraph()
                if !list.isEmpty, !ordered { flushList() }
                ordered = true
                list.append(String(line[line.index(dot, offsetBy: 2)...]))
                continue
            }
            if line.hasPrefix("> ") {
                flushParagraph()
                flushList()
                blocks.append(.quote(String(line.dropFirst(2))))
                continue
            }
            if !list.isEmpty, raw.hasPrefix("  ") {
                list[list.count - 1] += " " + line
                continue
            }
            flushList()
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(language, lines.joined(separator: "\n"))) }
        flushParagraph()
        flushList()
        return blocks
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation(.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(.snappy) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(CmuxTheme.chrome, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
    }
}
