import AppKit
import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A browser panel hosts a non-WebKit page only when its engine resolves to
/// one; the default stays a plain WebKit panel.
@MainActor
@Suite(.serialized) struct BrowserPanelEngineTests {
    @MainActor
    final class FakeChromiumPage: BrowserPage {
        var engineKind: BrowserEngineKind { .chromium }
        var capabilities: BrowserEngineCapabilities { [.devToolsProtocol] }
        var presentation: BrowserPagePresentation { .childWindow }
        let contentView = NSView(frame: .zero)
        var state = BrowserPageState()
        weak var uiDelegate: (any BrowserPageUIDelegate)?
        var pageZoom: Double = 1
        var isDevToolsVisible = false
        var isMuted = false
        private(set) var loadedURLs: [URL] = []
        private(set) var backCount = 0
        private(set) var stopCount = 0
        private(set) var closeCount = 0
        private let stream: AsyncStream<BrowserPageEvent>
        private let continuation: AsyncStream<BrowserPageEvent>.Continuation

        init() {
            (stream, continuation) = AsyncStream<BrowserPageEvent>.makeStream()
        }

        var events: AsyncStream<BrowserPageEvent> { stream }
        func send(_ event: BrowserPageEvent) { continuation.yield(event) }

        func load(_ request: URLRequest) { request.url.map { loadedURLs.append($0) } }
        func loadHTMLString(_ html: String, baseURL: URL?) {}
        func goBack() { backCount += 1 }
        func goForward() {}
        func reload() {}
        func reloadFromOrigin() {}
        func stop() { stopCount += 1 }
        func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? { nil }
        func callAsyncJavaScript(_ body: String, arguments: [String: any Sendable], in world: BrowserPageScriptWorld) async throws -> Any? { nil }
        func addUserScript(_ script: BrowserPageUserScript) {}
        func removeAllUserScripts() {}
        func showDevTools() {}
        func closeDevTools() {}
        func sendDevToolsProtocolMessage(method: String, params: Data?) async throws -> Data { Data("{}".utf8) }
        func takeSnapshot(rect: CGRect?) async throws -> NSImage { NSImage() }
        func setFocused(_ focused: Bool) -> Bool { true }
        func setContentVisible(_ visible: Bool) {}
        func dispatchInput(_ event: BrowserPageInputEvent) async throws {}
        func exportRestoreState() -> BrowserPageRestoreState? { nil }
        func close() {
            closeCount += 1
            continuation.finish()
        }
    }

    @MainActor
    final class FakeChromiumProvider: BrowserEngineProviding {
        let kind = BrowserEngineKind.chromium
        var availability = BrowserEngineAvailability.available
        let capabilities: BrowserEngineCapabilities = [.devToolsProtocol]
        private(set) var pages: [FakeChromiumPage] = []
        var initialState = BrowserPageState()

        func makePage(_ configuration: BrowserPageConfiguration) throws -> any BrowserPage {
            let page = FakeChromiumPage()
            page.state = initialState
            pages.append(page)
            return page
        }
    }

    private func runtime(
        providers: [any BrowserEngineProviding] = [],
        environment: [String: String] = [:]
    ) -> BrowserEngineRuntime {
        BrowserEngineRuntime(
            registry: BrowserEngineRegistry(providers: providers),
            environment: environment,
            defaults: UserDefaults(suiteName: "BrowserPanelEngineTests.\(UUID().uuidString)")!
        )
    }

    @Test func defaultPanelStaysWebKit() {
        let panel = BrowserPanel(workspaceId: UUID(), engineRuntime: runtime())
        defer { panel.close() }
        #expect(panel.engineKind == .webkit)
        #expect(panel.enginePage == nil)
        #expect(panel.automationEnginePage == nil)
        #expect(panel.engineFallbackNotice == nil)
        let page = panel.page as? WebKitBrowserPage
        #expect(page?.webView === panel.webView)
    }

    @Test func unavailableChromiumFallsBackToWebKitWithOneNotice() {
        let engines = runtime(environment: ["CMUX_BROWSER_ENGINE": "chromium"])
        let first = BrowserPanel(workspaceId: UUID(), engineRuntime: engines)
        let second = BrowserPanel(workspaceId: UUID(), engineRuntime: engines)
        defer {
            first.close()
            second.close()
        }
        #expect(first.engineKind == .webkit)
        #expect(first.engineFallbackNotice == .notBundled)
        #expect(second.engineKind == .webkit)
        #expect(second.engineFallbackNotice == nil)
    }

