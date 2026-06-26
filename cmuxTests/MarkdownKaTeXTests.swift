import AppKit
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for KaTeX math rendering in the markdown viewer (issue #6749):
/// the vendored assets, the shell wiring, the `$...$` / `$$...$$` / ```` ```math ````
/// tokenizer (including currency disambiguation), and the end-to-end render
/// pipeline through the lazy-load bridge.
@MainActor
final class MarkdownKaTeXTests: XCTestCase {

    // MARK: - Vendored assets

    func testKaTeXJavaScriptAssetLoads() {
        let js = MarkdownViewerAssets.shared.lazyAsset(name: "katex.min", ext: "js")
        XCTAssertFalse(js.isEmpty, "Bundled katex.min.js should be present")
        XCTAssertTrue(
            js.contains("renderToString"),
            "Bundled katex.min.js should expose renderToString"
        )
    }

    func testKaTeXFontStylesheetInlinesFontsAsDataURIs() {
        let css = MarkdownViewerAssets.shared.lazyAsset(name: "katex-fonts.min", ext: "css")
        XCTAssertFalse(css.isEmpty, "Bundled katex-fonts.min.css should be present")
        // The whole point of the data-URI font approach (issue #6749's open
        // question): no relative `url(fonts/...)` paths, which would resolve
        // against the user's markdown file base URL rather than the app bundle.
        XCTAssertFalse(
            css.contains("url(fonts/"),
            "Font references must be inlined, not relative bundle paths"
        )
        XCTAssertTrue(
            css.contains("data:font/woff2;base64,"),
            "Fonts should be embedded as woff2 data URIs"
        )
        XCTAssertTrue(
            css.contains(".katex"),
            "Stylesheet should include KaTeX layout rules, not just fonts"
        )
    }

    // MARK: - Shell wiring (no WebKit needed)

    func testShellTemplateWiresMathRendering() {
        let shell = MarkdownViewerAssets.shared.shellHTML(isDark: false)
        XCTAssertTrue(
            shell.contains("cmuxMath"),
            "Shell should define the inline/display math tokenizer"
        )
        XCTAssertTrue(
            shell.contains("renderKaTeXBlocks"),
            "Shell should define the KaTeX render pass"
        )
        XCTAssertTrue(
            shell.contains("cmux-math-display"),
            "Shell should style display math blocks"
        )
        XCTAssertTrue(
            shell.contains("loadLib('katex'"),
            "Shell should lazy-load katex only when math is present"
        )
    }

    // MARK: - Tokenizer behavior (deterministic, no library load required)

    func testInlineAndDisplayMathProducePlaceholders() async throws {
        let webView = try await makeRenderedWebView(markdown: """
        Inline: $E = mc^2$

        $$\\mathcal{L}(\\theta)$$

        ```math
        \\nabla_\\theta \\mathcal{L}
        ```
        """)

        let inline = try await count(".cmux-math-inline", in: webView)
        let display = try await count(".cmux-math-display", in: webView)
        XCTAssertEqual(inline, 1, "Expected one inline ($...$) math placeholder")
        XCTAssertEqual(display, 2, "Expected two display placeholders ($$...$$ and ```math)")

        // The raw LaTeX must round-trip through the hidden .cmux-source child.
        let source = try await evaluateString(
            "document.querySelector('.cmux-math-inline .cmux-source').textContent",
            in: webView
        )
        XCTAssertEqual(source, "E = mc^2")
    }

    func testProseDollarAmountsAreNotTreatedAsMath() async throws {
        let webView = try await makeRenderedWebView(markdown: """
        I spent $5 on coffee and saved $3. The invoice was $100.
        The price is $1,000 (negotiable).
        """)

        let mathCount = try await count(".cmux-math", in: webView)
        XCTAssertEqual(
            mathCount,
            0,
            "Prose dollar amounts must not be parsed as inline math"
        )
    }

    func testMathInsideTableCellIsTokenized() async throws {
        let webView = try await makeRenderedWebView(markdown: """
        | Method | Variance |
        |--------|----------|
        | OLS    | $\\sigma^2 (X^TX)^{-1}$ |
        | Ridge  | biased |
        """)

        let inCell = try await evaluateBool(
            "!!document.querySelector('td .cmux-math-inline')",
            in: webView
        )
        XCTAssertTrue(inCell, "Math inside a table cell should be tokenized")
    }

    // MARK: - End-to-end render through the lazy-load bridge

    func testMathRendersThroughBridge() async throws {
        let webView = try await makeRenderedWebView(
            markdown: "Inline $E = mc^2$ and display $$\\sum_{i=1}^n x_i$$",
            wireKaTeXBridge: true
        )

        try await waitForSelector(".katex", in: webView)
        let errorCount = try await count(".cmux-math-error, .cmux-render-error", in: webView)
        XCTAssertEqual(errorCount, 0, "Well-formed math should render without an error span")
    }

    func testMalformedMathRendersErrorWithoutCrashing() async throws {
        // throwOnError:false means KaTeX renders an in-place error rather than
        // throwing; the document must still render and the placeholder must be
        // marked rendered.
        let webView = try await makeRenderedWebView(
            markdown: "Broken: $\\notacommand{x}$ and after.",
            wireKaTeXBridge: true
        )

        // The surrounding prose must survive.
        try await waitForCondition(in: webView, script:
            "document.getElementById('content').textContent.indexOf('and after.') >= 0"
        )
        // The math placeholder must end up rendered (data-rendered set), proving
        // renderKaTeXBlocks ran and did not throw out of the loop.
        try await waitForCondition(in: webView, script:
            "!!document.querySelector('.cmux-math-inline[data-rendered]')"
        )
    }

    // MARK: - Helpers

    private func makeRenderedWebView(
        markdown: String,
        wireKaTeXBridge: Bool = false
    ) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        var bridge: KaTeXBridgeHandler?
        if wireKaTeXBridge {
            let handler = KaTeXBridgeHandler()
            bridge = handler
            config.userContentController.add(handler, name: "cmuxLib")
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        bridge?.webView = webView
        // Retain the bridge for the life of the webView so it can service the
        // lazy-load message round-trip.
        if let bridge {
            objc_setAssociatedObject(
                webView, &Self.bridgeKey, bridge, .OBJC_ASSOCIATION_RETAIN
            )
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in
            webView.navigationDelegate = nil
            if wireKaTeXBridge {
                config.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
            }
            window.close()
        }

        let loaded = expectation(description: "markdown shell loaded")
        let loadDelegate = KaTeXShellLoadDelegate(expectation: loaded)
        webView.navigationDelegate = loadDelegate
        webView.loadHTMLString(
            MarkdownViewerAssets.shared.shellHTML(isDark: false),
            baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("math.md")
        )
        await fulfillment(of: [loaded], timeout: 10)
        if let error = loadDelegate.error { throw error }

        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
        return webView
    }

    private static var bridgeKey: UInt8 = 0

    private func count(_ selector: String, in webView: WKWebView) async throws -> Int {
        let data = try JSONSerialization.data(withJSONObject: [selector])
        let literal = try XCTUnwrap(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            "document.querySelectorAll(\(literal)[0]).length"
        )
        return try XCTUnwrap((result as? NSNumber)?.intValue)
    }

    private func evaluateString(_ script: String, in webView: WKWebView) async throws -> String {
        let result = try await webView.evaluateJavaScript(script)
        return try XCTUnwrap(result as? String)
    }

    private func evaluateBool(_ script: String, in webView: WKWebView) async throws -> Bool {
        let result = try await webView.evaluateJavaScript(script)
        return try XCTUnwrap((result as? NSNumber)?.boolValue)
    }

    private func waitForSelector(_ selector: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [selector])
        let literal = try XCTUnwrap(String(data: data, encoding: .utf8))
        try await waitForCondition(
            in: webView,
            script: "document.querySelectorAll(\(literal)[0]).length > 0"
        )
    }

    private func waitForCondition(in webView: WKWebView, script: String) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let result = try await webView.evaluateJavaScript("!!(\(script))")
            if (result as? NSNumber)?.boolValue == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for condition: \(script)")
    }
}

