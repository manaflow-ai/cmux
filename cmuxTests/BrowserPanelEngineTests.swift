import AppKit
import CmuxBrowser
import Foundation
import Testing
import WebKit

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
    final class FakeChromiumPage: BrowserPage, BrowserPagePlaceholderColoring, BrowserExtensionHostProviding {
        var placeholderColor: NSColor = .clear
        var extensionHost: (any BrowserExtensionHosting)?
        private(set) var evaluatedScripts: [String] = []
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
        private(set) var userScripts: [BrowserPageUserScript] = []
        private(set) var backCount = 0
        private(set) var stopCount = 0
        private(set) var closeCount = 0
        private(set) var focusChanges: [Bool] = []
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
        func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? {
            evaluatedScripts.append(script)
            return nil
        }
        func callAsyncJavaScript(_ body: String, arguments: [String: any Sendable], in world: BrowserPageScriptWorld) async throws -> Any? { nil }
        func addUserScript(_ script: BrowserPageUserScript) { userScripts.append(script) }
        func removeAllUserScripts() {}
        func showDevTools() {}
        func closeDevTools() {}
        func sendDevToolsProtocolMessage(method: String, params: Data?) async throws -> Data { Data("{}".utf8) }
        func takeSnapshot(rect: CGRect?) async throws -> NSImage { NSImage() }
        func setFocused(_ focused: Bool) -> Bool {
            focusChanges.append(focused)
            return true
        }
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

    @MainActor
    final class FakeExtensionBackend: BrowserExtensionBackend {
        var supportsManagement: Bool { true }
        var commands: [BrowserExtensionCommand] = []
        private(set) var ranCommands: [String] = []
        func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])? { ([], commands) }
        func setEnabled(_ id: String, _ enabled: Bool) -> Bool { false }
        func uninstall(_ id: String) -> Bool { false }
        func reload(_ id: String) -> Bool { false }
        func setPinned(_ id: String, _ pinned: Bool) -> Bool { false }
        func openOptions(_ id: String, from tab: (any BrowserExtensionTab)?) -> Bool { false }
        func loadUnpacked(at path: String) -> Bool { false }
        func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserExtensionTab) -> Bool {
            ranCommands.append(command.name)
            return true
        }
    }

    @MainActor
    final class FakeExtensionHost: BrowserExtensionHosting, BrowserExtensionTab {
        let extensionStore: BrowserExtensionStore
        var extensionTab: any BrowserExtensionTab { self }
        var extensionActions: [BrowserExtensionAction] { [] }
        var openExtensionPopup: String? { nil }
        var extensionActionRequestHandler: (@MainActor (String) -> Void)?
        private(set) var requestedActions: [String] = []

        init(backend: FakeExtensionBackend) {
            extensionStore = BrowserExtensionStore(profileID: UUID(), backend: backend)
            extensionStore.refresh()
        }

        func runExtensionAction(_ id: String, anchor: CGRect) -> Bool { true }
        func hideExtensionPopup() {}
        func refreshExtensionActions() {}
        func showExtensionActionMenu(_ id: String, atScreenPoint point: CGPoint) {}
        func requestExtensionAction(_ extensionID: String) { requestedActions.append(extensionID) }
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

    @Test func leavingChromiumPanelReleasesPageFocus() throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        let page = try #require(provider.pages.first)

        panel.focus()
        panel.unfocus()

        #expect(page.focusChanges == [true, false])
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
        #expect(second.engineFallbackReason == .notBundled)
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
        // Chromium telemetry must be registered before the initial navigation;
        // installing it from console.list/errors.list loses page-load entries.
        let telemetryScript = try #require(page.userScripts.first {
            $0.source.contains("__cmuxHooksInstalled")
        })
        #expect(telemetryScript.injectionTime == .documentStart)
        #expect(telemetryScript.isMainFrameOnly)
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

        #expect(panel.activeEngineKind == .webkit)
        #expect(panel.engineKind == .chromium)
        #expect(panel.enginePage == nil)
        #expect(page.closeCount == 1)
        #expect(panel.engineFallbackNotice == .startFailed("NSApp does not conform to CefAppProtocol"))
        #expect(panel.engineFallbackReason == .startFailed("NSApp does not conform to CefAppProtocol"))
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

    @Test func chromiumPageOpensOnTheThemeColor() throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        let page = try #require(provider.pages.first)
        #expect(page.placeholderColor == GhosttyBackgroundTheme.currentColor())
    }

    @Test func automationHistoryStepsExactlyOneChromiumEntry() throws {
        let history = Data("""
        {"currentIndex": 3, "entries": [{"id": 10}, {"id": 11}, {"id": 12}, {"id": 13}, {"id": 14}]}
        """.utf8)
        #expect(BrowserPanel.historyEntryID(in: history, offset: -1) == 12)
        #expect(BrowserPanel.historyEntryID(in: history, offset: 1) == 14)
        #expect(BrowserPanel.historyEntryID(in: history, offset: 2) == nil)
        #expect(BrowserPanel.historyEntryID(in: Data("{}".utf8), offset: -1) == nil)
    }

    @Test func personBackUsesTheEnginesOwnBack() throws {
        let provider = FakeChromiumProvider()
        provider.initialState = BrowserPageState(url: URL(string: "https://example.com/"), canGoBack: true)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        panel.goBack(dialogOwner: .user)
        #expect(try #require(provider.pages.first).backCount == 1)
    }

    @Test func automationNavigationCompletesWhenTheChromiumLoadCommits() async throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        let url = URL(string: "https://example.com/next")!
        let ticket = panel.beginAutomationNavigation(to: url, recordTypedNavigation: false)
        #expect(try #require(provider.pages.first).loadedURLs.last == url)
        panel.handleEnginePageEvent(.navigationCommitted(url))
        let outcome = await panel.automationNavigationCoordinator.wait(for: ticket)
        #expect(outcome == .committed)
    }

    @Test func automationNavigationReportsAChromiumLoadFailure() async throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        let url = URL(string: "https://nope.invalid/")!
        let ticket = panel.beginAutomationNavigation(to: url, recordTypedNavigation: false)
        panel.handleEnginePageEvent(.navigationFailed(url, code: -105, message: "NAME_NOT_RESOLVED", showsEngineErrorPage: true))
        let outcome = await panel.automationNavigationCoordinator.wait(for: ticket)
        #expect(outcome == .failed("navigation failed"))
    }

    @Test func anAbortedEarlierLoadDoesNotFailAutomationsReload() async throws {
        let provider = FakeChromiumProvider()
        let url = URL(string: "https://example.com/")!
        provider.initialState = BrowserPageState(url: url)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        let reload = try #require(panel.beginAutomationReloadFromCLI())
        panel.handleEnginePageEvent(.navigationFailed(url, code: -3, message: "ERR_ABORTED", showsEngineErrorPage: false))
        panel.handleEnginePageEvent(.navigationCommitted(url))
        let outcome = await panel.automationNavigationCoordinator.wait(for: reload.ticket)
        #expect(outcome == .committed)
    }

    @Test func restoredChromiumPanelLoadsItsPage() throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .inherited),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        var snapshot = SessionBrowserPanelSnapshot(
            urlString: "https://example.com/restored", profileID: nil, shouldRenderWebView: true,
            pageZoom: 1, developerToolsVisible: false,
            backHistoryURLStrings: nil, forwardHistoryURLStrings: nil
        )
        snapshot.engine = .chromium
        panel.restoreSessionSnapshot(snapshot)
        #expect(try #require(provider.pages.first).loadedURLs == [URL(string: "https://example.com/restored")!])
    }

    @Test func webKitPopupStaysWebKitWhenChromiumIsConfigured() {
        let provider = FakeChromiumProvider()
        let url = URL(string: "https://example.com/popup")!
        let popupWebView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration(), host: CmuxWebViewAppHost())
        BrowserPanel.pendingPopupWebView = (url: url, webView: popupWebView)
        defer { BrowserPanel.pendingPopupWebView = nil }
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            engineRuntime: runtime(providers: [provider], environment: ["CMUX_BROWSER_ENGINE": "chromium"])
        )
        defer { panel.close() }
        #expect(panel.engineKind == .webkit)
        #expect(panel.webView === popupWebView)
        #expect(provider.pages.isEmpty)
    }

    @Test func cloudRoutingMovesAChromiumPanelToWebKit() throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        panel.cloudBrowserMachineID = "vm-test"
        _ = panel.navigate(to: URL(string: "https://example.com/")!)
        #expect(panel.activeEngineKind == .webkit)
        #expect(try #require(provider.pages.first).closeCount == 1)
        #expect(try #require(provider.pages.first).loadedURLs.isEmpty)
        #expect(panel.engineFallbackNotice == nil)
    }

    @Test func automationBackWaitsForTheChromiumCommit() async throws {
        let provider = FakeChromiumProvider()
        provider.initialState = BrowserPageState(url: URL(string: "https://example.com/b"), canGoBack: true)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        let step = try #require(panel.beginEngineHistoryNavigationForAutomation(offset: -1))
        #expect(panel.beginEngineHistoryNavigationForAutomation(offset: 1) == nil)
        panel.handleEnginePageEvent(.navigationCommitted(URL(string: "https://example.com/a")))
        let outcome = await panel.automationNavigationCoordinator.wait(for: step.ticket)
        #expect(outcome == .committed)
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

    /// A Chromium panel whose page sits in a shown window, as a pane shows it.
    private func shownChromiumPanel(
        _ provider: FakeChromiumProvider
    ) throws -> (panel: BrowserPanel, page: FakeChromiumPage, window: NSWindow) {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com/"),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        let page = try #require(provider.pages.first)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        page.contentView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(page.contentView)
        window.orderBack(nil)
        return (panel, page, window)
    }

    private func escape(at timestamp: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
    }

    /// Browser focus mode works for a Chromium page as for a WebKit one: it
    /// enters with the page focused, and a double Escape leaves it. The
    /// Chromium page draws in a child window, so the panel's WebKit view is
    /// never in a window (it was the only view focus mode checked).
    @Test func chromiumPanelEntersFocusModeAndDoubleEscapeLeavesIt() throws {
        let provider = FakeChromiumProvider()
        let (panel, page, window) = try shownChromiumPanel(provider)
        defer { panel.close(); window.close() }

        #expect(panel.canEnterBrowserFocusMode)
        #expect(panel.setBrowserFocusModeActive(true, reason: "unit.chromium", focusWebView: true))
        #expect(panel.isBrowserFocusModeActive)
        #expect(page.focusChanges.last == true)

        let start = ProcessInfo.processInfo.systemUptime
        #expect(panel.handleBrowserFocusModeKeyEvent(try escape(at: start), reason: "unit.first") == .forwardToWebView)
        #expect(panel.isBrowserFocusModeActive)
        #expect(panel.handleBrowserFocusModeKeyEvent(try escape(at: start + 0.05), reason: "unit.second") == .consume)
        #expect(!panel.isBrowserFocusModeActive)
    }

    /// A `chrome.commands` shortcut runs for the focused Chromium panel (the
    /// shortcut monitor calls this for a key no cmux shortcut took), and not
    /// in browser focus mode, where every key is the page's.
    @Test func extensionShortcutRunsInAChromiumPanelExceptInFocusMode() throws {
        let provider = FakeChromiumProvider()
        let (panel, page, window) = try shownChromiumPanel(provider)
        defer { panel.close(); window.close() }
        let backend = FakeExtensionBackend()
        backend.commands = [BrowserExtensionCommand(extensionID: "ext", name: "_execute_action", keyCode: 0x59, modifiers: 16 | 2)]
        let host = FakeExtensionHost(backend: backend)
        page.extensionHost = host
        let commandShiftY = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "Y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16
        ))

        #expect(panel.runExtensionShortcut(for: commandShiftY))
        #expect(host.requestedActions == ["ext"])

        #expect(panel.setBrowserFocusModeActive(true, reason: "unit.extensionShortcut", focusWebView: true))
        #expect(!panel.runExtensionShortcut(for: commandShiftY))
        #expect(host.requestedActions == ["ext"])
    }

    @Test func webKitPanelHasNoExtensionShortcuts() throws {
        let panel = BrowserPanel(workspaceId: UUID(), engineRuntime: runtime())
        defer { panel.close() }
        let commandShiftY = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "Y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16
        ))
        #expect(!panel.runExtensionShortcut(for: commandShiftY))
    }

    /// Cmd-L then Escape: the address bar's page-focus scripts run in the
    /// Chromium page (not the panel's unused WebKit view), and leaving the
    /// address bar gives the page the keyboard back.
    @Test func leavingTheAddressBarReturnsTheKeyboardToTheChromiumPage() async throws {
        let provider = FakeChromiumProvider()
        let (panel, page, window) = try shownChromiumPanel(provider)
        defer { panel.close(); window.close() }

        let adapter = BrowserOmnibarPageFocusAdapter(panel: panel)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.evaluateOmnibarPageFocusScript("probe()") { _, _ in continuation.resume() }
        }
        #expect(page.evaluatedScripts.last == "probe()")

        let focusesBefore = page.focusChanges.count
        let scriptsBefore = page.evaluatedScripts.count
        var returned = false
        // Completes after the previously focused field's restore ran in the page.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            returned = panel.returnFocusToEnginePageAfterAddressBar { continuation.resume() }
            if !returned { continuation.resume() }
        }
        #expect(returned)
        #expect(page.focusChanges.count == focusesBefore + 1)
        #expect(page.focusChanges.last == true)
        #expect(page.evaluatedScripts.count > scriptsBefore)
    }

    @Test func webKitPanelLeavesTheAddressBarThroughWebKit() {
        let panel = BrowserPanel(workspaceId: UUID(), engineRuntime: runtime())
        defer { panel.close() }
        #expect(!panel.returnFocusToEnginePageAfterAddressBar {})
    }
}