    @Test func explicitUnavailableChromiumIsRefused() {
        #expect(BrowserPanel.resolvedEngineChoice(requested: .chromium, runtime: runtime()) == nil)
        #expect(BrowserPanel.resolvedEngineChoice(requested: .webkit, runtime: runtime())?.engine == .webkit)
    }

    @Test func chromiumPanelRoutesNavigationAndMirrorsState() throws {
        let provider = FakeChromiumProvider()
        let url = URL(string: "https://example.com/")!
        provider.initialState = BrowserPageState(url: url, title: "Example", canGoBack: true)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }

        let page = try #require(provider.pages.first)
        #expect(panel.engineKind == .chromium)
        #expect(panel.automationEnginePage === page)
        #expect(panel.page === page)
        #expect(page.loadedURLs == [url])
        // The page's state is mirrored when the panel starts listening.
        #expect(panel.pageTitle == "Example")
        #expect(panel.canGoBack)

        panel.applyEnginePageState(BrowserPageState(url: url, title: "Changed", isLoading: true))
        #expect(panel.pageTitle == "Changed")
        #expect(panel.isLoading)
        #expect(!panel.canGoBack)

        panel.applyEnginePageState(BrowserPageState(url: url, title: "Changed", canGoBack: true))
        panel.goBack()
        #expect(page.backCount == 1)
        panel.stopLoading()
        #expect(page.stopCount == 1)
    }

    @Test func sessionSnapshotRecordsOnlyNonWebKitEngines() throws {
        var snapshot = SessionBrowserPanelSnapshot(
            urlString: "https://example.com/", profileID: nil, shouldRenderWebView: true,
            pageZoom: 1, developerToolsVisible: false,
            backHistoryURLStrings: nil, forwardHistoryURLStrings: nil
        )
        let webKitJSON = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: webKitJSON, as: UTF8.self).contains("engine"))

        snapshot.engine = .chromium
        let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.engine == .chromium)

        var object = try #require(JSONSerialization.jsonObject(with: webKitJSON) as? [String: Any])
        object["engine"] = "gecko"
        let unknown = try JSONSerialization.data(withJSONObject: object)
        let fromUnknown = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: unknown)
        #expect(fromUnknown.engine == nil)
    }

    @Test func restoredPanelsKeepTheirEngine() {
        let engines = runtime(providers: [FakeChromiumProvider()])
        #expect(BrowserPanel.restoredEngineChoice(nil, runtime: engines).engine == .webkit)
        #expect(BrowserPanel.restoredEngineChoice(.chromium, runtime: engines).engine == .chromium)
        let unavailable = BrowserPanel.restoredEngineChoice(.chromium, runtime: runtime())
        #expect(unavailable.engine == .webkit)
        #expect(unavailable.fallback == .notBundled)
    }

    @Test func chromiumStartFailureFallsBackToWebKitWithNotice() throws {
        let provider = FakeChromiumProvider()
        let engines = runtime(providers: [provider])
        let url = URL(string: "https://example.com/")!
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: engines
        )
        defer { panel.close() }
        let page = try #require(provider.pages.first)
        #expect(panel.engineKind == .chromium)

        // The runtime fails to start after the page was created.
        provider.availability = .unavailable(.startFailed("NSApp does not conform to CefAppProtocol"))
        panel.handleEnginePageEvent(.navigationFailed(url, code: -1, message: "start failed", showsEngineErrorPage: false))

        #expect(panel.engineKind == .webkit)
        #expect(panel.enginePage == nil)
        #expect(page.closeCount == 1)
        #expect(panel.engineFallbackNotice == .startFailed("NSApp does not conform to CefAppProtocol"))
        #expect(panel.page is WebKitBrowserPage)
        // Later explicit requests are refused with the reason.
        #expect(BrowserPanel.resolvedEngineChoice(requested: .chromium, runtime: engines) == nil)
    }

    @Test func ordinaryChromiumLoadFailureKeepsTheChromiumPage() throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        panel.handleEnginePageEvent(.navigationFailed(URL(string: "https://nope.invalid/"), code: -105, message: "NAME_NOT_RESOLVED", showsEngineErrorPage: true))
        #expect(panel.engineKind == .chromium)
        #expect(panel.engineFallbackNotice == nil)
    }

    @Test func closingTheChromiumPanelClosesItsPage() {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        panel.close()
        #expect(provider.pages.first?.closeCount == 1)
    }
}