/// Minimal stand-in for `MarkdownWebRenderer.Coordinator.handleLibRequest`,
/// servicing the `{lib: "katex"}` lazy-load message by injecting the bundled
/// stylesheet and library exactly as the shipping coordinator does.
@MainActor
private final class KaTeXBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "cmuxLib",
              let body = message.body as? [String: Any],
              body["lib"] as? String == "katex",
              let webView else { return }

        let assets = MarkdownViewerAssets.shared
        let css = assets.lazyAsset(name: "katex-fonts.min", ext: "css")
        let cssLiteral = (try? JSONSerialization.data(withJSONObject: [css]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let cssInjection = """
        (function(text){
          var styleEl = document.createElement('style');
          styleEl.id = 'cmux-katex-css';
          styleEl.textContent = text;
          (document.head || document.documentElement).appendChild(styleEl);
        })(\(cssLiteral)[0]);
        """
        let katexJS = assets.lazyAsset(name: "katex.min", ext: "js")
        let injection = cssInjection
            + "\n;" + katexJS
            + "\nwindow.__cmuxLibLoaded && window.__cmuxLibLoaded('katex');"
        webView.evaluateJavaScript(injection, completionHandler: nil)
    }
}

@MainActor
private final class KaTeXShellLoadDelegate: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation
    var error: Error?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        expectation.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        expectation.fulfill()
    }
}
