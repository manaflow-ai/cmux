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
final class MarkdownLinkBoundaryRegressionTests {
    @Test
    func renderedInlineLinkExcludesTrailingSentencePeriod() async throws {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-boundary-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loadDelegate = MarkdownLinkBoundaryShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            in: webView,
            baseURL: markdownURL
        )

        let expectedPath = "raw/plans/agent-ticket-v2/w5-runner-design.md"
        let snapshot = try await renderLinkBoundarySnapshot(
            """
            The runner design doc is written: [\(expectedPath)](\(expectedPath)). It locks in the decisions we discussed...
            """,
            in: webView
        )

        #expect(snapshot.href == expectedPath)
        #expect(snapshot.text == expectedPath)
        #expect(snapshot.trailingText.hasPrefix(". It locks in"))
        #expect(snapshot.periodHitHref == nil)
    }

    private func renderLinkBoundarySnapshot(
        _ markdown: String,
        in webView: WKWebView
    ) async throws -> LinkBoundarySnapshot {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            """
            (function(md) {
              window.__cmuxRenderMarkdown(md);
              var anchor = document.querySelector('a');
              var trailing = anchor && anchor.nextSibling;
              var periodHit = null;
              if (trailing && trailing.nodeType === Node.TEXT_NODE && trailing.textContent.charAt(0) === '.') {
                var range = document.createRange();
                range.setStart(trailing, 0);
                range.setEnd(trailing, 1);
                var rect = range.getBoundingClientRect();
                periodHit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
              }
              return {
                href: anchor && anchor.getAttribute('href'),
                text: anchor && anchor.textContent,
                trailingText: trailing && trailing.textContent,
                periodHitHref: periodHit && periodHit.getAttribute && periodHit.getAttribute('href')
              };
            })(\(literal)[0]);
            """
        )
        let raw = try #require(result as? [String: Any])
        return LinkBoundarySnapshot(
            href: raw["href"] as? String,
            text: raw["text"] as? String,
            trailingText: raw["trailingText"] as? String ?? "",
            periodHitHref: raw["periodHitHref"] as? String
        )
    }
}

private struct LinkBoundarySnapshot {
    let href: String?
    let text: String?
    let trailingText: String
    let periodHitHref: String?
}

private final class MarkdownLinkBoundaryShellLoadDelegate: NSObject, WKNavigationDelegate {
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
