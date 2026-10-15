import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `browser.tab.list` names a browser surface as its `surface_id`, never the
/// focused terminal.
@MainActor
@Suite(.serialized)
struct BrowserTabListSurfaceTests {
    @Test
    func tabListReportsTheRequestedBrowserSurfaceNotTheFocusedTerminal() throws {
        let manager = TabManager()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            manager.tabs.forEach { $0.teardownAllPanels() }
        }
        let workspace = try #require(manager.selectedWorkspace)
        let terminalID = try #require(workspace.focusedPanelId)
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let browser = try #require(workspace.newBrowserSurface(
            inPane: pane,
            url: URL(string: "about:blank"),
            focus: false
        ))
        #expect(workspace.focusedPanelId == terminalID)
        TerminalController.shared.setActiveTabManager(manager)

        let explicit = try result(TerminalController.shared.handleSocketLine(request(
            "browser.tab.list",
            ["workspace_id": workspace.id.uuidString, "surface_id": browser.id.uuidString]
        )))
        #expect(explicit["surface_id"] as? String == browser.id.uuidString)

        // Without a surface, the terminal is focused, so no browser is named
        // rather than the terminal.
        let implicit = try result(TerminalController.shared.handleSocketLine(request(
            "browser.tab.list",
            ["workspace_id": workspace.id.uuidString]
        )))
        #expect(implicit["surface_id"] as? String != terminalID.uuidString)
    }

    private func request(_ method: String, _ params: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params,
        ] as [String: Any])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func result(_ response: String) throws -> [String: Any] {
        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        #expect(envelope["ok"] as? Bool == true, "\(envelope)")
        return try #require(envelope["result"] as? [String: Any])
    }
}
