import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserElementPickerTests {
    @Test
    func pageGeneratedOptionClickCannotCreatePickedSelection() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let loader = BrowserViewportRuntimeLoadDelegate()
        webView.navigationDelegate = loader
        try await loader.load("<main><button id='target'>Untrusted page text</button></main>", in: webView)
        _ = try await webView.evaluateJavaScript(BrowserPanel.telemetryHookBootstrapScriptSource)

        let hasSelection = try #require(try await webView.evaluateJavaScript("""
            (() => {
              document.getElementById('target').dispatchEvent(new MouseEvent('click', {
                altKey: true, bubbles: true, composed: true
              }));
              return !!window.__cmuxPointedElement;
            })()
            """) as? Bool)

        #expect(!hasSelection, "A page-generated event must not impersonate an intentional user pick")
    }
}
