import AppKit
import Foundation
import ObjectiveC.runtime
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for KaTeX math rendering in the markdown viewer (issue #6749):
/// the vendored assets, the shipped lazy-load injection, the shell wiring, the
/// `$...$` / `$$...$$` / ```` ```math ```` tokenizer (incl. currency
/// disambiguation and the block-vs-inline `$$` split), and the end-to-end
/// render pipeline through the lazy-load bridge.
@Suite(.serialized)
@MainActor
struct MarkdownKaTeXTests {

    // MARK: - Vendored assets

    @Test func katexJavaScriptAssetLoads() {
        let js = MarkdownViewerAssets.shared.lazyAsset(name: "katex.min", ext: "js")
        #expect(!js.isEmpty, "Bundled katex.min.js should be present")
        #expect(
            js.contains("renderToString"),
            "Bundled katex.min.js should expose renderToString"
        )
    }

    @Test func katexFontStylesheetInlinesFontsAsDataURIs() {
        let css = MarkdownViewerAssets.shared.lazyAsset(name: "katex-fonts.min", ext: "css")
        #expect(!css.isEmpty, "Bundled katex-fonts.min.css should be present")
        // The whole point of the data-URI font approach (issue #6749's open
        // question): no relative `url(fonts/...)` paths, which would resolve
        // against the user's markdown file base URL rather than the app bundle.
        #expect(
            !css.contains("url(fonts/"),
            "Font references must be inlined, not relative bundle paths"
        )
        #expect(
            css.contains("data:font/woff2;base64,"),
            "Fonts should be embedded as woff2 data URIs"
        )
        #expect(
            css.contains(".katex"),
            "Stylesheet should include KaTeX layout rules, not just fonts"
        )
    }

    /// Exercises the *shipped* injection builder used by `handleLibRequest`, so
    /// a regression in asset names or KaTeX's CSS-before-JS ordering is caught
    /// without standing up a WKWebView.
    @Test func katexLazyLibrarySourcesInjectStylesheetBeforeLibrary() throws {
        let sources = try #require(
            MarkdownWebRenderer.Coordinator.lazyLibrarySources(
                for: "katex",
                assets: .shared
            )
        )
        #expect(sources.count == 2, "katex should inject the stylesheet then the library")
        let cssInjection = sources[0]
        #expect(
            cssInjection.contains("cmux-katex-css"),
            "First source should install the KaTeX stylesheet <style> element"
        )
        #expect(
            sources[1].contains("renderToString"),
            "Second source should be the katex.min.js library"
        )
    }

    @Test func unknownLazyLibraryReturnsNil() {
        #expect(
            MarkdownWebRenderer.Coordinator.lazyLibrarySources(
                for: "not-a-real-lib",
                assets: .shared
            ) == nil
        )
    }

    // MARK: - Shell wiring (no WebKit needed)

    @Test func shellTemplateWiresMathRendering() {
        let shell = MarkdownViewerAssets.shared.shellHTML(isDark: false)
        #expect(shell.contains("cmuxMath"), "Shell should define the inline math tokenizer")
        #expect(shell.contains("cmuxMathBlock"), "Shell should define the block math tokenizer")
        #expect(shell.contains("renderKaTeXBlocks"), "Shell should define the KaTeX render pass")
        #expect(shell.contains("cmux-math-display"), "Shell should style display math blocks")
        #expect(shell.contains("loadLib('katex'"), "Shell should lazy-load katex only when math is present")
    }

    // MARK: - Tokenizer behavior (deterministic, no library load required)

    @Test func inlineAndDisplayMathProducePlaceholders() async throws {
        let (webView, cleanup) = try await renderMath("""
        Inline: $E = mc^2$

        $$\\mathcal{L}(\\theta)$$

        ```math
        \\nabla_\\theta \\mathcal{L}
        ```
        """)
        defer { cleanup() }

        #expect(try await count(".cmux-math-inline", in: webView) == 1, "one inline placeholder")
        #expect(try await count(".cmux-math-display", in: webView) == 2, "two display placeholders")

        // Greptile #6844: a standalone $$...$$ must render as a block <div>, not
        // an inline <span> wrapped in a <p> (which would add an extra margin the
        // ```math fence never gets).
        #expect(
            try await evaluateBool("!document.querySelector('p > .cmux-math-display')", in: webView),
            "Display math must not be wrapped in a <p>"
        )

        // The raw LaTeX must round-trip through the hidden .cmux-source child.
        let source = try await evaluateString(
            "document.querySelector('.cmux-math-inline .cmux-source').textContent",
            in: webView
        )
        #expect(source == "E = mc^2")
    }

    @Test func proseDollarAmountsAreNotTreatedAsMath() async throws {
        let (webView, cleanup) = try await renderMath("""
        I spent $5 on coffee and saved $3. The invoice was $100.
        The price is $1,000 (negotiable).
        """)
        defer { cleanup() }

        #expect(
            try await count(".cmux-math", in: webView) == 0,
            "Prose dollar amounts must not be parsed as inline math"
        )
    }

    @Test func mathInsideTableCellIsTokenized() async throws {
        let (webView, cleanup) = try await renderMath("""
        | Method | Variance |
        |--------|----------|
        | OLS    | $\\sigma^2 (X^TX)^{-1}$ |
        | Ridge  | biased |
        """)
        defer { cleanup() }

        #expect(
            try await evaluateBool("!!document.querySelector('td .cmux-math-inline')", in: webView),
            "Math inside a table cell should be tokenized"
        )
    }

    // MARK: - End-to-end render through the lazy-load bridge

    @Test func mathRendersThroughBridge() async throws {
        let (webView, cleanup) = try await renderMath(
            "Inline $E = mc^2$ and display $$\\sum_{i=1}^n x_i$$",
            wireKaTeXBridge: true
        )
        defer { cleanup() }

        try await waitForSelector(".katex", in: webView)
        #expect(
            try await count(".cmux-math-error, .cmux-render-error", in: webView) == 0,
            "Well-formed math should render without an error span"
        )
    }

    @Test func malformedMathRendersWithoutCrashing() async throws {
        // throwOnError:false means KaTeX renders an in-place error rather than
        // throwing; the document must still render and the placeholder must be
        // marked rendered.
        let (webView, cleanup) = try await renderMath(
            "Broken: $\\notacommand{x}$ and after.",
            wireKaTeXBridge: true
        )
        defer { cleanup() }

        // The surrounding prose must survive.
        try await waitForCondition(
            "document.getElementById('content').textContent.indexOf('and after.') >= 0",
            in: webView
        )
        // The math placeholder must end up rendered (data-rendered set), proving
        // renderKaTeXBlocks ran and did not throw out of the loop.
        try await waitForCondition(
            "!!document.querySelector('.cmux-math-inline[data-rendered]')",
            in: webView
        )
    }

    // MARK: - Helpers

    private static var loadDelegateKey: UInt8 = 0
    private static var bridgeKey: UInt8 = 0

    private func renderMath(
        _ markdown: String,
        wireKaTeXBridge: Bool = false
    ) async throws -> (WKWebView, @MainActor () -> Void) {
        let config = WKWebViewConfiguration()
        var bridge: KaTeXBridgeHandler?
        if wireKaTeXBridge {
            let handler = KaTeXBridgeHandler()
            bridge = handler
            config.userContentController.add(handler, name: "cmuxLib")
        }
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: config
        )
        bridge?.webView = webView
        if let bridge {
            objc_setAssociatedObject(webView, &Self.bridgeKey, bridge, .OBJC_ASSOCIATION_RETAIN)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()

        let cleanup: @MainActor () -> Void = {
            webView.navigationDelegate = nil
            if wireKaTeXBridge {
                config.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
            }
            window.close()
        }

        do {
            try await loadShell(into: webView)
            let data = try JSONSerialization.data(withJSONObject: [markdown])
            let literal = try #require(String(data: data, encoding: .utf8))
            _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
        } catch {
            cleanup()
            throw error
        }
        return (webView, cleanup)
    }

    private func loadShell(into webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // navigationDelegate is weak; retain the delegate via association so
            // it survives until the load finishes.
            let delegate = KaTeXShellLoadDelegate { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            objc_setAssociatedObject(
                webView, &Self.loadDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN
            )
            webView.navigationDelegate = delegate
            webView.loadHTMLString(
                MarkdownViewerAssets.shared.shellHTML(isDark: false),
                baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("math.md")
            )
        }
    }

    private func count(_ selector: String, in webView: WKWebView) async throws -> Int {
        let data = try JSONSerialization.data(withJSONObject: [selector])
        let literal = try #require(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            "document.querySelectorAll(\(literal)[0]).length"
        )
        return try #require((result as? NSNumber)?.intValue)
    }

    private func evaluateString(_ script: String, in webView: WKWebView) async throws -> String {
        let result = try await webView.evaluateJavaScript(script)
        return try #require(result as? String)
    }

    private func evaluateBool(_ script: String, in webView: WKWebView) async throws -> Bool {
        let result = try await webView.evaluateJavaScript(script)
        return try #require((result as? NSNumber)?.boolValue)
    }

    private func waitForSelector(_ selector: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [selector])
        let literal = try #require(String(data: data, encoding: .utf8))
        try await waitForCondition(
            "document.querySelectorAll(\(literal)[0]).length > 0",
            in: webView
        )
    }

    private func waitForCondition(_ script: String, in webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let result = try await webView.evaluateJavaScript("!!(\(script))")
            if (result as? NSNumber)?.boolValue == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out waiting for condition: \(script)")
    }
}

/// Minimal stand-in for `MarkdownWebRenderer.Coordinator.handleLibRequest`,
/// servicing the `{lib: "katex"}` lazy-load message using the *shipped*
/// `lazyLibrarySources` builder so the end-to-end render exercises the real
/// injection rather than a re-implementation.
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
              let webView,
              let sources = MarkdownWebRenderer.Coordinator.lazyLibrarySources(
                  for: "katex",
                  assets: .shared
              ) else { return }

        var injection = ""
        for src in sources where !src.isEmpty {
            injection += src
            injection += "\n;"
        }
        injection += "\nwindow.__cmuxLibLoaded && window.__cmuxLibLoaded('katex');"
        webView.evaluateJavaScript(injection, completionHandler: nil)
    }
}

@MainActor
private final class KaTeXShellLoadDelegate: NSObject, WKNavigationDelegate {
    private var onDone: ((Error?) -> Void)?

    init(onDone: @escaping (Error?) -> Void) {
        self.onDone = onDone
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        let callback = onDone
        onDone = nil
        callback?(error)
    }
}
