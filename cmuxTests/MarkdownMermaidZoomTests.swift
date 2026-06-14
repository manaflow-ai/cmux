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
        let baselineProseHeight = try XCTUnwrap(baseline["proseHeight"])
        XCTAssertEqual(baseline["zoom"] ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(baselineWidth, 240, accuracy: 2)

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize * 2)
        let zoomed = try await waitForMermaidSnapshot(in: webView, expectedZoom: 2)
        let zoomedWidth = try XCTUnwrap(zoomed["width"])
        let zoomedProseHeight = try XCTUnwrap(zoomed["proseHeight"])
        XCTAssertGreaterThan(zoomedWidth, baselineWidth * 1.8)
        XCTAssertEqual(zoomedWidth / baselineWidth, zoomedProseHeight / baselineProseHeight, accuracy: 0.25)

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize)
        try await renderMarkdown(
            """
            ```mermaid
            flowchart LR
              wideDiagram[Very wide diagram] --> wider[Still fits at one hundred percent]
            ```
            """,
            in: webView
        )
        let fitted = try await waitForMermaidSnapshot(in: webView)
        let fittedWidth = try XCTUnwrap(fitted["width"])
        XCTAssertGreaterThan(fittedWidth, baselineWidth * 1.8)
        XCTAssertLessThanOrEqual(fittedWidth, (try XCTUnwrap(fitted["containerWidth"])) + 2)

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize * 2)
        let fittedZoomed = try await waitForMermaidSnapshot(in: webView, expectedZoom: 2)
        let fittedZoomedWidth = try XCTUnwrap(fittedZoomed["width"])
        XCTAssertGreaterThan(fittedZoomedWidth, fittedWidth * 1.8)

        let widerFrame = NSRect(x: 0, y: 0, width: 960, height: 480)
        window.setFrame(widerFrame, display: true)
        webView.frame = widerFrame
        _ = try await webView.evaluateJavaScript("window.__cmuxSetMarkdownZoom(2);")
        let widened = try await waitForMermaidSnapshot(
            in: webView,
            expectedZoom: 2,
            minimumWidth: fittedZoomedWidth * 1.1
        )
        XCTAssertGreaterThan(try XCTUnwrap(widened["width"]), fittedZoomedWidth * 1.1)
    }

    private func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

    private func waitForMermaidSnapshot(
        in webView: WKWebView,
        expectedZoom: Double? = nil,
        minimumWidth: Double? = nil
    ) async throws -> [String: Double] {
        let deadline = Date().addingTimeInterval(3)
        var lastSnapshot: [String: Double]?
        while Date() < deadline {
            if let snapshot = try await mermaidSnapshot(in: webView) {
                lastSnapshot = snapshot
                let zoomMatches = expectedZoom.map { abs((snapshot["zoom"] ?? -1) - $0) <= 0.001 } ?? true
                let widthMatches = minimumWidth.map { (snapshot["width"] ?? 0) >= $0 } ?? ((snapshot["width"] ?? 0) > 0)
                if zoomMatches && widthMatches {
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
              var container = svg.closest('.cmux-mermaid');
              var containerRect = container ? container.getBoundingClientRect() : null;
              var prose = document.querySelector('.markdown-body p');
              var proseRect = prose ? prose.getBoundingClientRect() : null;
              var zoom = Number(svg.getAttribute('data-cmux-mermaid-zoom') || '1');
              return {
                width: rect.width || 0,
                containerWidth: containerRect ? (containerRect.width || 0) : 0,
                proseHeight: proseRect ? (proseRect.height || 0) : 0,
                zoom: Number.isFinite(zoom) ? zoom : 1
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
              render: function(id, src) {
                var isWide = String(src || '').indexOf('wideDiagram') !== -1;
                var width = isWide ? 1200 : 240;
                var height = isWide ? 600 : 120;
                return Promise.resolve({
                  svg: '<svg data-stub-mermaid="1" width="100%" style="max-width:' + width + 'px;" viewBox="0 0 ' + width + ' ' + height + '" xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="' + width + '" height="' + height + '" fill="#d73a49"></rect><text x="20" y="65" font-size="18" fill="#ffffff">Mermaid label</text></svg>'
                });
              }
            };
            if (window.__cmuxLibLoaded) { window.__cmuxLibLoaded('mermaid'); }
            """,
            completionHandler: nil
        )
    }
}
