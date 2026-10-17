import AppKit
import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Page features of a Chromium panel that WebKit panels get from WebKit itself:
/// docked DevTools keeping the keyboard, content fullscreen, find across
/// navigations and links to other apps.
@MainActor
@Suite(.serialized) struct BrowserPanelEnginePageFeatureTests {
    /// Records native find calls and answers each at once with one match.
    @MainActor
    final class FindDriver: BrowserNativeFindDriving {
        struct Call: Equatable {
            let text: String
            let forward: Bool
            let findNext: Bool
        }

        weak var session: BrowserNativeFindSession?
        private(set) var calls: [Call] = []
        let issued: AsyncStream<Call>
        private let issuedContinuation: AsyncStream<Call>.Continuation

        init() {
            (issued, issuedContinuation) = AsyncStream.makeStream()
        }

        func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool) -> Bool {
            let call = Call(text: text, forward: forward, findNext: findNext)
            calls.append(call)
            // Answer after the session stored its pending request.
            Task { @MainActor [weak self] in
                self?.session?.receiveResult(count: 1, activeOrdinal: 1, isFinal: true)
                self?.issuedContinuation.yield(call)
            }
            return true
        }

        func stopFinding(clearSelection: Bool) {}
    }

    @MainActor
    final class Page: BrowserPage, BrowserPageDevToolsHosting, BrowserPageNativeFinding {
        var engineKind: BrowserEngineKind { .chromium }
        var capabilities: BrowserEngineCapabilities { [.devToolsProtocol] }
        var presentation: BrowserPagePresentation { .childWindow }
        let contentView = NSView(frame: .zero)
        var state = BrowserPageState()
        weak var uiDelegate: (any BrowserPageUIDelegate)?
        var pageZoom: Double = 1
        var isDevToolsVisible: Bool { devToolsState.isOpen }
        var isMuted = false
        var devToolsState = BrowserDevToolsState()
        let findDriver = FindDriver()
        let nativeFind: BrowserNativeFindSession
        private(set) var focusChanges: [Bool] = []
        private(set) var devToolsFocusChanges: [Bool] = []
        private(set) var evaluatedScripts: [String] = []
        private let stream: AsyncStream<BrowserPageEvent>
        private let continuation: AsyncStream<BrowserPageEvent>.Continuation

        init() {
            (stream, continuation) = AsyncStream<BrowserPageEvent>.makeStream()
            nativeFind = BrowserNativeFindSession(driver: findDriver)
            findDriver.session = nativeFind
        }

        var events: AsyncStream<BrowserPageEvent> { stream }

        private(set) var loadedURLs: [URL] = []

        func load(_ request: URLRequest) { request.url.map { loadedURLs.append($0) } }
        func loadHTMLString(_ html: String, baseURL: URL?) {}
        func goBack() {}
        func goForward() {}
        func reload() {}
        func reloadFromOrigin() {}
        func stop() {}
        func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? {
            evaluatedScripts.append(script)
            return nil
        }
        func callAsyncJavaScript(_ body: String, arguments: [String: any Sendable], in world: BrowserPageScriptWorld) async throws -> Any? { nil }
        func addUserScript(_ script: BrowserPageUserScript) {}
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
        func close() { continuation.finish() }

        func performDevTools(_ command: BrowserDevToolsCommand) {}
        func setDevToolsFocused(_ focused: Bool) { devToolsFocusChanges.append(focused) }
        func devToolsContains(window: NSWindow) -> Bool { false }
    }

    @MainActor
    final class Provider: BrowserEngineProviding {
        let kind = BrowserEngineKind.chromium
        var availability = BrowserEngineAvailability.available
        let capabilities: BrowserEngineCapabilities = [.devToolsProtocol]
        private(set) var pages: [Page] = []

        func makePage(_ configuration: BrowserPageConfiguration) throws -> any BrowserPage {
            let page = Page()
            pages.append(page)
            return page
        }
    }

    private func makePanel() throws -> (BrowserPanel, Page) {
        let provider = Provider()
        let runtime = BrowserEngineRuntime(
            registry: BrowserEngineRegistry(providers: [provider]),
            environment: [:],
            defaults: UserDefaults(suiteName: "BrowserPanelEnginePageFeatureTests.\(UUID().uuidString)")!
        )
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: runtime
        )
        return (panel, try #require(provider.pages.first))
    }

    // MARK: DevTools keyboard

    @Test func clickedDevToolsKeepTheKeyboardWhenThePanelIsFocusedAgain() throws {
        let (panel, page) = try makePanel()
        defer { panel.close() }
        page.devToolsState = BrowserDevToolsState(isOpen: true)

        // A click into docked DevTools: every later panel focus (SwiftUI
        // updates, pane focus) goes to the tools, not the page.
        panel.noteEngineDevToolsTookKeyboard()
        panel.focus()
        panel.focus()
        #expect(page.focusChanges.isEmpty)
        #expect(page.devToolsFocusChanges.allSatisfy { $0 })
        #expect(!page.devToolsFocusChanges.isEmpty)

        // A click into the page chooses it again.
        panel.noteEnginePageChosen()
        panel.focus()
        #expect(page.focusChanges == [true])
    }

    @Test func closedDevToolsGiveTheKeyboardBackToThePage() throws {
        let (panel, page) = try makePanel()
        defer { panel.close() }
        page.devToolsState = BrowserDevToolsState(isOpen: true)
        panel.noteEngineDevToolsTookKeyboard()

        page.devToolsState = BrowserDevToolsState(isOpen: false)
        panel.handleEnginePageEvent(.devToolsVisibilityChanged(false))
        panel.focus()
        #expect(page.focusChanges == [true])
    }

    // MARK: Content fullscreen

    @Test func contentFullscreenHidesTheChromeWithoutChangingTheSavedPolicy() throws {
        let (panel, _) = try makePanel()
        defer { panel.close() }
        #expect(panel.chromeState.isOmnibarVisible)

        panel.handleEnginePageEvent(.contentFullscreenChanged(true))
        #expect(!panel.chromeState.isOmnibarVisible)
        // Session snapshots and the command palette read the saved policy.
        #expect(panel.isOmnibarVisible)

        panel.handleEnginePageEvent(.contentFullscreenChanged(false))
        #expect(panel.chromeState.isOmnibarVisible)
    }

    // MARK: Find across navigations

    @Test func findKeepsWorkingAfterTheChromiumPageNavigates() async throws {
        let (panel, page) = try makePanel()
        defer { panel.close() }
        var issued = page.findDriver.issued.makeAsyncIterator()

        panel.startFind()
        panel.searchState?.needle = "cmux"
        #expect(await issued.next() == .init(text: "cmux", forward: true, findNext: false))

        // A new document: the CEF page resets its find session at load start.
        page.nativeFind.resetForNewDocument()
        let url = URL(string: "https://example.com/next")!
        panel.handleEnginePageEvent(.navigationCommitted(url))
        panel.handleEnginePageEvent(.navigationFinished(url))
        // The find bar's query runs again on the new document, as in WebKit.
        #expect(await issued.next() == .init(text: "cmux", forward: true, findNext: false))

        // Cmd-G steps through the new document's matches.
        panel.findNext()
        #expect(await issued.next() == .init(text: "cmux", forward: true, findNext: true))
        #expect(panel.searchState?.needle == "cmux")
    }

    // MARK: Links to other apps

    @Test func aChromiumLinkToAnotherAppAsksBeforeOpeningIt() throws {
        let (panel, page) = try makePanel()
        defer { panel.close() }
        var prompts: [String] = []
        panel.engineExternalAppAlertPresenter = { alert, _, completion, _ in
            prompts.append(alert.messageText)
            // Stay in Browser.
            completion(.alertSecondButtonReturn)
        }

        panel.handleEnginePageEvent(.externalAppRequested(URL(string: "mailto:someone@example.com")!, userGesture: true))
        // As in WebKit, the confirmation is the gate, gesture or not.
        panel.handleEnginePageEvent(.externalAppRequested(URL(string: "zoommtg://zoom.us/join?confno=1")!, userGesture: false))

        let title = String(localized: "browser.externalOpenPrompt.title", defaultValue: "Open External App?")
        #expect(prompts == [title, title])
        #expect(page.loadedURLs.isEmpty)
    }

    @Test func aChromiumIntentLinkLoadsItsWebFallbackInThePane() throws {
        let (panel, page) = try makePanel()
        defer { panel.close() }
        var prompts = 0
        panel.engineExternalAppAlertPresenter = { _, _, completion, _ in
            prompts += 1
            completion(.alertSecondButtonReturn)
        }
        let intent = URL(string: "intent://scan/#Intent;scheme=zxing;S.browser_fallback_url=https%3A%2F%2Fexample.com%2Ffallback;end")!

        panel.handleEnginePageEvent(.externalAppRequested(intent, userGesture: true))

        #expect(prompts == 0)
        #expect(page.loadedURLs.last == URL(string: "https://example.com/fallback"))
    }

    // MARK: beforeunload

    @Test func leavingAPageWithUnsavedChangesUsesChromesWording() {
        let leave = BrowserPanel.engineJavaScriptDialogText(for: .beforeUnload(isReload: false), message: "ignored")
        #expect(leave.title == String(localized: "browser.beforeUnload.leave.title", defaultValue: "Leave site?"))
        #expect(leave.ok == String(localized: "browser.beforeUnload.leave", defaultValue: "Leave"))
        #expect(leave.message == String(
            localized: "browser.beforeUnload.message", defaultValue: "Changes you made may not be saved."
        ))
        let reload = BrowserPanel.engineJavaScriptDialogText(for: .beforeUnload(isReload: true), message: "ignored")
        #expect(reload.title == String(localized: "browser.beforeUnload.reload.title", defaultValue: "Reload site?"))
        #expect(reload.ok == String(localized: "browser.reload", defaultValue: "Reload"))
        let confirm = BrowserPanel.engineJavaScriptDialogText(for: .confirm, message: "Sure?")
        #expect(confirm.title == nil)
        #expect(confirm.message == "Sure?")
        #expect(confirm.ok == String(localized: "common.ok", defaultValue: "OK"))
    }
}
