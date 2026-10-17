import AppKit
import Bonsplit
import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chromium panels recover from failed loads, keep their engine and history
/// across Reopen Closed Tab and Duplicate Tab, and list their history in the
/// Back and Forward menus (parity with cmux Next).
@MainActor
@Suite(.serialized) struct BrowserChromiumNavigationRecoveryTests {
    @MainActor
    final class FakePage: BrowserPage, BrowserPageBackForwardListing, BrowserPageNavigationRestoring,
        BrowserPageCertificateBypassing {
        var engineKind: BrowserEngineKind { .chromium }
        var capabilities: BrowserEngineCapabilities { [.devToolsProtocol] }
        var presentation: BrowserPagePresentation { .childWindow }
        let contentView = NSView(frame: .zero)
        var state = BrowserPageState()
        weak var uiDelegate: (any BrowserPageUIDelegate)?
        var pageZoom: Double = 1
        var isDevToolsVisible = false
        var isMuted = false
        var exportedState: BrowserPageRestoreState?
        var history = BrowserBackForwardList(back: [], forward: [])
        private(set) var loadedURLs: [URL] = []
        private(set) var reloadCount = 0
        private(set) var restoredStates: [BrowserPageRestoreState] = []
        private(set) var visitedOffsets: [Int] = []
        private(set) var proceeded: [(code: Int, url: URL)] = []
        private let stream: AsyncStream<BrowserPageEvent>
        private let continuation: AsyncStream<BrowserPageEvent>.Continuation

        init() {
            (stream, continuation) = AsyncStream<BrowserPageEvent>.makeStream()
        }

        var events: AsyncStream<BrowserPageEvent> { stream }

        func load(_ request: URLRequest) { request.url.map { loadedURLs.append($0) } }
        func loadHTMLString(_ html: String, baseURL: URL?) {}
        func goBack() {}
        func goForward() {}
        func reload() { reloadCount += 1 }
        func reloadFromOrigin() {}
        func stop() {}
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
        func exportRestoreState() -> BrowserPageRestoreState? { exportedState }
        func close() { continuation.finish() }

        func backForwardList() -> BrowserBackForwardList? { history }
        func goToBackForwardEntry(offset: Int) -> Bool {
            visitedOffsets.append(offset)
            return true
        }
        func restoreNavigation(_ state: BrowserPageRestoreState, fallbackURL: URL?) -> Bool {
            restoredStates.append(state)
            return true
        }
        func proceedPastCertificateError(_ error: ChromiumNetError, at url: URL) -> Bool {
            proceeded.append((error.code, url))
            return true
        }
    }

    @MainActor
    final class FakeProvider: BrowserEngineProviding {
        let kind = BrowserEngineKind.chromium
        var availability = BrowserEngineAvailability.available
        let capabilities: BrowserEngineCapabilities = [.devToolsProtocol]
        private(set) var pages: [FakePage] = []
        var exportedState: BrowserPageRestoreState?

        func makePage(_ configuration: BrowserPageConfiguration) throws -> any BrowserPage {
            let page = FakePage()
            page.exportedState = exportedState
            pages.append(page)
            return page
        }
    }

    private func runtime(_ provider: FakeProvider) -> BrowserEngineRuntime {
        BrowserEngineRuntime(
            registry: BrowserEngineRegistry(providers: [provider]),
            environment: [:],
            defaults: UserDefaults(suiteName: "BrowserChromiumNavigationRecoveryTests.\(UUID().uuidString)")!
        )
    }

