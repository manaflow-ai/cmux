import AppKit
import WebKit
import XCTest
@testable import cmux

@MainActor
final class ViewerNavigationTests: XCTestCase {
    func testMarkdownViewerUsesSmoothVimAndEmacsNavigation() async throws {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 360)
        let webView = MarkdownWebView(frame: frame, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loaded = expectation(description: "markdown shell loaded")
        let loadDelegate = ViewerNavigationShellLoadDelegate(expectation: loaded)
        webView.navigationDelegate = loadDelegate
        webView.loadHTMLString(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("navigation.md")
        )
        await fulfillment(of: [loaded], timeout: 5)
        if let error = loadDelegate.error {
            throw error
        }
        try await renderMarkdown(scrollSmokeMarkdown(), in: webView)

        let result = try await webView.evaluateJavaScript(
            """
            (function() {
              var scroller = document.scrollingElement || document.documentElement;
              var calls = [];
              scroller.scrollTo = function(options) { calls.push(options); };
              document.dispatchEvent(new KeyboardEvent('keydown', { key: 'j', bubbles: true }));
              document.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', ctrlKey: true, bubbles: true }));
              document.dispatchEvent(new KeyboardEvent('keydown', { key: 'p', ctrlKey: true, bubbles: true }));
              return calls;
            })();
            """
        )
        let calls = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.map { $0["behavior"] as? String }, ["smooth", "smooth", "smooth"])
        XCTAssertEqual((calls[0]["top"] as? NSNumber)?.doubleValue, 72)
        XCTAssertGreaterThan((calls[1]["top"] as? NSNumber)?.doubleValue ?? 0, 100)
        XCTAssertLessThan(
            (calls[2]["top"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude,
            (calls[1]["top"] as? NSNumber)?.doubleValue ?? 0
        )

        try await webView.evaluateJavaScript(
            """
            (function() {
              var scroller = document.scrollingElement || document.documentElement;
              window.__cmuxNativeNavigationCalls = [];
              scroller.scrollTo = function(options) { window.__cmuxNativeNavigationCalls.push(options); };
            })();
            """
        )
        XCTAssertTrue(webView.handleViewerNavigationKey(Self.keyEvent("j")))
        XCTAssertTrue(webView.handleViewerNavigationKey(Self.keyEvent("d", modifiers: .control)))
        XCTAssertTrue(webView.handleViewerNavigationKey(Self.keyEvent("g")))
        XCTAssertTrue(webView.handleViewerNavigationKey(Self.keyEvent("g")))
        XCTAssertFalse(webView.handleViewerNavigationKey(Self.keyEvent("x")))
        let nativeCalls = try XCTUnwrap(
            try await webView.evaluateJavaScript("window.__cmuxNativeNavigationCalls") as? [[String: Any]]
        )
        XCTAssertEqual(nativeCalls.count, 3)
        XCTAssertEqual(nativeCalls.map { $0["behavior"] as? String }, ["smooth", "smooth", "smooth"])
        XCTAssertGreaterThan((nativeCalls[0]["top"] as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertGreaterThan(
            (nativeCalls[1]["top"] as? NSNumber)?.doubleValue ?? 0,
            (nativeCalls[0]["top"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude
        )
        XCTAssertEqual((nativeCalls[2]["top"] as? NSNumber)?.doubleValue, 0)
    }

    private func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

    private func scrollSmokeMarkdown() -> String {
        (1...36).map { section in
            "## Section \(section)\n\n" + (1...5).map { paragraph in
                "Paragraph \(paragraph) for section \(section). This gives the renderer enough height to exercise viewer navigation."
            }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    private static func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }
}

private final class ViewerNavigationShellLoadDelegate: NSObject, WKNavigationDelegate {
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
