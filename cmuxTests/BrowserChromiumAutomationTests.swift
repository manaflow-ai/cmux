import AppKit
import CmuxBrowser
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Chromium page stand-in for socket automation: answers DevTools methods
/// from canned replies and records every call, the way the CEF page answers
/// over the shim.
@MainActor
private final class ScriptedChromiumPage: BrowserPage {
    private(set) var devToolsCalls: [(method: String, params: [String: Any])] = []
    private(set) var evaluations: [(script: String, world: BrowserPageScriptWorld)] = []
    private var replies: [String: String] = [:]
    var evaluationValue: Any? = ["__cmux_t": "value", "__cmux_v": 2] as [String: Any]

    func reply(_ method: String, _ json: String) { replies[method] = json }
    func devToolsMethods() -> [String] { devToolsCalls.map(\.method) }

    let engineKind = BrowserEngineKind.chromium
    let capabilities: BrowserEngineCapabilities = [.devToolsProtocol, .trustedInput, .snapshots]
    let presentation = BrowserPagePresentation.inView
    let contentView = NSView()
    var state = BrowserPageState()
    var events: AsyncStream<BrowserPageEvent> { AsyncStream { $0.finish() } }
    weak var uiDelegate: (any BrowserPageUIDelegate)?
    var pageZoom: Double = 1
    var isDevToolsVisible: Bool { false }
    var isMuted = false

    func load(_ request: URLRequest) { state.url = request.url }
    func loadHTMLString(_ html: String, baseURL: URL?) {}
    func goBack() {}
    func goForward() {}
    func reload() {}
    func reloadFromOrigin() {}
    func stop() {}

    func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? {
        evaluations.append((script, world))
        return evaluationValue
    }

    func callAsyncJavaScript(
        _ body: String,
        arguments: [String: any Sendable],
        in world: BrowserPageScriptWorld
    ) async throws -> Any? {
        evaluations.append((body, world))
        return evaluationValue
    }

    func addUserScript(_ script: BrowserPageUserScript) {}
    func removeAllUserScripts() {}
    func showDevTools() {}
    func closeDevTools() {}

    func sendDevToolsProtocolMessage(method: String, params: Data?) async throws -> Data {
        let decoded = params.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        devToolsCalls.append((method, decoded))
        return Data((replies[method] ?? "{}").utf8)
    }

    func takeSnapshot(rect: CGRect?) async throws -> NSImage { NSImage(size: NSSize(width: 1, height: 1)) }
    func setFocused(_ focused: Bool) -> Bool { false }
    func setContentVisible(_ visible: Bool) {}
    func dispatchInput(_ event: BrowserPageInputEvent) async throws {}
    func exportRestoreState() -> BrowserPageRestoreState? { nil }
    func close() {}
}

@MainActor
private final class ScriptedChromiumProvider: BrowserEngineProviding {
    let kind = BrowserEngineKind.chromium
    var availability = BrowserEngineAvailability.available
    let capabilities: BrowserEngineCapabilities = [.devToolsProtocol, .trustedInput, .snapshots]
    private(set) var pages: [ScriptedChromiumPage] = []

    func makePage(_ configuration: BrowserPageConfiguration) throws -> any BrowserPage {
        let page = ScriptedChromiumPage()
        pages.append(page)
        return page
    }
}

/// `browser.*` socket commands on a Chromium panel go through its page:
/// scripts through the page's evaluation, screenshots, cookies and keys
/// through DevTools, and nothing on a Chromium internal page.
@MainActor
@Suite(.serialized)
struct BrowserChromiumAutomationTests {
    @Test func socketAutomationDrivesAChromiumPanelThroughItsPage() async throws {
        let provider = ScriptedChromiumProvider()
        let registry = BrowserEngineRuntime.shared.registry
        let previousProvider = registry.provider(for: .chromium)
        registry.register(provider)
        let defaults = UserDefaults.standard
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled(defaults: defaults)
        BrowserAvailabilitySettings.setDisabled(false, defaults: defaults)
        let manager = TabManager()
        defer {
            // Later tests in this process see the app's own Chromium provider
            // again, or none.
            if let previousProvider {
                registry.register(previousProvider)
            } else {
                provider.availability = .unavailable(.notBundled)
            }
            TerminalController.shared.setActiveTabManager(nil)
            manager.tabs.forEach { $0.teardownAllPanels() }
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled, defaults: defaults)
        }
        let workspace = try #require(manager.selectedWorkspace)
        let sourceID = try #require(workspace.focusedPanelId)
        TerminalController.shared.setActiveTabManager(manager)

