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
final class MarkdownMermaidZoomTests {
    @Test
    func renderedMermaidDiagramScalesWithViewerZoom() async throws {
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

        let loadDelegate = MermaidZoomShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(MarkdownViewerAssets.shared.shellHTML(isDark: true), in: webView, baseURL: markdownURL)

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
        let baselineWidth = try #require(baseline["width"])
        let baselineProseHeight = try #require(baseline["proseHeight"])
        #expect(abs((baseline["zoom"] ?? -1) - 1) <= 0.001)
        #expect(abs(baselineWidth - 240) <= 2)

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize * 2)
        let zoomed = try await waitForMermaidSnapshot(in: webView, expectedZoom: 2)
        let zoomedWidth = try #require(zoomed["width"])
        let zoomedProseHeight = try #require(zoomed["proseHeight"])
        #expect(zoomedWidth > baselineWidth * 1.8)
        #expect(abs((zoomedWidth / baselineWidth) - (zoomedProseHeight / baselineProseHeight)) <= 0.25)
        let exported = try await exportedMermaidSnapshot(in: webView)
        #expect((exported["width"] ?? "missing") == "")
        #expect((exported["height"] ?? "missing") == "")
        #expect(exported["maxWidth"] == "240px")
        #expect(exported["hasCmuxData"] == "0")

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
        let fittedWidth = try #require(fitted["width"])
        let fittedContainerWidth = try #require(fitted["containerWidth"])
        #expect(fittedWidth > baselineWidth * 1.8)
        #expect(fittedWidth <= fittedContainerWidth + 2)

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize * 2)
        let fittedZoomed = try await waitForMermaidSnapshot(in: webView, expectedZoom: 2)
        let fittedZoomedWidth = try #require(fittedZoomed["width"])
        #expect(fittedZoomedWidth > fittedWidth * 1.8)
        #expect((try #require(fittedZoomed["leftOffset"])) >= -1)

        let widerFrame = NSRect(x: 0, y: 0, width: 960, height: 480)
        window.setFrame(widerFrame, display: true)
        webView.frame = widerFrame
        _ = try await webView.evaluateJavaScript("window.__cmuxSetMarkdownZoom(2);")
        let widened = try await waitForMermaidSnapshot(
            in: webView,
            expectedZoom: 2,
            minimumWidth: fittedZoomedWidth * 1.1
        )
        let widenedWidth = try #require(widened["width"])
        #expect(widenedWidth > fittedZoomedWidth * 1.1)
    }

    private func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

    private func waitForMermaidSnapshot(
        in webView: WKWebView,
        expectedZoom: Double? = nil,
        minimumWidth: Double? = nil
    ) async throws -> [String: Double] {
        let deadline = Date().addingTimeInterval(10)
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
        throw MermaidSnapshotTimeout(lastSnapshot: lastSnapshot)
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
                leftOffset: containerRect ? ((rect.left || 0) - (containerRect.left || 0)) : 0,
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

    private func exportedMermaidSnapshot(in webView: WKWebView) async throws -> [String: String] {
        let result = try await webView.evaluateJavaScript(
            """
            (function() {
              var wrapper = document.createElement('div');
              wrapper.innerHTML = window.__cmuxRenderedHTML();
              var svg = wrapper.querySelector('.cmux-mermaid svg');
              if (!svg) { return {}; }
              return {
                width: svg.style.width || '',
                height: svg.style.height || '',
                maxWidth: svg.style.maxWidth || '',
                hasCmuxData: Array.prototype.some.call(svg.attributes || [], function(attr) {
                  return String(attr.name || '').indexOf('data-cmux-') === 0;
                }) ? '1' : '0'
              };
            })();
            """
        )
        guard let raw = result as? [String: Any] else { return [:] }
        return raw.reduce(into: [String: String]()) { output, item in
            output[item.key] = item.value as? String
        }
    }
}

private final class MermaidZoomShellLoadDelegate: NSObject, WKNavigationDelegate {
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

private struct MermaidSnapshotTimeout: Error, CustomStringConvertible {
    let lastSnapshot: [String: Double]?

    var description: String {
        "Timed out waiting for Mermaid snapshot: \(String(describing: lastSnapshot))"
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
