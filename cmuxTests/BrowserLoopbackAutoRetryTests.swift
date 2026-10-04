import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The shared WebKit networking process can refuse loopback connections that
/// curl succeeds on (dev server restarting, or its per-host HTTP/1.1 pool
/// pinned by long-lived SSE/HMR connections). The navigation delegate
/// auto-retries those transient loopback failures instead of immediately
/// rendering the "Can't reach this page" error page.
@MainActor
@Suite(.serialized)
struct BrowserLoopbackAutoRetryTests {
    private func makePanel() -> (BrowserPanel, BrowserReloadRecordingWebView) {
        let panel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        panel.detachWebViewObservers()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = panel.websiteDataStore
        let webView = BrowserReloadRecordingWebView(frame: .zero, configuration: configuration)
        panel.webView = webView
        panel.navigationDelegate?.loopbackAutoRetryDelays = [0.01, 0.02]
        return (panel, webView)
    }

    private func fail(
        _ url: URL,
        in panel: BrowserPanel,
        webView: WKWebView,
        code: Int = NSURLErrorCannotConnectToHost
    ) {
        panel.navigationDelegate?.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: code, userInfo: [
                NSURLErrorFailingURLStringErrorKey: url.absoluteString
            ])
        )
    }

    @Test func loopbackConnectionFailureAutoRetriesWithoutErrorPage() async throws {
        let (panel, webView) = makePanel()
        defer { panel.close() }
        let url = try #require(URL(string: "http://127.0.0.1:5180/notes"))

        panel.navigateWithoutInsecureHTTPPrompt(to: url, recordTypedNavigation: false)
        webView.requests.removeAll()
        fail(url, in: panel, webView: webView)

        // No error page while the auto-retry is pending.
        #expect(panel.navigationDelegate?.activeErrorPageDisplayURL == nil)

        try await Task.sleep(for: .seconds(0.5))
        let replay = try #require(webView.requests.first)
        #expect(replay.url == url)
        #expect(replay.httpMethod == "GET")
        #expect(webView.requests.count == 1)
        #expect(panel.navigationDelegate?.activeErrorPageDisplayURL == nil)
    }

    @Test func budgetExhaustionShowsErrorPage() async throws {
        let (panel, webView) = makePanel()
        defer { panel.close() }
        let url = try #require(URL(string: "http://localhost:5180/notes"))

        panel.navigateWithoutInsecureHTTPPrompt(to: url, recordTypedNavigation: false)
        webView.requests.removeAll()

        fail(url, in: panel, webView: webView)
        try await Task.sleep(for: .seconds(0.3))
        #expect(webView.requests.count == 1)

        // The retry's own load fails again: second (final) auto-retry.
        fail(url, in: panel, webView: webView)
        try await Task.sleep(for: .seconds(0.4))
        #expect(webView.requests.count == 2)
        #expect(panel.navigationDelegate?.activeErrorPageDisplayURL == nil)

        // Budget exhausted: the failure now renders the error page.
        fail(url, in: panel, webView: webView)
        #expect(webView.requests.count == 2)
        #expect(panel.navigationDelegate?.activeErrorPageDisplayURL?.absoluteString == url.absoluteString)
    }

    @Test func nonLoopbackFailureShowsErrorPageImmediately() throws {
        let (panel, webView) = makePanel()
        defer { panel.close() }
        let url = try #require(URL(string: "https://example.com/notes"))

        panel.navigateWithoutInsecureHTTPPrompt(to: url, recordTypedNavigation: false)
        webView.requests.removeAll()
        fail(url, in: panel, webView: webView)

        #expect(webView.requests.isEmpty)
        #expect(panel.navigationDelegate?.activeErrorPageDisplayURL?.absoluteString == url.absoluteString)
    }

    @Test func unreplayableLoopbackUploadShowsErrorPageImmediately() throws {
        let (panel, webView) = makePanel()
        defer { panel.close() }
        let url = try #require(URL(string: "http://127.0.0.1:5180/upload"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data("streamed-upload".utf8))

        panel.navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: false)
        webView.requests.removeAll()
        fail(url, in: panel, webView: webView)

        #expect(webView.requests.isEmpty)
        #expect(panel.navigationDelegate?.activeErrorPageDisplayURL?.absoluteString == url.absoluteString)
    }

    @Test func commitResetsTheRetryBudget() async throws {
        let (panel, webView) = makePanel()
        defer { panel.close() }
        let url = try #require(URL(string: "http://localhost:5180/notes"))

        panel.navigateWithoutInsecureHTTPPrompt(to: url, recordTypedNavigation: false)
        webView.requests.removeAll()
        fail(url, in: panel, webView: webView)
        try await Task.sleep(for: .seconds(0.3))
        #expect(webView.requests.count == 1)

        // A committed load resets the budget, so the next failure retries again.
        panel.navigationDelegate?.webView(webView, didCommit: nil)
        fail(url, in: panel, webView: webView)
        try await Task.sleep(for: .seconds(0.3))
        #expect(webView.requests.count == 2)
    }

    @Test func pendingRetryYieldsToANewerNavigation() async throws {
        let (panel, webView) = makePanel()
        defer { panel.close() }
        let url = try #require(URL(string: "http://127.0.0.1:5180/notes"))
        let newerURL = try #require(URL(string: "http://127.0.0.1:5180/other"))

        panel.navigateWithoutInsecureHTTPPrompt(to: url, recordTypedNavigation: false)
        webView.requests.removeAll()
        fail(url, in: panel, webView: webView)

        // The user navigates elsewhere before the retry delay elapses.
        panel.navigateWithoutInsecureHTTPPrompt(to: newerURL, recordTypedNavigation: false)
        webView.requests.removeAll()

        try await Task.sleep(for: .seconds(0.4))
        #expect(webView.requests.isEmpty)
    }
}
