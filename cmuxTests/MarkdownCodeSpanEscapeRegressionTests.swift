import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The markdown viewer used to escape inline code spans twice: marked's
/// codespan tokenizer already HTML-escapes the span text, and the shell's
/// custom `codespan` renderer escaped that escaped text again. A file
/// containing `` `<encoded>` `` rendered as a literal `&lt;encoded&gt;`.
///
/// These cases assert on the rendered DOM, so they fail for any renderer that
/// escapes a code span zero times (raw HTML leaks) or twice (entities on
/// screen).
@MainActor
@Suite
final class MarkdownCodeSpanEscapeRegressionTests {
    @Test(arguments: MarkdownCodeSpanEscapeCase.all)
    func renderedCodeIsEscapedExactlyOnce(_ escapeCase: MarkdownCodeSpanEscapeCase) async throws {
        try await withLoadedMarkdownShell { webView in
            let snapshot = try await renderCodeSnapshot(
                escapeCase.markdown,
                selector: escapeCase.selector,
                in: webView
            )

            #expect(snapshot.text == escapeCase.expectedText)
            if let expectedInnerHTML = escapeCase.expectedInnerHTML {
                #expect(snapshot.innerHTML == expectedInnerHTML)
            }
        }
    }

    /// A code span holding a path is also the viewer's markdown-file link
    /// candidate, and the candidate is read back off `textContent`. Escaped
    /// entities in that text would silently break link detection too.
    @Test
    func codeSpanFileLinkCandidateSeesUnescapedText() async throws {
        try await withLoadedMarkdownShell { webView in
            let snapshot = try await renderCodeSnapshot(
                "Open `docs/<name>/notes.md` next.",
                selector: "code[data-cmux-file]",
                in: webView
            )

            #expect(snapshot.text == "docs/<name>/notes.md")
        }
    }

    private func withLoadedMarkdownShell<T>(
        _ body: (WKWebView) async throws -> T
    ) async throws -> T {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-code-span-\(UUID().uuidString).md")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { webView.navigationDelegate = nil }

        let loadDelegate = MarkdownCodeSpanShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            in: webView,
            baseURL: markdownURL
        )
        return try await body(webView)
    }

    private func renderCodeSnapshot(
        _ markdown: String,
        selector: String,
        in webView: WKWebView
    ) async throws -> CodeSpanSnapshot {
        let data = try JSONSerialization.data(withJSONObject: [markdown, selector])
        let literal = try #require(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            """
            (function(args) {
              window.__cmuxRenderMarkdown(args[0]);
              var el = document.querySelector(args[1]);
              if (!el) { return { found: false }; }
              return { found: true, text: el.textContent, innerHTML: el.innerHTML };
            })(\(literal));
            """
        )
        let raw = try #require(result as? [String: Any])
        #expect((raw["found"] as? Bool) == true, "no element matched \(selector)")
        return CodeSpanSnapshot(
            text: raw["text"] as? String,
            innerHTML: raw["innerHTML"] as? String
        )
    }
}

struct MarkdownCodeSpanEscapeCase: Sendable, CustomTestStringConvertible {
    let name: String
    let markdown: String
    let selector: String
    let expectedText: String
    /// `nil` where highlight.js wraps the text in spans, so only the visible
    /// text is stable enough to assert on.
    let expectedInnerHTML: String?

    var testDescription: String { name }

    static let all: [MarkdownCodeSpanEscapeCase] = [
        MarkdownCodeSpanEscapeCase(
            name: "code span with angle brackets",
            markdown: "The sessions persist under `~/.claude/projects/<encoded>/` on disk.",
            selector: "code",
            expectedText: "~/.claude/projects/<encoded>/",
            expectedInnerHTML: "~/.claude/projects/&lt;encoded&gt;/"
        ),
        MarkdownCodeSpanEscapeCase(
            name: "code span with an ampersand",
            markdown: "Run `foo & bar` now.",
            selector: "code",
            expectedText: "foo & bar",
            expectedInnerHTML: "foo &amp; bar"
        ),
        MarkdownCodeSpanEscapeCase(
            name: "code span with literal entity text",
            markdown: "Type `&amp;` here.",
            selector: "code",
            expectedText: "&amp;",
            expectedInnerHTML: "&amp;amp;"
        ),
        MarkdownCodeSpanEscapeCase(
            name: "code span with quotes",
            markdown: "Use `--flag=\"a 'b'\"` today.",
            selector: "code",
            expectedText: "--flag=\"a 'b'\"",
            expectedInnerHTML: "--flag=\"a 'b'\""
        ),
        MarkdownCodeSpanEscapeCase(
            name: "code span inside a link label",
            markdown: "See [the `<encoded>` doc](docs/x.md).",
            selector: "a code",
            expectedText: "<encoded>",
            expectedInnerHTML: "&lt;encoded&gt;"
        ),
        MarkdownCodeSpanEscapeCase(
            name: "code span inside a heading",
            markdown: "# Path `<encoded>` layout",
            selector: "h1 code",
            expectedText: "<encoded>",
            expectedInnerHTML: "&lt;encoded&gt;"
        ),
        MarkdownCodeSpanEscapeCase(
            name: "code span inside a table cell",
            markdown: "| a | b |\n| - | - |\n| `<x>` | y |",
            selector: "td code",
            expectedText: "<x>",
            expectedInnerHTML: "&lt;x&gt;"
        ),
        MarkdownCodeSpanEscapeCase(
            name: "fenced block without a language",
            markdown: "```\n<tag> & 'quote'\n```",
            selector: "pre code",
            expectedText: "<tag> & 'quote'",
            expectedInnerHTML: nil
        ),
        MarkdownCodeSpanEscapeCase(
            name: "fenced block with a language",
            markdown: "```swift\nlet x: Array<Int> = []  // a & b\n```",
            selector: "pre code",
            expectedText: "let x: Array<Int> = []  // a & b",
            expectedInnerHTML: nil
        )
    ]
}

private struct CodeSpanSnapshot {
    let text: String?
    let innerHTML: String?
}

private final class MarkdownCodeSpanShellLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