        let opened = try successfulResult(await call(method: "browser.open_split", params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": sourceID.uuidString,
            "url": "https://example.com/",
            "engine": "chromium",
            "focus": false,
        ]))
        #expect(opened["engine"] as? String == "chromium")
        let surfaceID = try #require(opened["surface_id"] as? String)
        let panelID = try #require(UUID(uuidString: surfaceID))
        let panel = try #require(workspace.panels[panelID] as? BrowserPanel)
        let page = try #require(provider.pages.last)
        #expect(panel.automationEnginePage === page)
        panel.applyEnginePageState(BrowserPageState(url: URL(string: "https://example.com/")))

        // Scripts run through the page's own evaluation, in the page world.
        let evaluated = try successfulResult(await call(method: "browser.eval", params: [
            "surface_id": surfaceID, "script": "1 + 1",
        ]))
        #expect((evaluated["value"] as? NSNumber)?.intValue == 2)
        #expect(page.evaluations.count == 1)
        #expect(page.evaluations.first?.world == .page)

        // Screenshots, cookies and keys go through DevTools.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        page.reply("Page.captureScreenshot", #"{"data":"\#(png.base64EncodedString())"}"#)
        let shot = try successfulResult(await call(method: "browser.screenshot", params: ["surface_id": surfaceID]))
        #expect(shot["png_base64"] as? String == png.base64EncodedString())

        page.reply("Network.getAllCookies", #"{"cookies":[{"name":"k","value":"v","domain":"example.com","path":"/","session":true}]}"#)
        let cookies = try successfulResult(await call(method: "browser.cookies.get", params: ["surface_id": surfaceID]))
        let cookieNames = (cookies["cookies"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(cookieNames == ["k"])

        _ = try successfulResult(await call(method: "browser.press", params: ["surface_id": surfaceID, "key": "Enter"]))
        #expect(page.devToolsMethods() == [
            "Page.captureScreenshot", "Network.getAllCookies", "Input.dispatchKeyEvent", "Input.dispatchKeyEvent",
        ])

        // On a Chromium internal page the person opened, automation is refused
        // and nothing reaches the page.
        panel.applyEnginePageState(BrowserPageState(url: URL(string: "chrome://settings/passwords")))
        let callsBefore = page.devToolsCalls.count
        let evaluationsBefore = page.evaluations.count
        let refusedEval = try errorPayload(await call(method: "browser.eval", params: [
            "surface_id": surfaceID, "script": "document.title",
        ]))
        #expect((refusedEval["message"] as? String)?.contains("internal pages") == true)
        let refusedShot = try errorPayload(await call(method: "browser.screenshot", params: ["surface_id": surfaceID]))
        #expect(refusedShot["code"] as? String == "agent_refused")
        let refusedCookies = try errorPayload(await call(method: "browser.cookies.get", params: ["surface_id": surfaceID]))
        #expect(refusedCookies["code"] as? String == "agent_refused")
        let refusedKey = try errorPayload(await call(method: "browser.press", params: ["surface_id": surfaceID, "key": "a"]))
        #expect(refusedKey["code"] as? String == "agent_refused")
        #expect(page.devToolsCalls.count == callsBefore)
        #expect(page.evaluations.count == evaluationsBefore)
    }

    /// Sends one request through the full socket dispatcher off the main
    /// thread, as a client's request arrives, so socket-worker commands can
    /// wait for the main actor.
    private func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let response = await Task.detached { TerminalController.shared.handleSocketLine(line) }.value
        return try #require(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
    }

    private func successfulResult(_ response: [String: Any]) throws -> [String: Any] {
        #expect(response["ok"] as? Bool == true, "\(response)")
        return try #require(response["result"] as? [String: Any])
    }

    private func errorPayload(_ response: [String: Any]) throws -> [String: Any] {
        #expect(response["ok"] as? Bool == false, "\(response)")
        return try #require(response["error"] as? [String: Any])
    }
}
