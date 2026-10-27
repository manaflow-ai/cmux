import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Another socket client cannot close, move, detach, reorder, reload or
/// navigate a tab a browser REPL session drives: every socket method that
/// would change such a tab is refused (`denied`, or `ERROR` on the v1 line
/// protocol) and leaves it where it is (docs/browser-repl/README.md,
/// Sessions and tabs). Once no session drives the tab it is the user's
/// again and the same methods work.
@MainActor
@Suite(.serialized)
struct BrowserReplSocketMutationRefusalTests {
    @Test func socketMutationsOfASessionTabAreRefused() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let previousApp = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let app = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let windowID = UUID()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
            AppDelegate.shared = app
            app.registerMainWindow(
                window, windowId: windowID, tabManager: manager, sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(), fileExplorerState: FileExplorerState()
            )
            TerminalController.shared.setActiveTabManager(manager)
            let sessionID = "socket-refusal-test-\(UUID().uuidString)"
            defer {
                BrowserReplTabAttachments.shared.detach(sessionID: sessionID)
                TerminalController.shared.setActiveTabManager(previousManager)
                app.unregisterMainWindowContextForTesting(windowId: windowID)
                manager.finalizeAllWorkspacesForWindowClose()
                window.orderOut(nil)
                AppDelegate.shared = previousApp
            }
            let other = manager.addWorkspace(select: false)
            let workspace = manager.addWorkspace(select: true)
            let pane = try #require(workspace.bonsplitController.focusedPaneId)
            let terminal = try #require(workspace.focusedTerminalPanel)
            let panel = try #require(workspace.newBrowserSurface(
                inPane: pane,
                url: URL(string: "about:blank"),
                focus: false,
                creationPolicy: .automationPreload
            ))
            let attachment = try BrowserReplTabAttachments.shared.attach(
                panel: panel,
                sessionID: sessionID,
                world: .world(name: sessionID)
            ) { _, _ in }
            attachment.markCreated(by: sessionID)
            let index = workspace.indexInPane(forPanelId: panel.id)
            let otherPane = try #require(other.bonsplitController.focusedPaneId)

            let ws = workspace.id.uuidString
            let tab = panel.id.uuidString
            let requests: [(String, [String: Any])] = [
                ("browser.tab.close", ["workspace_id": ws, "tab_id": tab]),
                ("surface.close", ["workspace_id": ws, "surface_id": tab, "force": true]),
                ("surface.move", ["surface_id": tab, "workspace_id": other.id.uuidString]),
                ("pane.join", ["surface_id": tab, "target_pane_id": otherPane.id.uuidString]),
                ("surface.reorder", ["surface_id": tab, "index": 0]),
                ("surface.drag_to_split", ["surface_id": tab, "direction": "right"]),
                ("surface.split_off", ["surface_id": tab, "direction": "down"]),
                ("pane.break", ["workspace_id": ws, "surface_id": tab]),
                ("surface.action", ["workspace_id": ws, "surface_id": tab, "action": "move_to_new_workspace"]),
                ("surface.action", ["workspace_id": ws, "surface_id": tab, "action": "reload"]),
                ("surface.action", ["workspace_id": ws, "surface_id": terminal.id.uuidString, "action": "close_others", "force": true]),
            ]
            for (method, params) in requests {
                let reply = try Self.call(method, params)
                if params["action"] as? String != "close_others" {
                    #expect((reply["error"] as? [String: Any])?["code"] as? String == "denied", "\(method) \(params) was not refused: \(reply)")
                }
                #expect(workspace.panels[panel.id] != nil, "\(method) \(params) closed or moved the session's tab")
                #expect(workspace.paneId(forPanelId: panel.id) == pane, "\(method) \(params) moved the session's tab to another pane")
                #expect(workspace.indexInPane(forPanelId: panel.id) == index, "\(method) \(params) reordered the session's tab")
            }
            for line in ["close_surface \(tab)", "navigate \(tab) https://example.com/"] {
                let reply = TerminalController.shared.handleSocketLine(line)
                #expect(reply.hasPrefix("ERROR"), "\(line) was not refused: \(reply)")
                #expect(workspace.panels[panel.id] != nil, "\(line) closed the session's tab")
            }

            // A tab no session drives is the user's again.
            BrowserReplTabAttachments.shared.detach(sessionID: sessionID)
            let reply = try Self.call("surface.close", ["workspace_id": ws, "surface_id": tab, "force": true])
            #expect(reply["ok"] as? Bool == true, "the user's tab was not closed: \(reply)")
            #expect(workspace.panels[panel.id] == nil)
        }
    }

    private static func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = ["id": method, "method": method, "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let raw = TerminalController.shared.handleSocketLine(line)
        return try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], Comment(rawValue: raw))
    }
}
