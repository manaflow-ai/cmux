import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock socket lifecycle", .serialized)
struct DockSocketLifecycleTests {
    private func v2Result(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(raw.data(using: .utf8))
        let envelope = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        if envelope["ok"] as? Bool != true {
            Issue.record("Expected \(method) to succeed: \(raw)")
        }
        return try #require(envelope["result"] as? [String: Any])
    }

    private func restoreUserDefault(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    @MainActor
    private func withDockEnabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.dockEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { restoreUserDefault(previous, forKey: key) }
        try body()
    }

    @MainActor
    private func withSocketAppContext(
        fileExplorerState: FileExplorerState? = nil,
        _ body: (TabManager, Workspace, UUID) throws -> Void
    ) throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        if let fileExplorerState {
            appDelegate.fileExplorerState = fileExplorerState
        }
        TerminalController.shared.setActiveTabManager(manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            fileExplorerState: fileExplorerState
        )
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        try body(manager, workspace, windowId)
    }

    @Test("Dock surface create with focus reveals the Dock")
    @MainActor
    func dockSurfaceCreateWithFocusRevealsDock() throws {
        try withDockEnabled {
            let fileExplorerState = FileExplorerState()
            fileExplorerState.setVisible(false)
            fileExplorerState.mode = .files

            try withSocketAppContext(fileExplorerState: fileExplorerState) { _, workspace, windowId in
                let result = try v2Result(
                    method: "surface.create",
                    params: ["placement": "dock", "type": "terminal", "focus": true]
                )

                let dockSurfaceIdRaw = try #require(result["dock_surface_id"] as? String)
                let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))
                #expect(result["window_id"] as? String == windowId.uuidString)
                #expect(result["workspace_id"] as? String == workspace.id.uuidString)
                #expect(fileExplorerState.isVisible)
                #expect(fileExplorerState.mode == .dock)
                #expect(workspace.dockSplit.focusedPanelId == dockSurfaceId)
            }
        }
    }

    @Test("Dock pane create with focus reveals the Dock")
    @MainActor
    func dockPaneCreateWithFocusRevealsDock() throws {
        try withDockEnabled {
            let fileExplorerState = FileExplorerState()
            fileExplorerState.setVisible(false)
            fileExplorerState.mode = .files

            try withSocketAppContext(fileExplorerState: fileExplorerState) { _, workspace, windowId in
                let result = try v2Result(
                    method: "pane.create",
                    params: ["placement": "dock", "direction": "right", "type": "terminal", "focus": true]
                )

                let dockSurfaceIdRaw = try #require(result["dock_surface_id"] as? String)
                let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))
                #expect(result["window_id"] as? String == windowId.uuidString)
                #expect(result["workspace_id"] as? String == workspace.id.uuidString)
                #expect(fileExplorerState.isVisible)
                #expect(fileExplorerState.mode == .dock)
                #expect(workspace.dockSplit.focusedPanelId == dockSurfaceId)
            }
        }
    }

    @Test("Runtime close routes Dock terminals through the Dock lifecycle")
    @MainActor
    func runtimeCloseRoutesDockTerminalsThroughDockLifecycle() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)

        let confirmationPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        manager.closeRuntimeSurfaceWithConfirmation(tabId: workspace.id, surfaceId: confirmationPanelId)
        #expect(!store.containsPanel(confirmationPanelId))

        let runtimePanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        manager.closeRuntimeSurface(tabId: workspace.id, surfaceId: runtimePanelId)
        #expect(!store.containsPanel(runtimePanelId))
    }

    @Test("Child exit closes Dock terminal surfaces")
    @MainActor
    func childExitClosesDockTerminalSurfaces() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let panelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panelId)

        #expect(!store.containsPanel(panelId))
        #expect(manager.tabs.contains(where: { $0.id == workspace.id }))
    }
}
