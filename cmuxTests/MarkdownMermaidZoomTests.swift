import AppKit
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MarkdownMermaidZoomTests: XCTestCase {
    func testRenderedMermaidDiagramScalesWithViewerZoom() async throws {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-mermaid-zoom-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        let configuration = WKWebViewConfiguration()
        let mermaidHandler = MarkdownMermaidStubHandler()
        configuration.userContentController.add(mermaidHandler, name: "cmuxLib")
        let webView = MarkdownWebView(frame: frame, configuration: configuration)
        mermaidHandler.webView = webView
        let coordinator = MarkdownWebRenderer.Coordinator()
        coordinator.webView = webView
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            coordinator.webView = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
            window.close()
        }

        let loaded = expectation(description: "markdown shell loaded")
        let loadDelegate = MermaidZoomShellLoadDelegate(expectation: loaded)
        webView.navigationDelegate = loadDelegate
        webView.loadHTMLString(MarkdownViewerAssets.shared.shellHTML(isDark: true), baseURL: markdownURL)
        await fulfillment(of: [loaded], timeout: 5)
        if let error = loadDelegate.error { throw error }

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize)
        try await renderMarkdown(
            """
            Prose before the diagram.

            ```mermaid
            flowchart LR
              host[Host process] --> backend[Backend]
              backend --> worker[Worker]
            ```
            """,
            in: webView
        )

        let baseline = try await waitForMermaidSnapshot(in: webView)
        let baselineWidth = try XCTUnwrap(baseline["width"])
        XCTAssertEqual(baseline["zoom"] ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(baselineWidth, 240, accuracy: 2)

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize * 2)
        let zoomed = try await waitForMermaidSnapshot(in: webView, expectedZoom: 2)
        XCTAssertGreaterThan(try XCTUnwrap(zoomed["width"]), baselineWidth * 1.8)
        XCTAssertEqual(zoomed["inlineMaxWidthCleared"] ?? 0, 1, accuracy: 0.001)
    }

    private func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

    private func waitForMermaidSnapshot(
        in webView: WKWebView,
        expectedZoom: Double? = nil
    ) async throws -> [String: Double] {
        let deadline = Date().addingTimeInterval(3)
        var lastSnapshot: [String: Double]?
        while Date() < deadline {
            if let snapshot = try await mermaidSnapshot(in: webView) {
                lastSnapshot = snapshot
                if let expectedZoom {
                    if abs((snapshot["zoom"] ?? -1) - expectedZoom) <= 0.001 { return snapshot }
                } else if (snapshot["width"] ?? 0) > 0 {
                    return snapshot
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(
            domain: "MarkdownMermaidZoomTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Mermaid snapshot: \(String(describing: lastSnapshot))"]
        )
    }

    private func mermaidSnapshot(in webView: WKWebView) async throws -> [String: Double]? {
        let result = try await webView.evaluateJavaScript(
            """
            (function() {
              var svg = document.querySelector('.cmux-mermaid svg');
              if (!svg) { return null; }
              var rect = svg.getBoundingClientRect();
              var zoom = Number(svg.getAttribute('data-cmux-mermaid-zoom') || '1');
              return {
                width: rect.width || 0,
                zoom: Number.isFinite(zoom) ? zoom : 1,
                inlineMaxWidthCleared: svg.style.maxWidth === 'none' ? 1 : 0
              };
            })();
            """
        )
        guard let raw = result as? [String: Any] else { return nil }
        var snapshot: [String: Double] = [:]
        for (key, value) in raw {
            if let number = value as? NSNumber { snapshot[key] = number.doubleValue }
        }
        return snapshot
    }
}

private final class MermaidZoomShellLoadDelegate: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation
    var error: Error?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }
}

@MainActor
private final class MarkdownMermaidStubHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "cmuxLib",
              let body = message.body as? [String: Any],
              body["lib"] as? String == "mermaid" else { return }
        webView?.evaluateJavaScript(
            """
            window.mermaid = {
              initialize: function() {},
              render: function() {
                return Promise.resolve({
                  svg: '<svg data-stub-mermaid="1" width="100%" style="max-width:240px;" viewBox="0 0 240 120" xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="240" height="120" fill="#d73a49"></rect><text x="20" y="65" font-size="18" fill="#ffffff">Mermaid label</text></svg>'
                });
              }
            };
            if (window.__cmuxLibLoaded) { window.__cmuxLibLoaded('mermaid'); }
            """,
            completionHandler: nil
        )
    }
}
