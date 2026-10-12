import Foundation

/// A small CommonMark-ish Markdown → HTML renderer for file previews:
/// headings, paragraphs, fenced code, block quotes, lists (with task
/// boxes), rules, pipe tables, and inline code/bold/italic/strike/links.
/// Raw HTML in the source is escaped, never executed.
enum MarkdownHTML {
    static func page(markdown: String) -> String {
        document(body: render(markdown))
    }

    /// Wraps body HTML with the app-theme stylesheet (light and dark).
    static func document(body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <style>\(css)</style></head><body>\(body)</body></html>
        """
    }

    static let css = """
    :root { color-scheme: light dark; --ink:#1c1c1e; --muted:#6e6e73; --line:#d8d8dc; --code:#f2f2f4; --bg:#ffffff; }
    @media (prefers-color-scheme: dark) { :root { --ink:#ececee; --muted:#9a9aa0; --line:#2c2c30; --code:#161618; --bg:#000000; } }
    html { -webkit-text-size-adjust: 100%; }
    body { margin:0; padding:16px 18px 48px; background:var(--bg); color:var(--ink);
      font: -apple-system-body; font-family: -apple-system, system-ui; line-height:1.55; word-wrap:break-word; }
    h1,h2,h3,h4,h5,h6 { line-height:1.25; margin:1.4em 0 .5em; font-weight:650; }
    h1 { font-size:1.6em; } h2 { font-size:1.35em; } h3 { font-size:1.15em; } h4,h5,h6 { font-size:1em; }
    h1,h2 { padding-bottom:.25em; border-bottom:1px solid var(--line); }
    p, ul, ol, blockquote, pre, table { margin:0 0 1em; }
    a { color:var(--ink); text-decoration:underline; text-underline-offset:2px; }
    code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size:.86em; }
    code { background:var(--code); padding:.15em .35em; border-radius:6px; }
    pre { background:var(--code); padding:12px 14px; border-radius:12px; overflow-x:auto; line-height:1.45; }
    pre code { background:none; padding:0; }
    blockquote { margin-left:0; padding-left:14px; border-left:3px solid var(--line); color:var(--muted); }
    hr { border:0; border-top:1px solid var(--line); margin:1.6em 0; }
    ul, ol { padding-left:1.4em; } li { margin:.2em 0; } li.task { list-style:none; margin-left:-1.3em; }
    table { border-collapse:collapse; display:block; overflow-x:auto; }
    th, td { border:1px solid var(--line); padding:6px 10px; text-align:left; }
    th { font-weight:600; background:var(--code); }
    img { max-width:100%; border-radius:8px; }
    """

    static func render(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html = ""
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + paragraph.map(inline).joined(separator: "\n") + "</p>\n"
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                let attribute = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                html += "<pre><code\(attribute)>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }

            // ATX heading.
            if let level = headingLevel(trimmed) {
                flushParagraph()
                var text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                while text.hasSuffix("#") { text.removeLast() }
                html += "<h\(level)>\(inline(text.trimmingCharacters(in: .whitespaces)))</h\(level)>\n"
                i += 1
                continue
            }

            // Thematic break.
            if isRule(trimmed) {
                flushParagraph()
                html += "<hr>\n"
                i += 1
                continue
            }

            // Block quote.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var content = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoted.append(String(content))
                    i += 1
                }
                html += "<blockquote>" + render(quoted.joined(separator: "\n")) + "</blockquote>\n"
                continue
            }

            // Pipe table: header row followed by a separator row.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                html += "<table><thead><tr>" + cells(trimmed).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>\n"
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    html += "<tr>" + cells(lines[i]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
                    i += 1
                }
                html += "</tbody></table>\n"
                continue
            }

            // Lists.
            if let marker = listMarker(trimmed) {
                flushParagraph()
                let tag = marker.ordered ? "ol" : "ul"
                html += "<\(tag)>\n"
                while i < lines.count, let item = listMarker(lines[i].trimmingCharacters(in: .whitespaces)), item.ordered == marker.ordered {
                    var text = item.text
                    var checkbox = ""
                    if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                        let checked = !text.hasPrefix("[ ]")
                        checkbox = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                        text = String(text.dropFirst(4))
                    }
                    i += 1
                    // Lazy continuation lines (indented, not a new item).
                    while i < lines.count, lines[i].hasPrefix("  "), listMarker(lines[i].trimmingCharacters(in: .whitespaces)) == nil,
                          !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    }
                    html += "<li\(checkbox.isEmpty ? "" : " class=\"task\"")>\(checkbox)\(inline(text))</li>\n"
                }
                html += "</\(tag)>\n"
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return html
    }

    // MARK: - Blocks

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.hasPrefix(" ") ? hashes : nil
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func listMarker(_ line: String) -> (ordered: Bool, text: String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) && !isRule(line) {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (true, String(rest.dropFirst(2))) }
        }
        return nil
    }

    // MARK: - Inline

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Inline spans. Code spans are cut out first so their contents stay literal.
    static func inline(_ text: String) -> String {
        var codes: [String] = []
        var stripped = ""
        var remainder = Substring(text)
        while let open = remainder.firstIndex(of: "`") {
            let afterOpen = remainder.index(after: open)
            guard let close = remainder[afterOpen...].firstIndex(of: "`") else { break }
            stripped += remainder[..<open]
            stripped += "\u{1}\(codes.count)\u{2}"
            codes.append("<code>" + escape(String(remainder[afterOpen..<close])) + "</code>")
            remainder = remainder[remainder.index(after: close)...]
        }
        stripped += remainder

        var html = escape(stripped)
        html = replace(html, #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#) { "<img alt=\"\($0[1])\" src=\"\(safeURL($0[2]))\">" }
        html = replace(html, #"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#) { "<a href=\"\(safeURL($0[2]))\">\($0[1])</a>" }
        html = replace(html, #"&lt;(https?://[^\s&]+)&gt;"#) { "<a href=\"\($0[1])\">\($0[1])</a>" }
        html = replace(html, #"\*\*(.+?)\*\*|__(.+?)__"#) { "<strong>\($0[1].isEmpty ? $0[2] : $0[1])</strong>" }
        html = replace(html, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w)|(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w])"#) { "<em>\($0[1].isEmpty ? $0[2] : $0[1])</em>" }
        html = replace(html, #"~~(.+?)~~"#) { "<del>\($0[1])</del>" }
        for (index, code) in codes.enumerated() {
            html = html.replacingOccurrences(of: "\u{1}\(index)\u{2}", with: code)
        }
        return html
    }

    /// Blocks `javascript:` and other script-capable schemes.
    static func safeURL(_ url: String) -> String {
        let lower = url.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text/html") { return "#" }
        return url
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
