import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension DockSocketLifecycleTests {
    @Test("surface.focus accepts handles for a window-owned Dock")
    @MainActor
    func surfaceFocusAcceptsDockSurfaceHandles() throws {
        try withDockEnabled {
            try withDockShortcutHarness { app, manager, _, store, sidebar, _ in
                let windowID = try #require(app.windowId(for: manager))
                let pane = try #require(store.bonsplitController.allPaneIds.first)
                let first = try #require(store.newSurface(kind: .terminal, inPane: pane, focus: true))
                let second = try #require(store.newSurface(kind: .terminal, inPane: pane, focus: false))
                #expect(store.focusedPanelId == first)
                let listing = try v2Result(method: "surface.list", params: ["workspace_id": windowID.uuidString])
                let surfaces = try #require(listing["surfaces"] as? [[String: Any]])
                let handle = try #require(surfaces.first { $0["id"] as? String == second.uuidString }?["ref"] as? String)
                let result = try v2Result(method: "surface.focus", params: ["surface_id": handle])
                #expect(result["window_id"] as? String == windowID.uuidString)
                #expect(result["workspace_id"] as? String == windowID.uuidString)
                #expect(result["surface_id"] as? String == second.uuidString)
                #expect(store.focusedPanelId == second)
                #expect(sidebar.isVisible && sidebar.mode == .dock)
            }
        }
    }

    @Test(
        "Dock terminal creation injects input into an interactive shell",
        arguments: ["surface.create", "pane.create"]
    )
    @MainActor
    func dockTerminalCreationInjectsInitialInput(method: String) throws {
        try withDockEnabled {
            try withSocketAppContext { _, _, windowID in
                let initialInput = " printf '  preserved  '\t\r"
                var params: [String: Any] = [
                    "placement": "dock",
                    "type": "terminal",
                    "initial_input": initialInput,
                    "focus": false,
                ]
                if method == "pane.create" {
                    params["direction"] = "right"
                }

                let result = try v2Result(method: method, params: params)
                let surfaceID = try #require(
                    (result["dock_surface_id"] as? String).flatMap(UUID.init(uuidString:))
                )
                let dock = try #require(AppDelegate.shared?.existingWindowDock(forWindowId: windowID))
                let panel = try #require(dock.panels[surfaceID] as? TerminalPanel)
                #expect(panel.surface.debugInitialInputForTesting() == initialInput)
                #expect(panel.surface.debugInitialCommand() == nil)
                #expect(panel.surface.debugWaitAfterCommand() == false)
            }
        }
    }
}
