import AppKit
import CmuxBrowser
import Foundation
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An agent (socket or CLI) never loads Chromium's internal pages in a
/// Chromium panel; the person still can, and WebKit panels are unchanged.
@MainActor
final class BrowserPanelAgentURLPolicyTests: XCTestCase {
    /// A Chromium page that records what the panel asks of it.
    @MainActor
    private final class RecordingPage: BrowserPage {
        let engineKind: BrowserEngineKind = .chromium
        let capabilities: BrowserEngineCapabilities = []
        let presentation: BrowserPagePresentation = .inView
        let contentView = NSView()
        var state = BrowserPageState()
        let events: AsyncStream<BrowserPageEvent> = AsyncStream { _ in }
        weak var uiDelegate: (any BrowserPageUIDelegate)?
        var pageZoom: Double = 1
        var isDevToolsVisible = false
        var isMuted = false
        private(set) var loadedURLs: [URL] = []
        private(set) var guardStates: [Bool] = []

        func load(_ request: URLRequest) { if let url = request.url { loadedURLs.append(url) } }
        func loadHTMLString(_ html: String, baseURL: URL?) {}
        func goBack() {}
        func goForward() {}
        func reload() {}
        func reloadFromOrigin() {}
        func stop() {}
        func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? { nil }
        func callAsyncJavaScript(
            _ body: String, arguments: [String: any Sendable], in world: BrowserPageScriptWorld
        ) async throws -> Any? { nil }
        func addUserScript(_ script: BrowserPageUserScript) {}
        func removeAllUserScripts() {}
        func showDevTools() {}
        func closeDevTools() {}
        func sendDevToolsProtocolMessage(method: String, params: Data?) async throws -> Data { Data() }
        func takeSnapshot(rect: CGRect?) async throws -> NSImage { NSImage() }
        func setFocused(_ focused: Bool) -> Bool { focused }
        func setContentVisible(_ visible: Bool) {}
        func dispatchInput(_ event: BrowserPageInputEvent) async throws {}
        func exportRestoreState() -> BrowserPageRestoreState? { nil }
        func close() {}
        func setAgentNavigationGuard(_ enabled: Bool) { guardStates.append(enabled) }
    }

    @MainActor
    private final class RecordingProvider: BrowserEngineProviding {
        let kind: BrowserEngineKind = .chromium
        var availability: BrowserEngineAvailability = .available
        let capabilities: BrowserEngineCapabilities = []
        private(set) var pages: [RecordingPage] = []

        func makePage(_ configuration: BrowserPageConfiguration) throws -> any BrowserPage {
            let page = RecordingPage()
            pages.append(page)
            return page
        }
    }

    private func makeChromiumPanel() throws -> (BrowserPanel, RecordingPage) {
        let provider = RecordingProvider()
        let runtime = BrowserEngineRuntime.shared
        runtime.registry.register(provider)
        addTeardownBlock { @MainActor in
            let unavailable = RecordingProvider()
            unavailable.availability = .unavailable(.notBundled)
            runtime.registry.register(unavailable)
        }
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, fallback: nil, source: .explicit)
        )
        let page = try XCTUnwrap(provider.pages.last)
        return (panel, page)
    }

    func testAgentNavigationToInternalPagesIsRefused() throws {
        let (panel, page) = try makeChromiumPanel()
        for url in ["chrome://settings", "chrome://password-manager/passwords", "devtools://devtools/bundled/x.html",
                    "chrome-extension://abc/options.html", "view-source:https://example.com"] {
            XCTAssertTrue(panel.refusesAgentNavigation(rawInput: url, resolvedURL: URL(string: url)), url)
            _ = panel.navigateSmart(url, dialogOwner: .automation)
        }
        XCTAssertFalse(page.loadedURLs.contains { $0.absoluteString.isRefusedForAgentNavigation }, "\(page.loadedURLs)")
    }

    func testAgentMayOpenOrdinaryPages() throws {
        let (panel, page) = try makeChromiumPanel()
        XCTAssertFalse(panel.refusesAgentNavigation(rawInput: "https://example.com", resolvedURL: URL(string: "https://example.com")))
        _ = panel.navigateSmart("https://example.com/agent", dialogOwner: .automation)
        XCTAssertEqual(page.loadedURLs.last?.absoluteString, "https://example.com/agent")
    }

    func testEngineGuardFollowsWhoDrivesThePanel() throws {
        let (panel, page) = try makeChromiumPanel()
        panel.takeBrowserDialogOwnership(.automation)
        panel.takeBrowserDialogOwnership(.user)
        XCTAssertEqual(page.guardStates.suffix(2), [true, false])
    }

    func testWebKitPanelsAreUnchanged() {
        let panel = BrowserPanel(workspaceId: UUID())
        XCTAssertFalse(panel.refusesAgentNavigation(rawInput: "chrome://settings", resolvedURL: nil))
        XCTAssertTrue(panel.agentMayDriveCurrentPage)
    }
}
