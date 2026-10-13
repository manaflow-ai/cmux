import SwiftUI
import WebKit

/// Renders agent markdown in a WKWebView (agents write markdown with code,
/// tables and lists; a web view renders all of it faithfully). The view
/// reports its content height so it sizes like text in a feed cell, and
/// clamps to `maxHeight` with a fade when collapsed.
struct MarkdownWebView: UIViewRepresentable {
    let markdown: String
    var maxHeight: CGFloat?
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $contentHeight, cacheKey: markdown) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "height")
        configuration.dataDetectorTypes = [.link]
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        // A cell scrolled back into view (LazyVStack rebuilds it) already
        // knows its height: show the page as soon as it paints. A first
        // load stays clear until its height is known, so the post never
        // flashes at the estimate and then jumps.
        webView.alpha = MarkdownHeightCache.height(for: markdown) == nil ? 0 : 1
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loaded != markdown else { return }
        context.coordinator.loaded = markdown
        context.coordinator.cacheKey = markdown
        webView.loadHTMLString(MarkdownHTML.page(body: MarkdownHTML.render(markdown)), baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var loaded: String?
        var cacheKey: String
        init(height: Binding<CGFloat>, cacheKey: String) {
            self.height = height
            self.cacheKey = cacheKey
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double, value > 0 else { return }
            let measured = CGFloat(value).rounded(.up)
            MarkdownHeightCache.store(measured, for: cacheKey)
            if let webView = message.webView, webView.alpha < 1 {
                UIView.animate(withDuration: 0.12) { webView.alpha = 1 }
            }
            guard abs(measured - height.wrappedValue) > 0.5 else { return }
            // Without an animation transaction: a height change from
            // measuring must not animate the whole timeline.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { height.wrappedValue = measured }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// Measured markdown heights, so a post rebuilt by the lazy timeline (or
/// re-rendered after an update) starts at its real height instead of
/// growing from an estimate.
@MainActor
enum MarkdownHeightCache {
    private static var heights: [String: CGFloat] = [:]
    private static var order: [String] = []
    private static let limit = 400

    static func height(for markdown: String) -> CGFloat? { heights[markdown] }

    static func store(_ height: CGFloat, for markdown: String) {
        if heights.updateValue(height, forKey: markdown) == nil {
            order.append(markdown)
            if order.count > limit { heights[order.removeFirst()] = nil }
        }
    }

    /// A first guess before the page is measured: about 40 characters a
    /// line at the body size, plus the explicit line breaks.
    nonisolated static func estimate(for markdown: String) -> CGFloat {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / 40).rounded(.up))) }
        return CGFloat(lines) * 23
    }
}

