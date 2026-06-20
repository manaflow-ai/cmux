import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock socket lifecycle", .serialized)
struct DockSocketLifecycleTests {
    private func v2Envelope(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func v2Result(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let envelope = try v2Envelope(method: method, params: params)
        if envelope["ok"] as? Bool != true {
            Issue.record("Expected \(method) to succeed: \(envelope)")
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
    private func withBrowserDisabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) as? Bool
        let hadPrevious = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) != nil
        BrowserAvailabilitySettings.setDisabled(true)
        defer {
            if hadPrevious, let previous {
                BrowserAvailabilitySettings.setDisabled(previous)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
                NotificationCenter.default.post(name: BrowserAvailabilitySettings.didChangeNotification, object: nil)
            }
        }
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

    @Test("surface.create validates placement before browser disabled handling")
    @MainActor
    func surfaceCreateInvalidPlacementBeatsBrowserDisabled() throws {
        try withBrowserDisabled {
            try withSocketAppContext { _, _, _ in
                let envelope = try v2Envelope(
                    method: "surface.create",
                    params: ["placement": "not-a-place", "type": "browser"]
                )

                #expect(envelope["ok"] as? Bool == false)
                let error = try #require(envelope["error"] as? [String: Any])
                #expect(error["code"] as? String == "invalid_params")
                #expect(error["message"] as? String == "placement must be one of: workspace, dock")
            }
        }
    }

    @Test("pane.create validates placement before browser disabled handling")
    @MainActor
    func paneCreateInvalidPlacementBeatsBrowserDisabled() throws {
        try withBrowserDisabled {
            try withSocketAppContext { _, _, _ in
                let envelope = try v2Envelope(
                    method: "pane.create",
                    params: ["placement": "not-a-place", "direction": "right", "type": "browser"]
                )

                #expect(envelope["ok"] as? Bool == false)
                let error = try #require(envelope["error"] as? [String: Any])
                #expect(error["code"] as? String == "invalid_params")
                #expect(error["message"] as? String == "placement must be one of: workspace, dock")
            }
        }
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

    @Test("surface.close closes Dock surfaces")
    @MainActor
    func surfaceCloseClosesDockSurfaces() throws {
        try withDockEnabled {
            try withSocketAppContext { _, workspace, windowId in
                let createResult = try v2Result(
                    method: "surface.create",
                    params: ["placement": "dock", "type": "terminal", "focus": true]
                )
                let dockSurfaceIdRaw = try #require(createResult["dock_surface_id"] as? String)
                let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))
                #expect(workspace.dockSplit.containsPanel(dockSurfaceId))

                let closeResult = try v2Result(
                    method: "surface.close",
                    params: [
                        "workspace_id": workspace.id.uuidString,
                        "surface_id": dockSurfaceId.uuidString,
                    ]
                )

                #expect(closeResult["window_id"] as? String == windowId.uuidString)
                #expect(closeResult["workspace_id"] as? String == workspace.id.uuidString)
                #expect(closeResult["surface_id"] as? String == dockSurfaceId.uuidString)
                #expect(!workspace.dockSplit.containsPanel(dockSurfaceId))
            }
        }
    }

    @Test("Dock tab selection activates the selected terminal")
    @MainActor
    func dockTabSelectionActivatesSelectedTerminal() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)

        let firstPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let secondPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let firstTabId = try #require(store.surfaceId(forPanelId: firstPanelId))
        let secondTabId = try #require(store.surfaceId(forPanelId: secondPanelId))
        let firstPanel = try #require(store.panel(for: firstTabId) as? TerminalPanel)
        let secondPanel = try #require(store.panel(for: secondTabId) as? TerminalPanel)

        store.setVisibleInUI(true)

        #expect(store.focusedPanelId == secondPanelId)
        #expect(!firstPanel.hostedView.debugPortalVisibleInUI)
        #expect(!firstPanel.hostedView.debugPortalActive)
        #expect(secondPanel.hostedView.debugPortalVisibleInUI)
        #expect(secondPanel.hostedView.debugPortalActive)

        store.bonsplitController.selectTab(firstTabId)

        #expect(store.focusedPanelId == firstPanelId)
        #expect(firstPanel.hostedView.debugPortalVisibleInUI)
        #expect(firstPanel.hostedView.debugPortalActive)
        #expect(!secondPanel.hostedView.debugPortalVisibleInUI)
        #expect(!secondPanel.hostedView.debugPortalActive)
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
