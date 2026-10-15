import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The `engine` parameter of browser-creating socket methods and the
/// `engine` field of their results.
@MainActor
@Suite(.serialized)
struct BrowserEngineSocketTests {
    @Test func browserCreationReportsItsEngineAndRefusesUnavailableOrUnknownEngines() throws {
        let defaults = UserDefaults.standard
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled(defaults: defaults)
        BrowserAvailabilitySettings.setDisabled(false, defaults: defaults)
        let manager = TabManager()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            manager.tabs.forEach { $0.teardownAllPanels() }
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled, defaults: defaults)
        }
        let workspace = try #require(manager.selectedWorkspace)
        let sourceID = try #require(workspace.focusedPanelId)
        TerminalController.shared.setActiveTabManager(manager)

        // Without an engine the panel follows the configured engine, and the
        // result reports the engine the panel actually got.
        let opened = try successfulResult(call(method: "browser.open_split", params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": sourceID.uuidString,
            "url": "about:blank",
            "focus": false,
        ]))
        let openedID = try #require((opened["surface_id"] as? String).flatMap(UUID.init(uuidString:)))
        let openedPanel = try #require(workspace.panels[openedID] as? BrowserPanel)
        #expect(opened["engine"] as? String == openedPanel.engineKind.rawValue)

        // An explicit WebKit request is honored.
        let explicitWebKit = try successfulResult(call(method: "browser.tab.new", params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": openedID.uuidString,
            "url": "about:blank",
            "engine": "WebKit",
        ]))
        #expect(explicitWebKit["engine"] as? String == "webkit")

        let listed = try successfulResult(call(method: "browser.tab.list", params: [
            "workspace_id": workspace.id.uuidString,
        ]))
        let tabs = try #require(listed["tabs"] as? [[String: Any]])
        #expect(!tabs.isEmpty)
        for tab in tabs {
            let id = try #require((tab["id"] as? String).flatMap(UUID.init(uuidString:)))
            let panel = try #require(workspace.panels[id] as? BrowserPanel)
            #expect(tab["engine"] as? String == panel.engineKind.rawValue)
        }

        // url.get (behind `cmux browser identify`) reports it too.
        let urlPayload = try successfulResult(call(method: "browser.url.get", params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": openedID.uuidString,
        ]))
        #expect(urlPayload["engine"] as? String == openedPanel.engineKind.rawValue)

        let panelCount = workspace.panels.count

        // An unknown engine is a parameter error.
        let unknown = try errorPayload(call(method: "browser.open_split", params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": sourceID.uuidString,
            "engine": "gecko",
        ]))
        #expect(unknown["code"] as? String == "invalid_params")

        // Chromium is refused with its reason, never silently opened as WebKit.
        // (A test host with the Chromium runtime registered opens it instead;
        // the refusal contract is checked where it is unavailable.)
        guard case .unavailable(let reason) = BrowserEngineRuntime.shared.availability(for: .chromium) else {
            return
        }
        for method in ["browser.open_split", "browser.tab.new"] {
            let refused = try errorPayload(call(method: method, params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": sourceID.uuidString,
                "url": "about:blank",
                "engine": "chromium",
            ]))
            #expect(refused["code"] as? String == "engine_unavailable")
            let data = try #require(refused["data"] as? [String: Any])
            #expect(data["engine"] as? String == "chromium")
            #expect(data["reason"] as? String == reason.code)
        }
        #expect(workspace.panels.count == panelCount)
    }

    private func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let response = TerminalController.shared.handleSocketLine(line)
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
