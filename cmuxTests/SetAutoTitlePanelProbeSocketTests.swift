import Foundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct SetAutoTitlePanelProbeSocketTests {
    private func decodeResponse(_ response: String) throws -> [String: Any] {
        let data = try #require(response.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = ["id": method, "method": method, "params": params]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        return try decodeResponse(TerminalController.shared.handleSocketLine(requestLine))
    }

    private func withAutoNamingSetting<T>(_ enabled: Bool, _ body: () throws -> T) rethrows -> T {
        let key = AutomationCatalogSection().workspaceAutoNaming.userDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        return try body()
    }

    private func withManager<T>(_ body: (Workspace) throws -> T) throws -> T {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(nil) }
        return try body(workspace)
    }

    @Test func panelProbeReportsPanelCurrentTitleForPanelTarget() throws {
        try withAutoNamingSetting(true) {
            try withManager { workspace in
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
                _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
                let params: [String: Any] = [
                    "probe": true,
                    "workspace_id": workspace.id.uuidString,
                    "panel_id": panelId.uuidString,
                    "panel_only_if_multiple": true
                ]

                workspace.setCustomTitle("Workspace Auto", source: .auto)
                workspace.setPanelCustomTitle(panelId: panelId, title: "Panel Auto", source: .auto)
                var envelope = try call(method: "workspace.set_auto_title", params: params)
                var result = try #require(envelope["result"] as? [String: Any])
                #expect(result["auto_naming_panel_writable"] as? Bool == true)
                #expect(result["auto_naming_current_title"] as? String == "Panel Auto")

                workspace.setPanelCustomTitle(panelId: panelId, title: "Panel User")
                envelope = try call(method: "workspace.set_auto_title", params: params)
                result = try #require(envelope["result"] as? [String: Any])
                #expect(result["auto_naming_panel_writable"] as? Bool == false)
                #expect(result["auto_naming_current_title"] as? String == "Workspace Auto")
            }
        }
    }
}
