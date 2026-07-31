import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
final class MarkdownCodespanRenderingTests {
    @Test
    func inlineCodespansRenderDecodedTextWhileCodeBlocksStayEscaped() async throws {
        try await withLoadedMarkdownShell { webView in
            let snapshot = try await renderSnapshot(
                """
                Plain prose control: 2 < 3 & 4 > 1, "quote" and 'apostrophe'.

                Privileged verbs each require the typed `"<verb> <env>"` confirmation phrase (e.g. `"reset dev"`).

                Inline JSON: `'{"action":"db_state"}'`

                Issue 4144: `<>&"'`

                Literal entity text: `&lt;`

                Delimiter normalization: `` `tick` `` and ` code `.

                Hostile inline: `<img src=x onerror=alert(1)>`

                Hostile lifecycle: `<cmux-codespan-execution-probe></cmux-codespan-execution-probe>`

                Fenced block:
                ```bash
                aws lambda invoke --function-name foo --payload '{"action":"db_state"}' /dev/stdout
                ```

                Unknown-language hostile fence:
                ```unknown-cmux-language
                <img src=x onerror=alert(1)> & "'
                ```
                """,
                in: webView
            )

            #expect(snapshot.proseText == #"Plain prose control: 2 < 3 & 4 > 1, "quote" and 'apostrophe'."#)
            #expect(snapshot.proseChildElementCount == 0)
            #expect(
                snapshot.inlineTexts == [
                    #""<verb> <env>""#,
                    #""reset dev""#,
                    "'{\"action\":\"db_state\"}'",
                    #"<>&"'"#,
                    "&lt;",
                    "`tick`",
                    "code",
                    #"<img src=x onerror=alert(1)>"#,
                    #"<cmux-codespan-execution-probe></cmux-codespan-execution-probe>"#,
                ]
            )
            #expect(snapshot.inlineChildElementCounts == [0, 0, 0, 0, 0, 0, 0, 0, 0])
            #expect(
                snapshot.fencedTexts == [
                    #"aws lambda invoke --function-name foo --payload '{"action":"db_state"}' /dev/stdout"#,
                    #"<img src=x onerror=alert(1)> & "'"#,
                ]
            )
            #expect(snapshot.fencedImageCounts == [0, 0])
            #expect(snapshot.documentImageCount == 0)
            #expect(snapshot.hostileProbeElementCount == 0)
            #expect(snapshot.hostileProbeConnected == false)
        }
    }

    @Test
    func malformedCodespanTokensRemainSpanLocalAndEscaped() async throws {
        try await withLoadedMarkdownShell { webView in
            let result = try await webView.evaluateJavaScript(
                """
                window.marked.use({
                  walkTokens: function(token) {
                    if (token.type === 'codespan' && token.text === 'cmux-malformed-codespan') {
                      token.raw = '<img src=x onerror=alert(1)>';
                      token.text = token.raw;
                    }
                  }
                });
                window.__cmuxRenderMarkdown('Before `cmux-malformed-codespan` after.');
                var content = document.querySelector('#content');
                var paragraph = content.querySelector('p');
                var code = paragraph.querySelector('code');
                ({
                  paragraphText: paragraph.textContent,
                  codeText: code.textContent,
                  codeChildElementCount: code.children.length,
                  documentImageCount: content.querySelectorAll('img').length,
                  hasRenderError: content.textContent.indexOf('markdown render error:') !== -1
                });
                """
            )
            let raw = try #require(result as? [String: Any])
            #expect(raw["paragraphText"] as? String == "Before [invalid code span] after.")
            #expect(raw["codeText"] as? String == "[invalid code span]")
            #expect((raw["codeChildElementCount"] as? NSNumber)?.intValue == 0)
            #expect((raw["documentImageCount"] as? NSNumber)?.intValue == 0)
            #expect(raw["hasRenderError"] as? Bool == false)
        }
    }

    private func withLoadedMarkdownShell<T>(
        _ body: (WKWebView) async throws -> T
    ) async throws -> T {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-codespan-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loadDelegate = MarkdownCodespanShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            in: webView,
            baseURL: markdownURL
        )
        return try await body(webView)
    }

    private func renderSnapshot(
        _ markdown: String,
        in webView: WKWebView
    ) async throws -> MarkdownCodespanSnapshot {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            """
            (function(md) {
              var hostileProbeTag = 'cmux-codespan-execution-probe';
              window.__cmuxCodespanHostileProbeConnected = false;
              if (!window.customElements.get(hostileProbeTag)) {
                window.customElements.define(
                  hostileProbeTag,
                  class extends HTMLElement {
                    connectedCallback() {
                      window.__cmuxCodespanHostileProbeConnected = true;
                    }
                  }
                );
              }
              window.__cmuxRenderMarkdown(md);
              var prose = document.querySelector('#content p');
              var inlineCodes = Array.prototype.slice.call(
                document.querySelectorAll('#content p code:not(.hljs)')
              );
              var fencedCodes = Array.prototype.slice.call(
                document.querySelectorAll('#content pre > code.hljs')
              );
              return {
                proseText: prose ? prose.textContent : null,
                proseChildElementCount: prose ? prose.children.length : null,
                inlineTexts: inlineCodes.map(function(code) { return code.textContent; }),
                inlineChildElementCounts: inlineCodes.map(function(code) { return code.children.length; }),
                fencedTexts: fencedCodes.map(function(code) { return code.textContent; }),
                fencedImageCounts: fencedCodes.map(function(code) {
                  return code.querySelectorAll('img').length;
                }),
                documentImageCount: document.querySelectorAll('#content img').length,
                hostileProbeElementCount: document.querySelectorAll(
                  '#content ' + hostileProbeTag
                ).length,
                hostileProbeConnected: !!window.__cmuxCodespanHostileProbeConnected
              };
            })(\(literal)[0]);
            """
        )
        let raw = try #require(result as? [String: Any])
        let proseText = try #require(raw["proseText"] as? String)
        let proseChildElementCount = try #require(raw["proseChildElementCount"] as? NSNumber)
        let inlineTexts = try #require(raw["inlineTexts"] as? [String])
        let inlineChildElementCounts = try #require(raw["inlineChildElementCounts"] as? [NSNumber])
        let fencedTexts = try #require(raw["fencedTexts"] as? [String])
        let fencedImageCounts = try #require(raw["fencedImageCounts"] as? [NSNumber])
        let documentImageCount = try #require(raw["documentImageCount"] as? NSNumber)
        let hostileProbeElementCount = try #require(raw["hostileProbeElementCount"] as? NSNumber)
        let hostileProbeConnected = try #require(raw["hostileProbeConnected"] as? Bool)

        return MarkdownCodespanSnapshot(
            proseText: proseText,
            proseChildElementCount: proseChildElementCount.intValue,
            inlineTexts: inlineTexts,
            inlineChildElementCounts: inlineChildElementCounts.map(\.intValue),
            fencedTexts: fencedTexts,
            fencedImageCounts: fencedImageCounts.map(\.intValue),
            documentImageCount: documentImageCount.intValue,
            hostileProbeElementCount: hostileProbeElementCount.intValue,
            hostileProbeConnected: hostileProbeConnected
        )
    }
}

private struct MarkdownCodespanSnapshot {
    let proseText: String
    let proseChildElementCount: Int
    let inlineTexts: [String]
    let inlineChildElementCounts: [Int]
    let fencedTexts: [String]
    let fencedImageCounts: [Int]
    let documentImageCount: Int
    let hostileProbeElementCount: Int
    let hostileProbeConnected: Bool
}

private final class MarkdownCodespanShellLoadDelegate: NSObject, WKNavigationDelegate {
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
