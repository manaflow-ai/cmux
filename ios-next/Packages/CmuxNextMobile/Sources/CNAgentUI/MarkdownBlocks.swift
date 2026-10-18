import Foundation

/// Block-level markdown for agent replies: fenced code, headings, lists,
/// tables, quotes, rules and paragraphs. Inline syntax (bold, code, links)
/// is left to `AttributedString(markdown:)` per block. Tolerates a reply cut
/// mid-stream: an unclosed fence is a code block to the end.
enum MarkdownBlock: Hashable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, text: String, closed: Bool)
    case list(items: [ListItem])
    case table(header: [String], rows: [[String]])
    case quote(String)
    case rule

    struct ListItem: Hashable, Sendable {
        /// "•" or "3."
        var marker: String
        var depth: Int
        var text: String
        var checked: Bool?
    }
}

struct MarkdownParser: Sendable {
    func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                var closed = false
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { closed = true; index += 1; break }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n"), closed: closed))
                continue
            }

            if trimmed.isEmpty { flushParagraph(); index += 1; continue }

            if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix("|"), index + 1 < lines.count, Self.isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = Self.cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    var row = Self.cells(t)
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if Self.listItem(line) != nil {
                flushParagraph()
                var items: [MarkdownBlock.ListItem] = []
                while index < lines.count {
                    if let item = Self.listItem(lines[index]) {
                        items.append(item)
                        index += 1
                    } else if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[index].hasPrefix("  "), !items.isEmpty {
                        // A wrapped continuation line of the previous item.
                        items[items.count - 1].text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items: items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1)))
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var t = row
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func listItem(_ line: String) -> MarkdownBlock.ListItem? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        let depth = min(indent / 2, 4)
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            var text = String(rest.dropFirst(2))
            var checked: Bool?
            if text.hasPrefix("[ ] ") { checked = false; text.removeFirst(4) } else if text.lowercased().hasPrefix("[x] ") { checked = true; text.removeFirst(4) }
            return .init(marker: "•", depth: depth, text: text, checked: checked)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return .init(marker: "\(digits).", depth: depth, text: String(after.dropFirst(2)), checked: nil)
            }
        }
        return nil
    }
}

/// Markdown reduced to one line of plain text, for previews and accessibility
/// labels: code fences keep their code, headings, list and quote markers,
/// emphasis, inline code ticks and link targets go, whitespace collapses.
public struct MarkdownPlainText: Sendable {
    public init() {}

    public func callAsFunction(_ source: String) -> String {
        var parts: [String] = []
        for block in MarkdownParser().parse(source) {
            switch block {
            case .paragraph(let t), .quote(let t): parts.append(inline(t))
            case .heading(_, let t): parts.append(inline(t))
            case .code(_, let code, _): parts.append(code)
            case .list(let items): parts.append(contentsOf: items.map { inline($0.text) })
            case .table(let header, let rows):
                parts.append(([header] + rows).map { $0.map(inline).joined(separator: " ") }.joined(separator: " "))
            case .rule: break
            }
        }
        return parts.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func inline(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        let squeezed = Self.dropSqueezedFenceLanguage(text)
        guard let parsed = try? AttributedString(markdown: squeezed, options: options) else { return squeezed }
        return String(parsed.characters)
    }

    /// Fence info strings common in agent replies.
    static let fenceLanguages: Set<String> = [
        "text", "txt", "plaintext", "console", "shell", "sh", "bash", "zsh", "swift", "ts", "tsx", "typescript",
        "js", "jsx", "javascript", "json", "yaml", "yml", "toml", "xml", "html", "css", "sql", "diff", "patch",
        "python", "py", "go", "rust", "rs", "ruby", "rb", "java", "kotlin", "c", "cpp", "objc", "md", "markdown",
    ]

    /// A fence squeezed onto one line (a host preview with newlines folded,
    /// "```text v1c-out-42 ```") keeps its language word inside the code span.
    /// Drop it when it is a known language, so a command like `npm test` is
    /// never mistaken for one.
    static func dropSqueezedFenceLanguage(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "```") {
            out += rest[..<open.upperBound]
            rest = rest[open.upperBound...]
            let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }
            let after = rest.dropFirst(word.count)
            if !word.isEmpty, after.first?.isWhitespace == true, fenceLanguages.contains(word.lowercased()),
               after.contains("```") {
                rest = after.drop { $0.isWhitespace }
                // Copy the code span through its closing fence unchanged.
                if let close = rest.range(of: "```") {
                    out += rest[..<close.upperBound]
                    rest = rest[close.upperBound...]
                }
            } else if let close = rest.range(of: "```") {
                out += rest[..<close.upperBound]
                rest = rest[close.upperBound...]
            }
        }
        return out + rest
    }
}
