import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for the opt-in wiki-style link support in the markdown
/// viewer shell (`Resources/markdown-viewer/shell.html`). The shell parses
/// `[[Target]]` / `[[Target|Label]]` into anchors only when
/// `window.__cmuxSetWikiLinks(true)` has been called, mirroring the
/// `markdown.wikiLinks` setting. These tests drive the real shell in a
/// WKWebView and assert on the rendered DOM.
@MainActor
@Suite
final class MarkdownWikiLinkRenderingTests {
    /// When disabled (the default), `[[Note]]` stays literal text and produces
    /// no anchor — a plain markdown document is untouched.
    @Test
    func wikiLinksRenderAsLiteralTextWhenDisabled() async throws {
        try await withLoadedMarkdownShell { webView in
            let snapshot = try await renderWikiSnapshot(
                "See [[Note]] and [[Other|Label]] here.",
                wikiLinksEnabled: false,
                in: webView
            )
            #expect(snapshot.anchorCount == 0)
            #expect(snapshot.proseText == "See [[Note]] and [[Other|Label]] here.")
        }
    }

    /// When enabled, `[[Note]]` becomes an anchor to the sibling `Note.md`
    /// file, `[[Note|Label]]` uses the label as visible text, subpaths and
    /// existing extensions are preserved, and a `#heading` fragment is slugged.
    @Test
    func wikiLinksRenderAsMarkdownFileAnchorsWhenEnabled() async throws {
        try await withLoadedMarkdownShell { webView in
            let snapshot = try await renderWikiSnapshot(
                """
                Bare: [[Note]]
                Aliased: [[Other|Display Text]]
                Subpath: [[folder/Deep Note]]
                Explicit: [[image.png]]
                Heading: [[Guide#Getting Started]]
                Same doc: [[#Section Two]]
                """,
                wikiLinksEnabled: true,
                in: webView
            )
            #expect(snapshot.anchorHrefs == [
                "Note.md",
                "Other.md",
                "folder/Deep Note.md",
                "image.png",
                "Guide.md#getting-started",
                "#section-two"
            ])
            #expect(snapshot.anchorTexts == [
                "Note",
                "Display Text",
                "folder/Deep Note",
                "image.png",
                "Guide#Getting Started",
                "#Section Two"
            ])
            // The bare-note anchor points at a real markdown path, so the
            // shell's file-link machinery tags it as an openable candidate.
            #expect(snapshot.markdownCandidateHrefs.contains("Note.md"))
        }
    }

    /// Toggling the flag re-renders the currently displayed document in place,
    /// so the setting takes effect live without a fresh markdown push.
    @Test
    func togglingWikiLinksReRendersCurrentDocument() async throws {
        try await withLoadedMarkdownShell { webView in
            let off = try await renderWikiSnapshot(
                "Link: [[Note]]",
                wikiLinksEnabled: false,
                in: webView
            )
            #expect(off.anchorCount == 0)

            let on = try await setWikiLinksSnapshot(true, in: webView)
            #expect(on.anchorHrefs == ["Note.md"])

            let offAgain = try await setWikiLinksSnapshot(false, in: webView)
            #expect(offAgain.anchorCount == 0)
            #expect(offAgain.proseText == "Link: [[Note]]")
        }
    }

    // MARK: - Harness

    private func renderWikiSnapshot(
        _ markdown: String,
        wikiLinksEnabled: Bool,
        in webView: WKWebView
    ) async throws -> WikiLinkSnapshot {
        _ = try await webView.evaluateJavaScript(
            "window.__cmuxSetWikiLinks(\(wikiLinksEnabled ? "true" : "false"));"
        )
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript(
            "window.__cmuxRenderMarkdown(\(literal)[0]);"
        )
        return try await captureSnapshot(in: webView)
    }

    private func setWikiLinksSnapshot(
        _ enabled: Bool,
        in webView: WKWebView
    ) async throws -> WikiLinkSnapshot {
        _ = try await webView.evaluateJavaScript(
            "window.__cmuxSetWikiLinks(\(enabled ? "true" : "false"));"
        )
        return try await captureSnapshot(in: webView)
    }

    private func captureSnapshot(in webView: WKWebView) async throws -> WikiLinkSnapshot {
        let result = try await webView.evaluateJavaScript(
            """
            (function() {
              var content = document.getElementById('content');
              var anchors = Array.prototype.slice.call(content.querySelectorAll('a[href]'));
              return {
                proseText: content.textContent,
                anchorHrefs: anchors.map(function(a) { return a.getAttribute('href'); }),
                anchorTexts: anchors.map(function(a) { return a.textContent; }),
                markdownCandidateHrefs: anchors
                  .filter(function(a) { return a.hasAttribute('data-cmux-file-candidate'); })
                  .map(function(a) { return a.getAttribute('href'); })
              };
            })();
            """
        )
        let raw = try #require(result as? [String: Any])
        // The block element's textContent carries a trailing newline from HTML
        // serialization; trim so literal-text assertions compare the prose only.
        let proseText = try #require(raw["proseText"] as? String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WikiLinkSnapshot(
            proseText: proseText,
            anchorHrefs: try #require(raw["anchorHrefs"] as? [String]),
            anchorTexts: try #require(raw["anchorTexts"] as? [String]),
            markdownCandidateHrefs: try #require(raw["markdownCandidateHrefs"] as? [String])
        )
    }

    private func withLoadedMarkdownShell<T>(
        _ body: (WKWebView) async throws -> T
    ) async throws -> T {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-wikilink-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loadDelegate = MarkdownWikiLinkShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            in: webView,
            baseURL: markdownURL
        )
        return try await body(webView)
    }
}

private struct WikiLinkSnapshot {
    let proseText: String
    let anchorHrefs: [String]
    let anchorTexts: [String]
    let markdownCandidateHrefs: [String]

    var anchorCount: Int { anchorHrefs.count }
}

private final class MarkdownWikiLinkShellLoadDelegate: NSObject, WKNavigationDelegate {
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
        continuation.resume(with: result)
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
