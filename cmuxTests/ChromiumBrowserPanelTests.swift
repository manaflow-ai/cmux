import AppKit
import CmuxBrowser
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Chromium pane integration")
struct ChromiumBrowserPanelTests {
    @Test("Startup failure switches the pane to WebKit and ignores late Chromium state")
    func startupFallback() throws {
        let url = try #require(URL(string: "about:blank"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            renderInitialNavigation: false,
            engine: .chromium
        )
        defer { panel.close() }
        #expect(panel.isChromiumBacked)
        let originalWebView = panel.webView
        panel.applyChromiumSnapshot(.init(state: .failed("runtime missing")))
        #expect(panel.engineKind == .webkit)
        #expect(panel.browserEngineController.kind == .webkit)
        #expect(panel.webView === originalWebView)
        #expect(panel.currentURL == url)
        #expect(panel.chromiumSessionForAutomation == nil)
        #expect(panel.chromiumContentView == nil)
        panel.applyChromiumSnapshot(.init(state: .crashed(9), title: "stale title"))
        #expect(panel.pageTitle != "stale title")
        #expect(!panel.hasRecoverableWebContentTermination)
    }

    @Test("Ephemeral sessions preserve WebKit's nonpersistent store")
    func ephemeralSession() {
        let store = WKWebsiteDataStore.nonPersistent()
        let panel = BrowserPanel(workspaceId: UUID(), engine: .chromium, websiteDataStore: store)
        defer { panel.close() }
        #expect(panel.engineKind == .webkit)
        #expect(panel.webView.configuration.websiteDataStore === store)
    }

    @Test("Native key mapping preserves physical identity and valid CDP modifiers")
    func nativeKeyMapping() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift, .capsLock],
            timestamp: 0, windowNumber: 0, context: nil, characters: "!",
            charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        let mapping = ChromiumKeyMapping().map(event)
        #expect(mapping.key == "!")
        #expect(mapping.code == "Digit1")
        #expect(mapping.text == "!")
        #expect(mapping.modifiers == 8)
    }
}