/// A small, dependency-free markdown → HTML renderer for agent output:
/// headings, paragraphs, lists, block quotes, fenced code, tables, inline
/// code, bold, italics, links and rules. Everything is HTML-escaped first.
enum MarkdownHTML {
    static func page(body: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
        :root { color-scheme: light dark; --fg:#1d1d1f; --muted:#6e6e73; --code:#f2f2f4; --border:rgba(0,0,0,.1); }
        @media (prefers-color-scheme: dark) { :root { --fg:#ececee; --muted:#9a9aa0; --code:#1b1c1e; --border:rgba(255,255,255,.1); } }
        html,body { margin:0; padding:0; background:transparent; color:var(--fg);
          font:-apple-system-body; line-height:1.42;
          -webkit-text-size-adjust:none; word-wrap:break-word; }
        #c { display:flow-root } #c > :first-child { margin-top:0 } #c > :last-child { margin-bottom:0 }
        p { margin:0 0 .6em } p:last-child { margin-bottom:0 }
        h1,h2,h3,h4 { font-weight:600; margin:.7em 0 .35em; line-height:1.25 } h1{font-size:1.25em} h2{font-size:1.15em} h3,h4{font-size:1.05em}
        ul,ol { margin:.2em 0 .6em; padding-left:1.3em } li { margin:.15em 0 }
        a { color:inherit; text-decoration:underline; text-decoration-color:var(--muted) }
        code { font-family:ui-monospace,Menlo,monospace; font-size:.82em; background:var(--code); padding:.1em .35em; border-radius:6px }
        pre { background:var(--code); border:1px solid var(--border); border-radius:12px; padding:10px 12px; overflow-x:auto; margin:.5em 0 }
        pre code { background:none; padding:0; font-size:.78em; line-height:1.45 }
        blockquote { margin:.4em 0; padding-left:.8em; border-left:3px solid var(--border); color:var(--muted) }
        table { border-collapse:collapse; display:block; overflow-x:auto; margin:.5em 0; font-size:.88em }
        th,td { border-bottom:1px solid var(--border); padding:6px 10px; text-align:left; white-space:nowrap }
        hr { border:0; border-top:1px solid var(--border); margin:.8em 0 }
        .add { color:#3fb950 } .del { color:#f85149 }
        </style></head><body><div id="c">\(body)</div>
        <script>
        const post=()=>webkit.messageHandlers.height.postMessage(document.getElementById('c').getBoundingClientRect().height);
        new ResizeObserver(post).observe(document.getElementById('c')); window.addEventListener('load',post); post();
        </script></body></html>
        """
    }

    static func render(_ markdown: String) -> String {
        var html: [String] = []
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>"); paragraph = [] }
        }
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(next); lines = lines.dropFirst()
                }
                lines = lines.dropFirst()
                let isDiff = lang == "diff" || lang == "patch"
                let body = code.map { row -> String in
                    let escaped = escape(row)
                    guard isDiff else { return escaped }
                    if row.hasPrefix("+") && !row.hasPrefix("+++") { return "<span class=add>\(escaped)</span>" }
                    if row.hasPrefix("-") && !row.hasPrefix("---") { return "<span class=del>\(escaped)</span>" }
                    return escaped
                }.joined(separator: "\n")
                html.append("<pre><code>\(body)</code></pre>")
            } else if trimmed.isEmpty {
                flush()
            } else if let level = heading(trimmed) {
                flush()
                html.append("<h\(level)>\(inline(String(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))))</h\(level)>")
            } else if trimmed == "---" || trimmed == "***" {
                flush(); html.append("<hr>")
            } else if trimmed.hasPrefix(">") {
                flush(); html.append("<blockquote>\(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>")
            } else if trimmed.hasPrefix("|"), let next = lines.first, next.contains("---") {
                flush()
                lines = lines.dropFirst()
                var rows = [trimmed]
                while let row = lines.first, row.trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(row); lines = lines.dropFirst() }
                html.append(table(rows))
            } else if let item = listItem(trimmed) {
                flush()
                var items = [item]
                while let next = lines.first, let more = listItem(next.trimmingCharacters(in: .whitespaces)), more.ordered == item.ordered {
                    items.append(more); lines = lines.dropFirst()
                }
                let tag = item.ordered ? "ol" : "ul"
                html.append("<\(tag)>" + items.map { "<li>\(inline($0.text))</li>" }.joined() + "</\(tag)>")
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return html.joined(separator: "\n")
    }

    private static func heading(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        return (1...4).contains(hashes) && line.dropFirst(hashes).first == " " ? hashes : nil
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { return (false, String(line.dropFirst(2))) }
        if let match = line.range(of: #"^\d{1,3}[.)]\s"#, options: .regularExpression) { return (true, String(line[match.upperBound...])) }
        return nil
    }

    private static func table(_ rows: [String]) -> String {
        func cells(_ row: String) -> [String] {
            row.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var out = "<table><thead><tr>" + cells(rows[0]).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
        for row in rows.dropFirst() { out += "<tr>" + cells(row).map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
        return out + "</tbody></table>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Inline spans, applied to escaped text.
    static func inline(_ text: String) -> String {
        var html = escape(text)
        var codes: [String] = []
        // Protect inline code from the other rules.
        html = replace(html, #"`([^`]+)`"#) { groups in
            codes.append("<code>\(groups[1])</code>")
            return "\u{1}\(codes.count - 1)\u{2}"
        }
        html = replace(html, #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        html = replace(html, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#) { "<em>\($0[1])</em>" }
        html = replace(html, #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#) { "<a href=\"\($0[2])\">\($0[1])</a>" }
        // Not a raw string: the sentinels are real U+0001/U+0002 characters
        // (a raw `\u{1}` reached ICU as text, so every inline code span
        // showed as "\u{1}0\u{2}" boxes).
        html = replace(html, "\u{1}(\\d+)\u{2}") { codes[Int($0[1]) ?? 0] }
        return html
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            let groups = (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            result += transform(groups)
            last = range.upperBound
        }
        return result + text[last...]
    }
}
