import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the WebKit process termination callback boundary.
@MainActor
@Suite(.serialized)
struct BrowserWebContentTerminationLifecycleTests {
    @Test
    func terminationCallbackDoesNotReplaceWebViewInsideWebKitCallback() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com/recovery")!
        )
        defer { panel.close() }

        let originalWebView = panel.webView
        panel.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(originalWebView)

        #expect(panel.webView === originalWebView)
        #expect(originalWebView.navigationDelegate == nil)
    }
}
