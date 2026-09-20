import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserFailedNavigationReloadTests {
    enum Action: CaseIterable {
        case reload, hardRefresh, automation

        @MainActor func perform(on panel: BrowserPanel) {
            switch self {
            case .reload: panel.reload()
            case .hardRefresh: panel.hardReload()
            case .automation: _ = panel.beginAutomationReloadFromCLI()
            }
        }
    }

    @Test(arguments: Action.allCases, [false, true])
    func refreshReplaysFailedRequestInsteadOfReloadingInterstitial(
        action: Action,
        interstitialCommitted: Bool
    ) throws {
        let panel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let webView = installRecordingWebView(in: panel)
        let failedURL = try #require(URL(string: "https://refresh.example/submit"))
        var request = URLRequest(url: failedURL)
        request.httpMethod = "POST"
        request.httpBody = Data("payload=preserve-me".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("retained-header", forHTTPHeaderField: "X-Refresh-Test")
        panel.navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: false)
        fail(request, in: panel, webView: webView)
        // While the generated error document is committing, WebKit can still
        // expose the previous page URL. The failed request owns refresh in both states.
        webView.reportedURL = URL(string: interstitialCommitted ? "about:blank" : "https://previous.example/")
        webView.requests.removeAll()

        action.perform(on: panel)

        let replay = try #require(webView.requests.first)
        #expect(webView.requests.count == 1)
        #expect(replay.url == failedURL)
        #expect(replay.httpMethod == "POST")
        #expect(replay.httpBody == request.httpBody)
        #expect(replay.value(forHTTPHeaderField: "Content-Type") == request.value(forHTTPHeaderField: "Content-Type"))
        #expect(replay.value(forHTTPHeaderField: "X-Refresh-Test") == "retained-header")
        #expect(replay.cachePolicy == (action == .hardRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy))
        #expect(webView.reloadCount == 0)
        #expect(webView.originReloadCount == 0)
    }

    @Test(arguments: Action.allCases)
    func refreshDoesNotTurnAnUnreplayableUploadIntoGET(action: Action) throws {
        let panel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let webView = installRecordingWebView(in: panel)
        var request = URLRequest(url: try #require(URL(string: "https://refresh.example/upload")))
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data("streamed-upload".utf8))
        panel.navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: false)
        fail(request, in: panel, webView: webView)
        webView.reportedURL = URL(string: "about:blank")
        webView.requests.removeAll()

        action.perform(on: panel)

        #expect(webView.requests.isEmpty)
        #expect(webView.reloadCount == 0)
        #expect(webView.originReloadCount == 0)
    }

    @Test(arguments: Action.allCases)
    func healthyDocumentRetainsNativeReloadSemanticsAfterVisibilityChanges(action: Action) {
        let panel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let webView = installRecordingWebView(in: panel)
        webView.reportedURL = URL(string: "https://refresh.example/current")
        let store = webView.configuration.websiteDataStore
        panel.noteWebViewVisibility(false, reason: "test.switchAway")
        panel.noteWebViewVisibility(true, reason: "test.switchBack")

        action.perform(on: panel)

        #expect(panel.webView === webView)
        #expect(panel.webView.configuration.websiteDataStore === store)
        #expect(webView.requests.isEmpty)
        #expect(webView.reloadCount == (action == .hardRefresh ? 0 : 1))
        #expect(webView.originReloadCount == (action == .hardRefresh ? 1 : 0))
    }

    @Test(arguments: Action.allCases)
    func URLOnlyFailureStillStartsARealLoad(action: Action) throws {
        let panel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let webView = installRecordingWebView(in: panel)
        let request = URLRequest(url: try #require(URL(string: "https://refresh.example/recovered")))
        fail(request, in: panel, webView: webView)
        webView.reportedURL = URL(string: "about:blank")

        action.perform(on: panel)

        let replay = try #require(webView.requests.first)
        #expect(replay.url == request.url)
        #expect(replay.httpMethod == "GET")
        #expect(replay.cachePolicy == (action == .hardRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy))
    }

    @Test func portalRebindPreservesDocumentAndRoutesRefreshToTheSameWebView() throws {
        let panel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let webView = installRecordingWebView(in: panel)
        webView.reportedURL = URL(string: "https://refresh.example/current")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let first = NSView(frame: NSRect(x: 20, y: 20, width: 350, height: 400))
        content.addSubview(first)
        BrowserWindowPortalRegistry.bind(webView: webView, to: first, visibleInUI: true)
        let slot = try #require(webView.superview)
        BrowserWindowPortalRegistry.hide(webView: webView)
        first.removeFromSuperview()
        let replacement = NSView(frame: NSRect(x: 400, y: 20, width: 350, height: 400))
        content.addSubview(replacement)
        BrowserWindowPortalRegistry.bind(webView: webView, to: replacement, visibleInUI: true)
        BrowserWindowPortalRegistry.refresh(webView: webView, reason: "test.paneReplacement")

        #expect(webView.superview === slot)
        #expect(webView.isDescendant(of: try #require(window.contentView)))
        #expect(BrowserWindowPortalRegistry.isPresented(webView))
        #expect(webView.requests.isEmpty)
        #expect(webView.reloadCount == 0)
        panel.reload()
        #expect(webView.reloadCount == 1)
        #expect(panel.webView === webView)
    }

    private func installRecordingWebView(in panel: BrowserPanel) -> BrowserReloadRecordingWebView {
        panel.detachWebViewObservers()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = panel.websiteDataStore
        let webView = BrowserReloadRecordingWebView(frame: .zero, configuration: configuration)
        panel.webView = webView
        return webView
    }

    private func fail(_ request: URLRequest, in panel: BrowserPanel, webView: WKWebView) {
        panel.navigationDelegate?.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
                NSURLErrorFailingURLStringErrorKey: request.url!.absoluteString
            ])
        )
    }
}
