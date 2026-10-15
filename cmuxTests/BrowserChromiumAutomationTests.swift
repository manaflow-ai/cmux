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
    /// When set, every script and DevTools call fails with it (a page whose
    /// runtime never started).
    var failure: BrowserEngineError?

    /// False for a page whose engine content is not up (released by Memory
    /// Saver, or never created); `startForAutomation` counts the requests.
    var isLiveForAutomation = true
    private(set) var startRequests = 0
    func startForAutomation() { startRequests += 1 }

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

    /// Runs after every load, so a test can answer it as the engine would.
    var onLoad: ((URL?) -> Void)?

    func load(_ request: URLRequest) {
        state.url = request.url
        onLoad?(request.url)
    }
    func loadHTMLString(_ html: String, baseURL: URL?) {}
    func goBack() {}
    func goForward() {}
    func reload() { onLoad?(state.url) }
    func reloadFromOrigin() {}
    func stop() {}

    func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? {
        if let failure { throw failure }
        evaluations.append((script, world))
        return evaluationValue
    }

    func callAsyncJavaScript(
        _ body: String,
        arguments: [String: any Sendable],
        in world: BrowserPageScriptWorld
    ) async throws -> Any? {
        if let failure { throw failure }
        evaluations.append((body, world))
        return evaluationValue
    }

    func addUserScript(_ script: BrowserPageUserScript) {}
    func removeAllUserScripts() {}
    func showDevTools() {}
    func closeDevTools() {}

    func sendDevToolsProtocolMessage(method: String, params: Data?) async throws -> Data {
        if let failure { throw failure }
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

extension ScriptedChromiumPage: BrowserEnginePageAutomationStarting {}

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

        // `type` keeps the text as given, whitespace included, as `fill` does;
        // a lone space is text, not a missing parameter.
        for text in [" x y ", " "] {
            let typed = try await call(method: "browser.type", params: [
                "surface_id": surfaceID, "selector": "#a", "text": text,
            ])
            #expect((typed["error"] as? [String: Any])?["code"] as? String != "invalid_params", "\(typed)")
            let literal = try #require(String(data: JSONSerialization.data(withJSONObject: [text]), encoding: .utf8))
            #expect(page.evaluations.last?.script.contains(String(literal.dropFirst().dropLast())) == true)
        }

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

        // A page whose engine cannot run answers one error on every verb,
        // carrying the engine's reason.
        panel.applyEnginePageState(BrowserPageState(url: URL(string: "https://example.com/")))
        page.failure = .unavailable(.chromium, .startFailed("runtime did not start"))
        for (method, extra) in [
            ("browser.eval", ["script": "1"]),
            ("browser.wait", ["selector": "body", "timeout_ms": 500]),
            ("browser.get.text", ["selector": "body"]),
            ("browser.screenshot", [:]),
            ("browser.cookies.get", [:]),
            ("browser.press", ["key": "Enter"]),
        ] as [(String, [String: Any])] {
            var params: [String: Any] = ["surface_id": surfaceID]
            params.merge(extra) { _, new in new }
            let failed = try errorPayload(await call(method: method, params: params))
            #expect(failed["code"] as? String == "engine_unavailable", "\(method): \(failed)")
            let data = failed["data"] as? [String: Any]
            #expect(data?["reason"] as? String == "startFailed", "\(method): \(failed)")
        }

        // A tab opened from a Chromium surface with no engine named inherits
        // Chromium, as a tab opened from the page's own UI does.
        let pagesBefore = provider.pages.count
        let inherited = try successfulResult(await call(method: "browser.tab.new", params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceID,
            "url": "https://example.com/other",
        ]))
        #expect(inherited["engine"] as? String == "chromium", "\(inherited)")
        #expect(provider.pages.count == pagesBefore + 1)
        let inheritedID = try #require((inherited["surface_id"] as? String).flatMap(UUID.init(uuidString:)))
        #expect((workspace.panels[inheritedID] as? BrowserPanel)?.engineKind == .chromium)
    }

    /// A command on a Chromium page that is not up (Memory Saver released it,
    /// or its pane was never shown) starts it and waits for it, instead of
    /// failing with engine_unavailable; an engine that cannot start is not
    /// waited for.
    @Test func automationStartsAndWaitsForAChromiumPageThatIsNotUp() async throws {
        let provider = ScriptedChromiumProvider()
        let registry = BrowserEngineRuntime.shared.registry
        let previousProvider = registry.provider(for: .chromium)
        registry.register(provider)
        let manager = TabManager()
        defer {
            if let previousProvider {
                registry.register(previousProvider)
            } else {
                provider.availability = .unavailable(.notBundled)
            }
            TerminalController.shared.setActiveTabManager(nil)
            manager.tabs.forEach { $0.teardownAllPanels() }
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
        let surfaceID = try #require(opened["surface_id"] as? String)
        let panelID = try #require(UUID(uuidString: surfaceID))
        let panel = try #require(workspace.panels[panelID] as? BrowserPanel)
        let page = try #require(provider.pages.last)
        panel.applyEnginePageState(BrowserPageState(url: URL(string: "https://example.com/")))

        page.isLiveForAutomation = false
        async let evaluated = call(method: "browser.eval", params: ["surface_id": surfaceID, "script": "1 + 1"])
        // The command asked the page to start, and waits for it.
        while page.startRequests == 0 { await Task.yield() }
        #expect(page.evaluations.isEmpty)
        page.isLiveForAutomation = true
        panel.handleEnginePageEvent(.stateChanged(BrowserPageState(url: URL(string: "https://example.com/"))))
        let result = try successfulResult(await evaluated)
        #expect((result["value"] as? NSNumber)?.intValue == 2)
        #expect(page.evaluations.count == 1)

        // An engine that cannot start answers at once with its reason.
        page.isLiveForAutomation = false
        provider.availability = .unavailable(.startFailed("runtime did not start"))
        page.failure = .unavailable(.chromium, .startFailed("runtime did not start"))
        let requestsBefore = page.startRequests
        let failed = try errorPayload(await call(method: "browser.eval", params: ["surface_id": surfaceID, "script": "1"]))
        #expect(failed["code"] as? String == "engine_unavailable")
        #expect(page.startRequests == requestsBefore)
    }

    @Test func navigationsAndCrashesOnAChromiumPanelReportWhatHappened() async throws {
        let provider = ScriptedChromiumProvider()
        let registry = BrowserEngineRuntime.shared.registry
        let previousProvider = registry.provider(for: .chromium)
        registry.register(provider)
        let manager = TabManager()
        defer {
            if let previousProvider {
                registry.register(previousProvider)
            } else {
                provider.availability = .unavailable(.notBundled)
            }
            TerminalController.shared.setActiveTabManager(nil)
            manager.tabs.forEach { $0.teardownAllPanels() }
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
        let surfaceID = try #require(opened["surface_id"] as? String)
        let panelID = try #require(UUID(uuidString: surfaceID))
        let panel = try #require(workspace.panels[panelID] as? BrowserPanel)
        let page = try #require(provider.pages.last)
        // The engine finishes each load the way Chromium reports it.
        page.onLoad = { [weak panel] url in
            Task { @MainActor in panel?.handleEnginePageEvent(.navigationFinished(url)) }
        }

        // navigate and reload succeed once the engine finishes the load,
        // instead of reporting navigation_failed for a load without a WKNavigation.
        _ = try successfulResult(await call(method: "browser.navigate", params: [
            "surface_id": surfaceID, "url": "https://example.com/next",
        ]))
        _ = try successfulResult(await call(method: "browser.reload", params: ["surface_id": surfaceID]))

        // A crashed renderer fails scripts at once with page_crashed.
        page.state.processExit = BrowserPageProcessExit(kind: .crashed, status: 9)
        let crashed = try errorPayload(await call(method: "browser.eval", params: [
            "surface_id": surfaceID, "script": "1",
        ]))
        #expect(crashed["code"] as? String == "page_crashed", "\(crashed)")
        #expect(page.evaluations.isEmpty)

        // Reloading recovers it, and reports success.
        page.state.processExit = nil
        _ = try successfulResult(await call(method: "browser.reload", params: ["surface_id": surfaceID]))
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
