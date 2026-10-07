import Foundation

/// Block-level Markdown (the CommonMark and GitHub subset agents write):
/// ATX and setext headings, fenced and indented code, block quotes,
/// nested bullet and ordered lists with task items, pipe tables, thematic
/// breaks and paragraphs. Inline markup is left in the text.
public struct MarkdownParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map(Self.expandTabs)
        return parse(lines[...])
    }

    // MARK: Blocks

    private func parse(_ lines: ArraySlice<String>) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = lines.startIndex
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(Self.joinParagraph(paragraph)))
            paragraph.removeAll()
        }
        while i < lines.endIndex {
            let line = lines[i]
            let indent = Self.indent(line)
            let body = String(line.dropFirst(min(indent, 3)))
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            if indent >= 4, paragraph.isEmpty {
                var code: [String] = []
                while i < lines.endIndex, Self.indent(lines[i]) >= 4 || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[i].dropFirst(min(4, lines[i].count))))
                    i += 1
                }
                while code.last?.isEmpty == true { code.removeLast() }
                blocks.append(.code(language: nil, text: code.joined(separator: "\n")))
                continue
            }
            if let fence = Self.fence(body) {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.endIndex {
                    let candidate = String(lines[i].dropFirst(min(Self.indent(lines[i]), 3)))
                    if let close = Self.fence(candidate), close.marker == fence.marker, close.length >= fence.length, close.info == nil {
                        i += 1
                        break
                    }
                    code.append(String(lines[i].dropFirst(min(indent, Self.indent(lines[i])))))
                    i += 1
                }
                blocks.append(.code(language: fence.info, text: code.joined(separator: "\n")))
                continue
            }
            if let heading = Self.atxHeading(body) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }
            if !paragraph.isEmpty, let level = Self.setextLevel(body) {
                blocks.append(.heading(level: level, text: Self.joinParagraph(paragraph)))
                paragraph.removeAll()
                i += 1
                continue
            }
            if Self.isThematicBreak(body) {
                flushParagraph()
                blocks.append(.thematicBreak)
                i += 1
                continue
            }
            if body.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.endIndex {
                    let candidate = String(lines[i].dropFirst(min(Self.indent(lines[i]), 3)))
                    guard candidate.hasPrefix(">") else { break }
                    var rest = candidate.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    i += 1
                }
                blocks.append(.quote(parse(quoted[...])))
                continue
            }
            if Self.listMarker(line) != nil {
                flushParagraph()
                let (list, next) = parseList(lines, from: i)
                blocks.append(.list(list))
                i = next
                continue
            }
            if paragraph.isEmpty, i + 1 < lines.endIndex, body.contains("|"), let alignments = Self.tableDelimiter(lines[i + 1]) {
                let header = Self.cells(body)
                if header.count == alignments.count {
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.endIndex, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        var row = Self.cells(lines[i])
                        row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
                        rows.append(row)
                        i += 1
                    }
                    blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
                    continue
                }
            }
            paragraph.append(body)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// Items of one list: same kind of marker; an item owns the following
    /// lines indented to its content column, blank lines included when the
    /// list goes on after them.
    private func parseList(_ lines: ArraySlice<String>, from start: Int) -> (MarkdownList, Int) {
        guard let first = Self.listMarker(lines[start]) else { return (MarkdownList(ordered: false, items: []), start + 1) }
        var items: [MarkdownListItem] = []
        var i = start
        while i < lines.endIndex, let marker = Self.listMarker(lines[i]), marker.ordered == first.ordered,
              marker.indent < first.content {
            var itemLines = [String(lines[i].dropFirst(marker.content))]
            i += 1
            while i < lines.endIndex {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Keep the blank only if the item continues below it.
                    let next = i + 1
                    guard next < lines.endIndex, Self.indent(lines[next]) >= marker.content else { break }
                    itemLines.append("")
                    i += 1
                    continue
                }
                if Self.indent(line) >= marker.content {
                    itemLines.append(String(line.dropFirst(marker.content)))
                } else if Self.listMarker(line) == nil, !Self.startsBlock(line), !(itemLines.last?.isEmpty ?? true) {
                    // A lazy continuation of the item's paragraph.
                    itemLines.append(line.trimmingCharacters(in: .whitespaces))
                } else {
                    break
                }
                i += 1
            }
            var isChecked: Bool?
            if let head = itemLines.first, let task = Self.task(head) {
                isChecked = task.checked
                itemLines[0] = task.rest
            }
            items.append(MarkdownListItem(isChecked: isChecked, blocks: parse(itemLines[...])))
            // A blank line between items is fine; the next marker continues the list.
            while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                  i + 1 < lines.endIndex, Self.listMarker(lines[i + 1]).map({ $0.ordered == first.ordered && $0.indent < first.content }) == true {
                i += 1
            }
        }
        return (MarkdownList(ordered: first.ordered, start: first.number, items: items), i)
    }

    // MARK: Line classifiers

    struct ListMarker {
        var ordered: Bool
        var number: Int
        /// Columns before the marker.
        var indent: Int
        /// Column where the item's content starts.
        var content: Int
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = indent(line)
        let chars = Array(line.dropFirst(indent))
        guard let first = chars.first else { return nil }
        if "-*+".contains(first) {
            guard chars.count == 1 || chars[1] == " " else { return nil }
            if isThematicBreak(String(chars)) { return nil }
            let spaces = min(4, chars.dropFirst().prefix { $0 == " " }.count)
            return ListMarker(ordered: false, number: 1, indent: indent, content: indent + 1 + max(1, spaces))
        }
        let digits = chars.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, chars.count > digits.count, ".)".contains(chars[digits.count]) else { return nil }
        let after = chars.dropFirst(digits.count + 1)
        guard after.isEmpty || after.first == " " else { return nil }
        let spaces = min(4, after.prefix { $0 == " " }.count)
        return ListMarker(ordered: true, number: Int(String(digits)) ?? 1, indent: indent,
                          content: indent + digits.count + 1 + max(1, spaces))
    }

    static func task(_ text: String) -> (checked: Bool, rest: String)? {
        let chars = Array(text)
        guard chars.count >= 3, chars[0] == "[", chars[2] == "]", chars.count == 3 || chars[3] == " " else { return nil }
        switch chars[1] {
        case " ": return (false, String(chars.dropFirst(4)))
        case "x", "X": return (true, String(chars.dropFirst(4)))
        default: return nil
        }
    }

    struct Fence {
        var marker: Character
        var length: Int
        var info: String?
    }

    static func fence(_ body: String) -> Fence? {
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let length = body.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = body.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        let word = info.split(separator: " ").first.map(String.init)
        return Fence(marker: marker, length: length, info: word)
    }

    static func atxHeading(_ body: String) -> MarkdownBlock? {
        let level = body.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = body.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of # preceded by a space is not content.
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) {
            text.removeSubrange(range)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return .heading(level: level, text: text)
    }

    static func setextLevel(_ body: String) -> Int? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "=" || first == "-", trimmed.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    static func isThematicBreak(_ body: String) -> Bool {
        let compact = body.filter { $0 != " " }
        guard let first = compact.first, "*-_".contains(first), compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func startsBlock(_ line: String) -> Bool {
        let body = String(line.dropFirst(min(indent(line), 3)))
        return fence(body) != nil || atxHeading(body) != nil || body.hasPrefix(">") || isThematicBreak(body)
    }

    static func tableDelimiter(_ line: String) -> [MarkdownTable.Alignment]? {
        let cells = cells(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in cells {
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(leading && trailing ? .center : (trailing ? .trailing : .leading))
        }
        return alignments
    }

    /// Cells of a pipe row, outer pipes optional, `\|` kept as a pipe.
    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for char in trimmed {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
                current.append(char)
            } else if char == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current)
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// Leading tabs become 4-column stops; tabs inside the line stay.
    static func expandTabs(_ line: String) -> String {
        guard line.first == "\t" || line.hasPrefix(" ") && line.contains("\t") else { return line }
        var column = 0
        var out = ""
        var leading = true
        for char in line {
            if leading, char == "\t" {
                let spaces = 4 - column % 4
                out += String(repeating: " ", count: spaces)
                column += spaces
            } else if leading, char == " " {
                out.append(char)
                column += 1
            } else {
                leading = false
                out.append(char)
            }
        }
        return out
    }

    /// Soft breaks join with a space; two trailing spaces or a backslash
    /// keep a line break.
    static func joinParagraph(_ lines: [String]) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            if line.hasSuffix("  "), !isLast {
                out += line.trimmingCharacters(in: .whitespaces) + "\n"
            } else if line.hasSuffix("\\"), !isLast {
                out += String(line.dropLast()).trimmingCharacters(in: .whitespaces) + "\n"
            } else {
                out += line.trimmingCharacters(in: .whitespaces) + (isLast ? "" : " ")
            }
        }
        return out
    }
}
