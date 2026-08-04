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
        try await withLoadedMarkdownShell { webView in
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
    }

    @Test
    func renderedInlineLinkTitleAndLabelAreEscapedOnce() async throws {
        try await withLoadedMarkdownShell { webView in
            let href = #"raw/with "quote"&and.md"#
            let snapshot = try await renderLinkBoundarySnapshot(
                #"See [<span onclick="x">label <strong>raw</strong></span> **bold**](<\#(href)> "a & \" <q>")."#,
                in: webView
            )

            #expect(snapshot.href == href)
            #expect(snapshot.title == #"a & " <q>"#)
            #expect(snapshot.text == "label raw bold")
            #expect(snapshot.innerHTML == "label raw <strong>bold</strong>")
        }
    }

    @Test
    func renderedLinkedMarkdownImagePreservesImageLabel() async throws {
        try await withLoadedMarkdownShell { webView in
            let snapshot = try await renderLinkBoundarySnapshot(
                #"[![diagram alt](raw/diagram.png "diagram title")](dest.md)."#,
                in: webView
            )

            #expect(snapshot.href == "dest.md")
            #expect(snapshot.imageAlt == "diagram alt")
            #expect(snapshot.imageTitle == "diagram title")
            #expect(snapshot.trailingText == ".")
        }
    }

    @Test
    func renderedExplicitlyRelativeColonFilenameRemainsALocalMarkdownCandidate() async throws {
        try await withLoadedMarkdownShell { webView in
            let snapshot = try await renderLinkBoundarySnapshot(
                "[Chapter](./chapter:one.md)",
                in: webView
            )

            #expect(snapshot.href == "./chapter:one.md")
            #expect(snapshot.fileCandidate == "./chapter:one.md")
        }
    }

    @Test
    func clickedRelativeLinkKeepsAuthoredPathWhileExplicitDotlessHTTPSStaysExternal() async throws {
        try await withLoadedMarkdownShellAndRoutes { webView, bridge, navigationDelegate in
            let relativePath = "raw/plans/agent-ticket-v2/w5-runner-design.md"
            _ = try await renderLinkBoundarySnapshot(
                "[Runner design](\(relativePath))",
                in: webView
            )
            bridge.reset()
            navigationDelegate.resetActivatedURLs()

            let relativeResult = try await webView.evaluateJavaScript(
                """
                (function() {
                  var anchor = document.querySelector('a');
                  var authored = anchor && anchor.getAttribute('data-cmux-file-candidate');
                  anchor.setAttribute('href', 'https://raw/plans/agent-ticket-v2/w5-runner-design.md');
                  anchor.click();
                  return {
                    authored: authored,
                    href: anchor.getAttribute('href')
                  };
                })();
                """
            )
            let relativeSnapshot = try #require(relativeResult as? [String: String])
            let openMessage = await bridge.nextBody(action: "openMarkdownFile")

            #expect(relativeSnapshot["authored"] == relativePath)
            #expect(relativeSnapshot["href"] == "https://raw/plans/agent-ticket-v2/w5-runner-design.md")
            #expect(openMessage["path"] as? String == relativePath)
            #expect(navigationDelegate.activatedURLs.isEmpty)

            _ = try await renderLinkBoundarySnapshot(
                "[Remote](https://raw/plans/agent-ticket-v2/w5-runner-design.md)",
                in: webView
            )
            bridge.reset()
            navigationDelegate.resetActivatedURLs()
            _ = try await webView.evaluateJavaScript(
                """
                document.querySelector('a').click();
                true;
                """
            )
            let activatedURL = await navigationDelegate.nextActivatedURL()

            #expect(bridge.lastBody(action: "openMarkdownFile") == nil)
            #expect(
                activatedURL.absoluteString
                    == "https://raw/plans/agent-ticket-v2/w5-runner-design.md"
            )
        }
    }

    private func withLoadedMarkdownShell<T>(
        _ body: (WKWebView) async throws -> T
    ) async throws -> T {
        try await withLoadedMarkdownShellAndRoutes { webView, _, _ in
            try await body(webView)
        }
    }

    private func withLoadedMarkdownShellAndRoutes<T>(
        _ body: (
            WKWebView,
            MarkdownLinkBoundaryBridgeRecorder,
            MarkdownLinkBoundaryShellLoadDelegate
        ) async throws -> T
    ) async throws -> T {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-boundary-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let configuration = WKWebViewConfiguration()
        let bridge = MarkdownLinkBoundaryBridgeRecorder()
        configuration.userContentController.add(bridge, name: "cmuxLib")
        let webView = WKWebView(frame: frame, configuration: configuration)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
            window.close()
        }

        let loadDelegate = MarkdownLinkBoundaryShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            in: webView,
            baseURL: markdownURL
        )
        return try await body(webView, bridge, loadDelegate)
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
              var image = anchor && anchor.querySelector('img');
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
                title: anchor && anchor.getAttribute('title'),
                text: anchor && anchor.textContent,
                innerHTML: anchor && anchor.innerHTML,
                imageAlt: image && image.getAttribute('alt'),
                imageTitle: image && image.getAttribute('title'),
                fileCandidate: anchor && anchor.getAttribute('data-cmux-file-candidate'),
                trailingText: trailing && trailing.textContent,
                periodHitHref: periodHit && periodHit.getAttribute && periodHit.getAttribute('href')
              };
            })(\(literal)[0]);
            """
        )
        let raw = try #require(result as? [String: Any])
        return LinkBoundarySnapshot(
            href: raw["href"] as? String,
            title: raw["title"] as? String,
            text: raw["text"] as? String,
            innerHTML: raw["innerHTML"] as? String,
            imageAlt: raw["imageAlt"] as? String,
            imageTitle: raw["imageTitle"] as? String,
            fileCandidate: raw["fileCandidate"] as? String,
            trailingText: raw["trailingText"] as? String ?? "",
            periodHitHref: raw["periodHitHref"] as? String
        )
    }
}

private struct LinkBoundarySnapshot {
    let href: String?
    let title: String?
    let text: String?
    let innerHTML: String?
    let imageAlt: String?
    let imageTitle: String?
    let fileCandidate: String?
    let trailingText: String
    let periodHitHref: String?
}

private final class MarkdownLinkBoundaryShellLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var activatedURLs: [URL] = []
    private var activatedURLContinuation: CheckedContinuation<URL, Never>?

    func resetActivatedURLs() {
        activatedURLs.removeAll()
    }

    func nextActivatedURL() async -> URL {
        if let url = activatedURLs.last {
            return url
        }
        return await withCheckedContinuation { continuation in
            activatedURLContinuation = continuation
        }
    }

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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            activatedURLs.append(url)
            activatedURLContinuation?.resume(returning: url)
            activatedURLContinuation = nil
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

@MainActor
private final class MarkdownLinkBoundaryBridgeRecorder: NSObject, WKScriptMessageHandler {
    private var bodies: [[String: Any]] = []
    private var bodyContinuations: [String: CheckedContinuation<[String: Any], Never>] = [:]

    func reset() {
        bodies.removeAll()
    }

    func lastBody(action: String) -> [String: Any]? {
        bodies.last { $0["action"] as? String == action }
    }

    func nextBody(action: String) async -> [String: Any] {
        if let body = lastBody(action: action) {
            return body
        }
        return await withCheckedContinuation { continuation in
            bodyContinuations[action] = continuation
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "cmuxLib",
              let body = message.body as? [String: Any] else { return }
        bodies.append(body)
        guard let action = body["action"] as? String,
              let continuation = bodyContinuations.removeValue(forKey: action) else { return }
        continuation.resume(returning: body)
    }
}