    private func chromiumPanel(_ provider: FakeProvider, url: URL? = nil) -> BrowserPanel {
        BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(provider)
        )
    }

    private func loadFailure(_ panel: BrowserPanel) -> ChromiumNetError? {
        guard case .chromiumLoadFailed(let error)? = panel.pageRecoveryPrompt else { return nil }
        return error
    }

    // MARK: Load failures

    @Test func aFailureChromiumDrewNoPageForShowsTheRecoveryView() throws {
        let provider = FakeProvider()
        let panel = chromiumPanel(provider)
        defer { panel.close() }
        let url = URL(string: "https://127.0.0.1:8443/")!
        panel.handleEnginePageEvent(.navigationFailed(url, code: -202, message: "net::ERR_CERT_AUTHORITY_INVALID", showsEngineErrorPage: false))
        #expect(loadFailure(panel)?.code == -202)
        #expect(loadFailure(panel)?.name == "ERR_CERT_AUTHORITY_INVALID")
    }

    @Test func chromiumsOwnErrorPageAndAbortedLoadsShowNoRecoveryView() throws {
        let provider = FakeProvider()
        let panel = chromiumPanel(provider)
        defer { panel.close() }
        let url = URL(string: "http://127.0.0.1:9/")!
        panel.handleEnginePageEvent(.navigationFailed(url, code: -102, message: "net::ERR_CONNECTION_REFUSED", showsEngineErrorPage: true))
        #expect(panel.pageRecoveryPrompt == nil)
        panel.handleEnginePageEvent(.navigationFailed(url, code: -3, message: "net::ERR_ABORTED", showsEngineErrorPage: false))
        #expect(panel.pageRecoveryPrompt == nil)
    }

    @Test func theNextLoadDismissesTheRecoveryView() throws {
        let provider = FakeProvider()
        let panel = chromiumPanel(provider)
        defer { panel.close() }
        let url = URL(string: "https://example.com/auth")!
        panel.handleEnginePageEvent(.navigationFailed(url, code: -338, message: "net::ERR_INVALID_AUTH_CREDENTIALS", showsEngineErrorPage: false))
        #expect(loadFailure(panel)?.code == -338)
        panel.handleEnginePageEvent(.stateChanged(BrowserPageState(url: url, isLoading: true)))
        #expect(panel.pageRecoveryPrompt == nil)
    }

    @Test func reloadOnTheRecoveryViewLoadsTheFailedAddressAgain() throws {
        let provider = FakeProvider()
        let panel = chromiumPanel(provider)
        defer { panel.close() }
        let page = try #require(provider.pages.first)
        let failed = URL(string: "https://example.com/auth")!
        panel.handleEnginePageEvent(.navigationFailed(failed, code: -338, message: "net::ERR_INVALID_AUTH_CREDENTIALS", showsEngineErrorPage: false))
        let prompt = try #require(panel.pageRecoveryPrompt)
        panel.performPageRecovery(prompt)
        #expect(page.loadedURLs.last == failed)
    }

    @Test func proceedIsOfferedOnlyForCertificateErrors() throws {
        let provider = FakeProvider()
        let panel = chromiumPanel(provider)
        defer { panel.close() }
        let page = try #require(provider.pages.first)
        let url = URL(string: "https://127.0.0.1:8443/")!
        panel.handleEnginePageEvent(.navigationFailed(url, code: -338, message: "net::ERR_INVALID_AUTH_CREDENTIALS", showsEngineErrorPage: false))
        #expect(!panel.canProceedPastChromiumLoadFailure)
        panel.handleEnginePageEvent(.stateChanged(BrowserPageState(url: url, isLoading: true)))
        panel.handleEnginePageEvent(.navigationFailed(url, code: -202, message: "net::ERR_CERT_AUTHORITY_INVALID", showsEngineErrorPage: false))
        #expect(panel.canProceedPastChromiumLoadFailure)
        panel.proceedPastChromiumLoadFailure()
        #expect(page.proceeded.map { $0.code } == [-202])
        #expect(page.proceeded.map { $0.url } == [url])
    }

    @Test func theAddressBarShowsTheAddressThatFailed() throws {
        let provider = FakeProvider()
        let panel = chromiumPanel(provider)
        defer { panel.close() }
        let previous = URL(string: "https://example.com/")!
        let failed = URL(string: "http://127.0.0.1:9/")!
        panel.handleEnginePageEvent(.stateChanged(BrowserPageState(url: previous)))
        #expect(panel.currentURL == previous)
        panel.handleEnginePageEvent(.stateChanged(BrowserPageState(url: previous, isLoading: true)))
        panel.handleEnginePageEvent(.navigationFailed(failed, code: -102, message: "net::ERR_CONNECTION_REFUSED", showsEngineErrorPage: true))
        #expect(panel.currentURL == failed)
        // Chromium's load ends without an address change: the failed address stays.
        panel.handleEnginePageEvent(.stateChanged(BrowserPageState(url: previous, isLoading: false)))
        #expect(panel.currentURL == failed)
    }

    // MARK: Back and Forward menus

    @Test func backAndForwardMenusListNearestEntriesFirstUpToTheLimit() throws {
        let provider = FakeProvider()
        let panel = chromiumPanel(provider)
        defer { panel.close() }
        let page = try #require(provider.pages.first)
        page.history = BrowserBackForwardList(
            back: (1...20).map { BrowserBackForwardEntry(url: URL(string: "https://example.com/\($0)"), title: "Page \($0)", offset: -$0) },
            forward: [BrowserBackForwardEntry(url: URL(string: "https://example.com/next"), title: nil, offset: 1)]
        )
        let back = panel.backForwardMenuEntries(forward: false)
        #expect(back.count == BrowserPanel.backForwardMenuLimit)
        #expect(back.first?.offset == -1)
        #expect(back.last?.offset == -BrowserPanel.backForwardMenuLimit)
        #expect(panel.backForwardMenuEntries(forward: true).map(\.offset) == [1])
        panel.goToBackForwardEntry(offset: -3)
        #expect(page.visitedOffsets == [-3])
    }

    // MARK: Reopen and Duplicate

    private func chromiumWorkspace(_ provider: FakeProvider) throws -> (Workspace, BrowserPanel, PaneID) {
        let workspace = Workspace()
        workspace.browserEngineRuntime = runtime(provider)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let url = URL(string: "https://example.com/three")!
        let panel = try #require(workspace.newBrowserSurface(inPane: paneID, url: url, focus: false, engine: .chromium))
        panel.handleEnginePageEvent(.stateChanged(BrowserPageState(url: url, canGoBack: true)))
        #expect(panel.engineKind == .chromium)
        return (workspace, panel, paneID)
    }

    @Test func duplicateTabKeepsTheChromiumEngine() throws {
        let provider = FakeProvider()
        let (workspace, panel, _) = try chromiumWorkspace(provider)
        let copy = try #require(workspace.duplicateBrowserToRight(panelId: panel.id, focus: false))
        #expect(copy.engineKind == .chromium)
        #expect(copy.enginePage != nil)
    }

    @Test func reopenClosedTabKeepsTheChromiumEngineAndHistory() throws {
        let provider = FakeProvider()
        provider.exportedState = .chromium("three entries")
        let (workspace, panel, paneID) = try chromiumWorkspace(provider)
        let tabID = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let tab = try #require(workspace.bonsplitController.tab(tabID))
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            ClosedBrowserNavigationStates.shared.removeAll()
        }
        let snapshot = try #require(workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panel.id })
        #expect(snapshot.browser?.engine == .chromium)

        workspace.markExplicitClose(surfaceId: tabID)
        #expect(workspace.splitTabBar(workspace.bonsplitController, shouldCloseTab: tab, inPane: paneID))
        workspace.splitTabBar(workspace.bonsplitController, didCloseTab: tabID, fromPane: paneID)
        #expect(workspace.panels[panel.id] == nil)

        let entry = ClosedPanelHistoryEntry(workspaceId: workspace.id, paneId: paneID.id, tabIndex: 0, snapshot: snapshot)
        let restoredID = try #require(workspace.restoreClosedPanel(entry))
        let restored = try #require(workspace.browserPanel(for: restoredID))
        #expect(restored.engineKind == .chromium)
        let page = try #require(restored.enginePage as? FakePage)
        #expect(page.restoredStates == [.chromium("three entries")])
        // The restored history replaces the plain load of the closed tab's URL.
        #expect(page.loadedURLs.isEmpty)
    }
}
