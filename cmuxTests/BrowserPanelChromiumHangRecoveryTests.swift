import AppKit
import CmuxBrowser
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A hung Chromium page (JS infinite loop) recovers: the probe finds the hang
/// without input, the card shows, and a reload or navigation ends the
/// renderer and then runs in a new one.
@MainActor
final class BrowserPanelChromiumHangRecoveryTests: XCTestCase {
    @MainActor
    private final class ScriptablePage: BrowserPage {
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
        /// A hung page never answers a script.
        var isHung = false
        private(set) var reloads = 0
        private(set) var loads: [URL] = []
        private(set) var hangAnswers: [Bool] = []

        func load(_ request: URLRequest) { if let url = request.url { loads.append(url) } }
        func loadHTMLString(_ html: String, baseURL: URL?) {}
        func goBack() {}
        func goForward() {}
        func reload() { reloads += 1 }
        func reloadFromOrigin() { reloads += 1 }
        func stop() {}
        func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? {
            if isHung { try await Task.sleep(for: .seconds(30)) }
            return 1
        }
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
        func answerUnresponsive(terminate: Bool) { hangAnswers.append(terminate) }
    }

    @MainActor
    private final class Provider: BrowserEngineProviding {
        let kind: BrowserEngineKind = .chromium
        var availability: BrowserEngineAvailability = .available
        let capabilities: BrowserEngineCapabilities = []
        private(set) var pages: [ScriptablePage] = []

        func makePage(_ configuration: BrowserPageConfiguration) throws -> any BrowserPage {
            let page = ScriptablePage()
            pages.append(page)
            return page
        }
    }

    private func makePanel() throws -> (BrowserPanel, ScriptablePage) {
        let provider = Provider()
        let runtime = BrowserEngineRuntime.shared
        runtime.registry.register(provider)
        addTeardownBlock { @MainActor in
            let unavailable = Provider()
            unavailable.availability = .unavailable(.notBundled)
            runtime.registry.register(unavailable)
        }
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, fallback: nil, source: .explicit)
        )
        // On screen, as a pane the person looks at.
        panel.noteEnginePageVisibility(true)
        return (panel, try XCTUnwrap(provider.pages.last))
    }

    private let renderedEnd = BrowserPageEvent.processTerminated(BrowserPageProcessExit(kind: .killed, status: 9))

    func testProbeShowsTheCardWithoutEndingTheRenderer() async throws {
        let (panel, page) = try makePanel()
        page.isHung = true

        panel.probeChromiumResponsiveness(timeout: .milliseconds(50))
        await panel.chromiumHangProbeTask?.value

        XCTAssertEqual(panel.pageRecoveryPromptName, "unresponsive")
        XCTAssertEqual(page.hangAnswers, [], "a busy page or a Leave-site dialog is never ended by the probe alone")
    }

    func testSecondReloadOnTheCardEndsTheRendererAndReloads() async throws {
        let (panel, page) = try makePanel()
        page.isHung = true
        panel.probeChromiumResponsiveness(timeout: .milliseconds(50))
        await panel.chromiumHangProbeTask?.value

        panel.reloadEnginePageRecoveringHang(fromOrigin: false)
        XCTAssertEqual(page.hangAnswers, [true], "the hung renderer is ended")
        // The fake page has no renderer process to end, so the reload runs at once.
        XCTAssertEqual(page.reloads, 1)
        XCTAssertNil(panel.chromiumPageFailure.failure)
    }

    func testNewDocumentDuringTheProbeKeepsTheCardAway() async throws {
        let (panel, page) = try makePanel()
        page.isHung = true
        panel.probeChromiumResponsiveness(timeout: .milliseconds(200))
        panel.noteEnginePageSafetyEvent(.navigationStarted(URL(string: "https://example.com/next")))
        await panel.chromiumHangProbeTask?.value
        XCTAssertNil(panel.chromiumPageFailure.failure)
    }

    func testResponsivePageIsLeftAlone() async throws {
        let (panel, page) = try makePanel()
        panel.probeChromiumResponsiveness(timeout: .seconds(5))
        await panel.chromiumHangProbeTask?.value
        XCTAssertNil(panel.chromiumPageFailure.failure)
        XCTAssertEqual(page.hangAnswers, [])
    }

    func testNavigationWhileTheCardShowsEndsTheRendererFirst() throws {
        let (panel, page) = try makePanel()
        panel.noteEnginePageSafetyEvent(.unresponsiveChanged(true))
        let target = try XCTUnwrap(URL(string: "https://example.com/next"))

        panel.loadEnginePageRecoveringHang(URLRequest(url: target))
        XCTAssertEqual(page.hangAnswers, [true])
        XCTAssertEqual(page.loads, [target])
        XCTAssertNil(panel.pendingChromiumHangRecovery)
    }

    func testStalePendingRecoveryIsDroppedWhenThePageMovesOn() throws {
        let (panel, _) = try makePanel()
        panel.noteEnginePageSafetyEvent(.unresponsiveChanged(true))
        panel.exitUnresponsiveChromiumPage()
        XCTAssertEqual(panel.pendingChromiumHangRecovery, .showCrashPage)
        panel.noteEnginePageSafetyEvent(.unresponsiveChanged(false))
        XCTAssertNil(panel.pendingChromiumHangRecovery)
    }

    func testExitPageShowsTheCrashPage() throws {
        let (panel, page) = try makePanel()
        panel.noteEnginePageSafetyEvent(.unresponsiveChanged(true))
        panel.exitUnresponsiveChromiumPage()
        XCTAssertEqual(page.hangAnswers, [true])
        panel.noteEnginePageSafetyEvent(renderedEnd)
        XCTAssertEqual(panel.pageRecoveryPromptName, "crashed")
        XCTAssertEqual(page.reloads, 0, "Exit page does not reload by itself")
    }
}

private extension BrowserPanel {
    var pageRecoveryPromptName: String? {
        pageRecoveryPrompt.map(TerminalController.debugPromptName)
    }
}
