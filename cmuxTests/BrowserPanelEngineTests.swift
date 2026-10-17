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
    final class FakeChromiumPage: BrowserPage, BrowserPagePlaceholderColoring {
        var placeholderColor: NSColor = .clear
        var engineKind: BrowserEngineKind { .chromium }
        var capabilities: BrowserEngineCapabilities = [.devToolsProtocol]
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
        private(set) var agentDrivenMarks = 0
        /// What the next `markAgentDriven` answers (a live page reopened).
        var reopensWhenMarked = false
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
        func markAgentDriven() -> Bool {
            agentDrivenMarks += 1
            defer { reopensWhenMarked = false }
            return reopensWhenMarked
        }
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

    /// A Chromium tab shows the speaker while its page plays sound, as a
    /// WebKit tab does, and Mute Tab mutes the Chromium page itself.
    @Test func chromiumMediaReportsDriveTheTabAudioIndicator() throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        #expect(!panel.isPlayingAudio)

        panel.handleEnginePageEvent(.mediaPlaybackReported(
            BrowserMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: true)
        ))
        #expect(panel.isPlayingMedia)
        #expect(panel.isPlayingAudio)

        // A new main-frame document replaces the frames that reported.
        panel.handleEnginePageEvent(.mediaPlaybackReset)
        #expect(!panel.isPlayingMedia)
        #expect(!panel.isPlayingAudio)
    }

    @Test func muteTabMutesTheChromiumPage() throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        let page = try #require(provider.pages.first)
        page.capabilities.insert(.mediaMuting)
        panel.handleEnginePageEvent(.mediaPlaybackReported(
            BrowserMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: true)
        ))

        #expect(panel.setMuted(true))
        #expect(page.isMuted)
        #expect(panel.isMuted)
        #expect(!panel.isPlayingAudio)

        #expect(panel.toggleMute())
        #expect(!page.isMuted)
        #expect(panel.isPlayingAudio)
    }

    @Test func aChromiumPageThatCannotMuteRefusesMuteTab() throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        #expect(!panel.setMuted(true))
        #expect(!panel.isMuted)
    }

    // MARK: Passwords (agent-driven fill off, save offers in the strip)

    private func chromiumPanel() throws -> (BrowserPanel, FakeChromiumPage) {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        return (panel, try #require(provider.pages.first))
    }

    private let fixtureOffer = BrowserPagePasswordSaveOffer(
        id: 3, origin: URL(string: "http://localhost:19250/login")!, username: "fixture-user", isUpdate: false
    )

    /// Waits (bounded) until the strip shows a question.
    private func currentPrompt(_ panel: BrowserPanel) async -> BrowserPermissionPrompt? {
        for _ in 0..<100 {
            if let prompt = panel.enginePageDelegate.permissionQueue.current { return prompt }
            await Task.yield()
        }
        return nil
    }

    @Test func automationTurnsPasswordFillOffForGood() throws {
        let (panel, page) = try chromiumPanel()
        defer { panel.close() }
        #expect(!panel.isAgentDriven)
        #expect(page.agentDrivenMarks == 0)

        panel.takeBrowserDialogOwnership(.automation)
        #expect(panel.isAgentDriven)
        #expect(page.agentDrivenMarks > 0)

        // Physical input takes the dialogs back; filling stays off.
        panel.takeBrowserDialogOwnership(.user)
        #expect(panel.isAgentDriven)
    }

    @Test func aPanelAutomationOpenedInTheBackgroundStartsAgentDriven() throws {
        let provider = FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            preloadInitialNavigationInBackground: true,
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime(providers: [provider])
        )
        defer { panel.close() }
        #expect(panel.isAgentDriven)
        #expect(try #require(provider.pages.first).agentDrivenMarks > 0)
    }

    @Test func aReopenedPageAsksTheAgentToRetryOnce() throws {
        let (panel, page) = try chromiumPanel()
        defer { panel.close() }
        page.reopensWhenMarked = true
        #expect(panel.markAgentDriven())
        #expect(panel.takeAgentReopenNotice())
        #expect(!panel.takeAgentReopenNotice())
    }

    @Test func passwordOfferWaitsInTheStripThroughNavigation() async throws {
        let (panel, page) = try chromiumPanel()
        defer { panel.close() }
        let delegate = panel.enginePageDelegate
        let offer = fixtureOffer
        let answer = Task { await delegate.page(page, offerToSavePassword: offer) }

        let prompt = try #require(await currentPrompt(panel))
        #expect(prompt.isPasswordPrompt)
        #expect(prompt.variant == .savePassword(username: "fixture-user", isUpdate: false))
        // Chromium asks after the sign-in navigated; the next load keeps it.
        panel.handleEnginePageEvent(.navigationStarted(URL(string: "http://localhost:19250/welcome")))
        #expect(delegate.permissionQueue.current?.id == prompt.id)

        delegate.permissionQueue.answer(prompt.id, with: .allowAndRemember)
        #expect(await answer.value == .save)
    }

    @Test func aPasswordOfferChromiumDroppedLeavesTheStrip() async throws {
        let (panel, page) = try chromiumPanel()
        defer { panel.close() }
        let delegate = panel.enginePageDelegate
        let offer = fixtureOffer
        let answer = Task { await delegate.page(page, offerToSavePassword: offer) }
        _ = try #require(await currentPrompt(panel))

        delegate.page(page, didEndPasswordSaveOffer: offer.id)
        #expect(await answer.value == nil)
        #expect(delegate.permissionQueue.current == nil)
    }

    @Test func anAgentDrivenPanelIsNeverAskedToSaveAPassword() async throws {
        let (panel, page) = try chromiumPanel()
        defer { panel.close() }
        panel.takeBrowserDialogOwnership(.automation)
        let answer = await panel.enginePageDelegate.page(page, offerToSavePassword: fixtureOffer)
        #expect(answer == .notNow)
        #expect(panel.enginePageDelegate.permissionQueue.current == nil)
    }

    @Test func stripButtonsMapToChromiumAnswers() {
        #expect(BrowserPanelEnginePageDelegate.passwordSaveAnswer(.allowAndRemember) == .save)
        #expect(BrowserPanelEnginePageDelegate.passwordSaveAnswer(.block) == .never)
        #expect(BrowserPanelEnginePageDelegate.passwordSaveAnswer(.notNow) == .notNow)
        #expect(BrowserPanelEnginePageDelegate.passwordSaveAnswer(nil) == nil)
    }
}
