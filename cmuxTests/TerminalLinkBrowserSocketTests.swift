import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal link socket placement", .serialized)
struct TerminalLinkBrowserSocketTests {
    @Test(arguments: [true, false])
    func onlyOptedInOpensUseTerminalPlacement(optIn: Bool) throws {
        let defaults = UserDefaults.standard
        let key = "browserTerminalLinkBrowserPlacement"
        let previous = defaults.object(forKey: key)
        defaults.set("samePane", forKey: key)
        let manager = TabManager()
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        controller.setActiveTabManager(manager)
        defer {
            controller.setActiveTabManager(previousManager)
            manager.tabs.forEach { $0.teardownAllPanels() }
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let workspace = try #require(manager.selectedWorkspace)
        let source = try #require(workspace.focusedPanelId)
        let pane = try #require(workspace.paneId(forPanelId: source))
        let payload: [String: Any] = [
            "id": "terminal-link-placement", "method": "browser.open_split",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": source.uuidString,
                "url": "about:blank", "focus": false,
                "use_terminal_link_browser_placement": optIn,
            ],
        ]
        let wire = try #require(String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8))
        let response = controller.handleSocketLine(wire)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        #expect(decoded["ok"] as? Bool == true)
        let result = try #require(decoded["result"] as? [String: Any])
        let createdID = try #require((result["surface_id"] as? String).flatMap(UUID.init(uuidString:)))
        #expect(workspace.panels[createdID] is BrowserPanel)
        #expect(workspace.bonsplitController.allPaneIds.count == (optIn ? 1 : 2))
        #expect((workspace.paneId(forPanelId: createdID) == pane) == optIn)
        #expect(result["created_split"] as? Bool == !optIn)
        #expect(result["placement_strategy"] as? String == (optIn ? "same_pane" : "split_right"))
        #expect(workspace.focusedPanelId == source)
    }
}
