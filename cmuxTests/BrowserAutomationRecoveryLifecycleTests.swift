import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Browser automation recovery lifecycle")
struct BrowserAutomationRecoveryLifecycleTests {
    @Test("Closing a browser panel prevents automation recovery from resurrecting it")
    func closedPanelCannotRecover() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: try #require(URL(string: "about:blank"))
        )
        let webViewIdentifier = ObjectIdentifier(panel.webView)
        panel.close()

        let didRecover = panel.replaceWebViewAfterAutomationTimeout(
            expectedWebViewIdentifier: webViewIdentifier,
            reason: "test.closed"
        )
        panel.close()

        #expect(!didRecover)
    }

    @Test("An active visual capture keeps ownership of its WebView")
    func activeVisualCapturePreventsRecovery() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: try #require(URL(string: "about:blank")),
            preloadInitialNavigationInBackground: true
        )
        defer { panel.close() }
        let webViewIdentifier = ObjectIdentifier(panel.webView)
        panel.captureAutomationVisibleViewportSnapshot { _ in }

        #expect(!panel.canRecoverFromAutomationTimeout)
        #expect(!panel.replaceWebViewAfterAutomationTimeout(
            expectedWebViewIdentifier: webViewIdentifier,
            reason: "test.active-capture"
        ))
        #expect(ObjectIdentifier(panel.webView) == webViewIdentifier)
    }
}
