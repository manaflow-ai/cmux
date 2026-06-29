import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock socket lifecycle", .serialized)
struct DockSocketLifecycleTests {
    private static let socketWorkerQueue = DispatchQueue(label: "DockSocketLifecycleTests.socketWorker")

    @MainActor
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

    @MainActor
    private func v2EnvelopeOnSocketWorker(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let controller = TerminalController.shared
        let raw = await withCheckedContinuation { continuation in
            Self.socketWorkerQueue.async {
                continuation.resume(returning: controller.handleSocketLine(requestLine))
            }
        }
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    @MainActor
    private func v2Result(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let envelope = try v2Envelope(method: method, params: params)
        if envelope["ok"] as? Bool != true {
            Issue.record("Expected \(method) to succeed: \(envelope)")
        }
        return try #require(envelope["result"] as? [String: Any])
    }

    @MainActor
    private func v2ResultOnSocketWorker(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let envelope = try await v2EnvelopeOnSocketWorker(method: method, params: params)
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
    private func withDockEnabled(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.dockEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { restoreUserDefault(previous, forKey: key) }
        try await body()
    }

    @MainActor
    private func withDockDisabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.dockEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
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
    private func withBrowserEnabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) as? Bool
        let hadPrevious = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) != nil
        BrowserAvailabilitySettings.setDisabled(false)
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
    private func withBrowserEnabled(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) as? Bool
        let hadPrevious = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) != nil
        BrowserAvailabilitySettings.setDisabled(false)
        defer {
            if hadPrevious, let previous {
                BrowserAvailabilitySettings.setDisabled(previous)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
                NotificationCenter.default.post(name: BrowserAvailabilitySettings.didChangeNotification, object: nil)
            }
        }
        try await body()
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
            appDelegate.existingGlobalDock?.closeAllPanels()
            TerminalController.shared.setActiveTabManager(previousManager)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        try body(manager, workspace, windowId)
    }

    @MainActor
    private func withSocketAppContext(
        fileExplorerState: FileExplorerState? = nil,
        _ body: (TabManager, Workspace, UUID) async throws -> Void
    ) async throws {
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
            appDelegate.existingGlobalDock?.closeAllPanels()
            TerminalController.shared.setActiveTabManager(previousManager)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        try await body(manager, workspace, windowId)
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
                let globalDock = try #require(AppDelegate.shared?.existingGlobalDock)
                #expect(result["window_id"] as? String == windowId.uuidString)
                #expect(result["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
                #expect(fileExplorerState.isVisible)
                #expect(fileExplorerState.mode == .dock)
                #expect(globalDock.focusedPanelId == dockSurfaceId)
                #expect(workspace._dockSplit?.containsPanel(dockSurfaceId) != true)
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
                let globalDock = try #require(AppDelegate.shared?.existingGlobalDock)
                #expect(result["window_id"] as? String == windowId.uuidString)
                #expect(result["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
                #expect(fileExplorerState.isVisible)
                #expect(fileExplorerState.mode == .dock)
                #expect(globalDock.focusedPanelId == dockSurfaceId)
                #expect(workspace._dockSplit?.containsPanel(dockSurfaceId) != true)
            }
        }
    }

    @Test("Dock placement is rejected when Dock mode is disabled")
    @MainActor
    func dockPlacementRejectedWhenDockModeDisabled() throws {
        try withDockDisabled {
            try withSocketAppContext { _, workspace, _ in
                for method in ["surface.create", "pane.create"] {
                    var params = ["placement": "dock", "type": "terminal", "focus": true]
                    if method == "pane.create" {
                        params["direction"] = "right"
                    }
                    let envelope = try v2Envelope(method: method, params: params)

                    #expect(envelope["ok"] as? Bool == false)
                    let error = try #require(envelope["error"] as? [String: Any])
                    #expect(error["code"] as? String == "invalid_params")
                    #expect(error["message"] as? String == "Dock placement is disabled")
                    #expect(AppDelegate.shared?.existingGlobalDock?.bonsplitController.allTabIds.isEmpty ?? true)
                    #expect(workspace._dockSplit?.bonsplitController.allTabIds.isEmpty ?? true)
                }
            }
        }
    }

    @Test("Dock unavailable beats browser-disabled external fallback")
    @MainActor
    func dockUnavailableBeatsBrowserDisabledExternalFallback() throws {
        try withDockDisabled {
            try withBrowserDisabled {
                try withSocketAppContext { _, workspace, _ in
                    for method in ["surface.create", "pane.create"] {
                        var params = ["placement": "dock", "type": "browser", "url": "https://example.com"]
                        if method == "pane.create" {
                            params["direction"] = "right"
                        }
                        let envelope = try v2Envelope(method: method, params: params)

                        #expect(envelope["ok"] as? Bool == false)
                        let error = try #require(envelope["error"] as? [String: Any])
                        #expect(error["code"] as? String == "invalid_params")
                        #expect(error["message"] as? String == "Dock placement is disabled")
                        #expect(AppDelegate.shared?.existingGlobalDock?.bonsplitController.allTabIds.isEmpty ?? true)
                        #expect(workspace._dockSplit?.bonsplitController.allTabIds.isEmpty ?? true)
                    }
                }
            }
        }
    }

    @Test("surface.close closes Dock surfaces")
    @MainActor
    func surfaceCloseClosesDockSurfaces() throws {
        try withDockEnabled {
            try withSocketAppContext { _, workspace, windowId in
                let mainPanelIds = Set(workspace.panels.keys)
                let createResult = try v2Result(
                    method: "surface.create",
                    params: ["placement": "dock", "type": "terminal", "focus": true]
                )
                let dockSurfaceIdRaw = try #require(createResult["dock_surface_id"] as? String)
                let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))
                let globalDock = try #require(AppDelegate.shared?.existingGlobalDock)
                #expect(createResult["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
                #expect(globalDock.containsPanel(dockSurfaceId))
                #expect(workspace._dockSplit?.containsPanel(dockSurfaceId) != true)

                let closeResult = try v2Result(
                    method: "surface.close",
                    params: [
                        "workspace_id": AppDelegate.globalDockWorkspaceId.uuidString
                    ]
                )

                #expect(closeResult["window_id"] as? String == windowId.uuidString)
                #expect(closeResult["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
                #expect(closeResult["surface_id"] as? String == dockSurfaceId.uuidString)
                #expect(!globalDock.containsPanel(dockSurfaceId))
                #expect(Set(workspace.panels.keys) == mainPanelIds)
            }
        }
    }

    @Test("Global Dock owner resolves surface read snapshots")
    @MainActor
    func globalDockOwnerResolvesSurfaceReadSnapshots() throws {
        try withDockEnabled {
            try withSocketAppContext { _, workspace, _ in
                let mainPanelIds = Set(workspace.panels.keys)
                let createResult = try v2Result(
                    method: "surface.create",
                    params: ["placement": "dock", "type": "terminal", "focus": true]
                )
                let dockSurfaceIdRaw = try #require(createResult["dock_surface_id"] as? String)
                let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))

                let listResult = try v2Result(
                    method: "surface.list",
                    params: ["workspace_id": AppDelegate.globalDockWorkspaceId.uuidString]
                )
                let surfaces = try #require(listResult["surfaces"] as? [[String: Any]])
                #expect(listResult["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
                #expect(surfaces.contains { $0["id"] as? String == dockSurfaceId.uuidString })

                let currentResult = try v2Result(
                    method: "surface.current",
                    params: ["workspace_id": AppDelegate.globalDockWorkspaceId.uuidString]
                )
                #expect(currentResult["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
                #expect(currentResult["surface_id"] as? String == dockSurfaceId.uuidString)
                #expect(Set(workspace.panels.keys) == mainPanelIds)
            }
        }
    }

    @Test("Global Dock owner pane mutations do not fall back to selected workspace")
    @MainActor
    func globalDockOwnerPaneMutationDoesNotFallBackToSelectedWorkspace() throws {
        try withDockEnabled {
            try withSocketAppContext { _, workspace, _ in
                let mainPanelIds = Set(workspace.panels.keys)
                let mainFocusedPane = workspace.bonsplitController.focusedPaneId

                _ = try v2Result(
                    method: "surface.create",
                    params: ["placement": "dock", "type": "terminal", "focus": true]
                )

                let envelope = try v2Envelope(
                    method: "pane.resize",
                    params: [
                        "workspace_id": AppDelegate.globalDockWorkspaceId.uuidString,
                        "direction": "right",
                        "amount": 1,
                    ]
                )

                #expect(envelope["ok"] as? Bool == false)
                #expect(Set(workspace.panels.keys) == mainPanelIds)
                #expect(workspace.bonsplitController.focusedPaneId == mainFocusedPane)
            }
        }
    }

    @Test("Global Dock browser surfaces resolve browser commands")
    @MainActor
    func globalDockBrowserSurfacesResolveBrowserCommands() async throws {
        try await withDockEnabled {
            try await withBrowserEnabled {
                try await withSocketAppContext { _, workspace, _ in
                    let mainPanelIds = Set(workspace.panels.keys)
                    let createResult = try v2Result(
                        method: "surface.create",
                        params: [
                            "placement": "dock",
                            "type": "browser",
                            "url": "about:blank",
                            "focus": true,
                        ]
                    )
                    let dockSurfaceIdRaw = try #require(createResult["dock_surface_id"] as? String)
                    let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))

                    let urlResult = try v2Result(
                        method: "browser.url.get",
                        params: [
                            "workspace_id": AppDelegate.globalDockWorkspaceId.uuidString,
                            "surface_id": dockSurfaceId.uuidString,
                        ]
                    )
                    #expect(urlResult["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
                    #expect(urlResult["surface_id"] as? String == dockSurfaceId.uuidString)

                    let navigateResult = try await v2ResultOnSocketWorker(
                        method: "browser.navigate",
                        params: [
                            "workspace_id": AppDelegate.globalDockWorkspaceId.uuidString,
                            "surface_id": dockSurfaceId.uuidString,
                            "url": "about:blank",
                        ]
                    )
                    #expect(navigateResult["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
                    #expect(navigateResult["surface_id"] as? String == dockSurfaceId.uuidString)

                    let tabListResult = try v2Result(
                        method: "browser.tab.list",
                        params: ["workspace_id": AppDelegate.globalDockWorkspaceId.uuidString]
                    )
                    let tabs = try #require(tabListResult["tabs"] as? [[String: Any]])
                    #expect(tabListResult["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
                    #expect(tabs.contains { $0["id"] as? String == dockSurfaceId.uuidString })
                    #expect(Set(workspace.panels.keys) == mainPanelIds)
                }
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

    @Test("Dock visibility remains active while any host is mounted")
    @MainActor
    func dockVisibilityRemainsActiveWhileAnyHostIsMounted() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)

        let panelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        let panel = try #require(store.panel(for: tabId) as? TerminalPanel)
        let firstHost = UUID()
        let secondHost = UUID()

        store.setActive(isVisible: true, mode: .dock, visibilityHostId: firstHost)
        store.setActive(isVisible: true, mode: .dock, visibilityHostId: secondHost)

        #expect(store.isVisibleInUI)
        #expect(panel.hostedView.debugPortalVisibleInUI)

        store.setVisibleInUI(false, hostId: firstHost)

        #expect(store.isVisibleInUI)
        #expect(panel.hostedView.debugPortalVisibleInUI)

        store.setVisibleInUI(false, hostId: secondHost)

        #expect(!store.isVisibleInUI)
        #expect(!panel.hostedView.debugPortalVisibleInUI)
    }

    @Test("Dock zoom hides selected panels outside the zoomed pane")
    @MainActor
    func dockZoomHidesSelectedPanelsOutsideZoomedPane() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)

        let firstPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let secondPanelId = try #require(store.newSplit(
            kind: .terminal,
            orientation: .vertical,
            insertFirst: false,
            sourcePanelId: firstPanelId,
            focus: true
        ))
        let firstTabId = try #require(store.surfaceId(forPanelId: firstPanelId))
        let secondTabId = try #require(store.surfaceId(forPanelId: secondPanelId))
        let firstPane = try #require(store.paneId(forPanelId: firstPanelId))
        let secondPane = try #require(store.paneId(forPanelId: secondPanelId))
        let firstPanel = try #require(store.panel(for: firstTabId) as? TerminalPanel)
        let secondPanel = try #require(store.panel(for: secondTabId) as? TerminalPanel)

        store.setVisibleInUI(true)

        #expect(firstPane != secondPane)
        #expect(store.panelIsSelectedInVisibleDockPane(firstPanelId))
        #expect(store.panelIsSelectedInVisibleDockPane(secondPanelId))
        #expect(firstPanel.hostedView.debugPortalVisibleInUI)
        #expect(secondPanel.hostedView.debugPortalVisibleInUI)

        #expect(store.bonsplitController.requestTabZoomToggle(for: secondTabId, inPane: secondPane))

        #expect(store.bonsplitController.zoomedPaneId == secondPane)
        #expect(!store.panelIsSelectedInVisibleDockPane(firstPanelId))
        #expect(!store.panelIsActiveInVisibleDockPane(firstPanelId))
        #expect(!firstPanel.hostedView.debugPortalVisibleInUI)
        #expect(!firstPanel.hostedView.debugPortalActive)
        #expect(store.panelIsSelectedInVisibleDockPane(secondPanelId))
        #expect(store.panelIsActiveInVisibleDockPane(secondPanelId))
        #expect(secondPanel.hostedView.debugPortalVisibleInUI)
        #expect(secondPanel.hostedView.debugPortalActive)
    }

    @Test("Dock UI tab close clears surface notifications")
    @MainActor
    func dockUITabCloseClearsSurfaceNotifications() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.replaceNotificationsForTesting([])

        try withSocketAppContext { _, workspace, _ in
            let appDelegate = try #require(AppDelegate.shared)
            let previousNotificationStore = appDelegate.notificationStore
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.replaceNotificationsForTesting([])
                appDelegate.notificationStore = previousNotificationStore
            }

            let store = workspace.dockSplit
            let rootPane = try #require(store.bonsplitController.allPaneIds.first)
            let panelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
            let tabId = try #require(store.surfaceId(forPanelId: panelId))
            notificationStore.replaceNotificationsForTesting([
                TerminalNotification(
                    id: UUID(),
                    tabId: workspace.id,
                    surfaceId: panelId,
                    title: "Dock",
                    subtitle: "",
                    body: "Unread",
                    createdAt: Date(),
                    isRead: false
                ),
            ])

            #expect(notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))

            store.forceCloseDockTabIds.insert(tabId)
            #expect(store.bonsplitController.closeTab(tabId))

            #expect(!store.containsPanel(panelId))
            #expect(!notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        }
    }

    @Test("Global Dock pane routing and focused close stay in the Dock")
    @MainActor
    func dockPaneRoutingAndFocusedCloseStayInDock() throws {
#if DEBUG
        try withDockEnabled {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let activeManager = TabManager(autoWelcomeIfNeeded: false)
            let dockManager = TabManager(autoWelcomeIfNeeded: false)
            let fileExplorerState = FileExplorerState()
            let activeWindowId = UUID()
            let activeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            activeWindow.isReleasedWhenClosed = false
            activeWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(activeWindowId.uuidString)")
            let dockWindowId = UUID()
            let dockWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            dockWindow.isReleasedWhenClosed = false
            dockWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(dockWindowId.uuidString)")

            AppDelegate.shared = appDelegate
            appDelegate.tabManager = activeManager
            TerminalController.shared.setActiveTabManager(activeManager)
            appDelegate.registerMainWindow(activeWindow, windowId: activeWindowId, tabManager: activeManager, sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState())
            appDelegate.registerMainWindow(dockWindow, windowId: dockWindowId, tabManager: dockManager, sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState(), fileExplorerState: fileExplorerState)
            dockWindow.orderFront(nil)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.existingGlobalDock?.closeAllPanels()
                appDelegate.unregisterMainWindowContextForTesting(windowId: activeWindowId)
                appDelegate.unregisterMainWindowContextForTesting(windowId: dockWindowId)
                activeManager.tabs.forEach { $0.teardownAllPanels() }
                dockManager.tabs.forEach { $0.teardownAllPanels() }
                activeWindow.orderOut(nil)
                activeWindow.close()
                dockWindow.orderOut(nil)
                dockWindow.close()
                AppDelegate.shared = previousAppDelegate
            }

            let activeWorkspace = try #require(activeManager.tabs.first)
            let dockWorkspace = try #require(dockManager.tabs.first)
            let globalDock = appDelegate.globalDock
            let dockPane = try #require(globalDock.bonsplitController.allPaneIds.first)
            let result = try v2Result(method: "surface.create", params: [
                "placement": "dock",
                "type": "terminal",
                "pane_id": dockPane.id.uuidString,
                "window_id": activeWindowId.uuidString,
            ])
            let dockSurfaceIdRaw = try #require(result["dock_surface_id"] as? String)
            let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))
            #expect(result["window_id"] as? String == activeWindowId.uuidString)
            #expect(result["workspace_id"] as? String == AppDelegate.globalDockWorkspaceId.uuidString)
            #expect(globalDock.containsPanel(dockSurfaceId))
            #expect(activeWorkspace._dockSplit?.containsPanel(dockSurfaceId) != true)
            #expect(dockWorkspace._dockSplit?.containsPanel(dockSurfaceId) != true)

            let closeAction = KeyboardShortcutSettings.Action.closeTab
            let hadCloseShortcut = UserDefaults.standard.object(forKey: closeAction.defaultsKey) != nil
            let originalCloseShortcut = KeyboardShortcutSettings.shortcut(for: closeAction)
            KeyboardShortcutSettings.setShortcut(closeAction.defaultShortcut, for: closeAction)
            defer {
                if hadCloseShortcut {
                    KeyboardShortcutSettings.setShortcut(originalCloseShortcut, for: closeAction)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: closeAction)
                }
            }

            let mainPanelCount = dockWorkspace.panels.count
            let focusedMainPanel = dockWorkspace.focusedPanelId
            fileExplorerState.setVisible(true)
            fileExplorerState.mode = .dock
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: dockWindow)
            let closeEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: dockWindow.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))

            #expect(appDelegate.debugHandleCustomShortcut(event: closeEvent))
            #expect(!globalDock.containsPanel(dockSurfaceId))
            #expect(dockWorkspace.panels.count == mainPanelCount)
            #expect(dockWorkspace.focusedPanelId == focusedMainPanel)
        }
#else
        Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
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

    // MARK: - Creation/split shortcut routing to the focused Dock

    /// Sets up a single registered main window with the Global Dock created, and
    /// tears everything down (including the static Global Dock's panels) on exit.
    /// Builds and dispatches a synthetic key-down event through the custom
    /// shortcut handler. Kept as a `@MainActor` method so callers don't invoke
    /// the main-actor handler from a nested/ nonisolated context.
    @MainActor
    private func dispatchShortcut(
        _ appDelegate: AppDelegate,
        window: NSWindow,
        characters: String,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return false
        }
        return appDelegate.debugHandleCustomShortcut(event: event)
    }

    /// Sets up a single registered main window with the Global Dock created, and
    /// tears everything down (including the static Global Dock's panels) on exit.
    @MainActor
    private func withDockShortcutHarness(
        _ body: @MainActor (
            _ appDelegate: AppDelegate,
            _ manager: TabManager,
            _ mainWorkspace: Workspace,
            _ globalDock: DockSplitStore,
            _ fileExplorerState: FileExplorerState,
            _ window: NSWindow
        ) throws -> Void
    ) throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let fileExplorerState = FileExplorerState()
        let windowId = UUID()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")

        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        appDelegate.registerMainWindow(window, windowId: windowId, tabManager: manager, sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState(), fileExplorerState: fileExplorerState)
        window.makeKeyAndOrderFront(nil)
        defer {
            appDelegate.existingGlobalDock?.closeAllPanels()
            TerminalController.shared.setActiveTabManager(previousManager)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        let mainWorkspace = try #require(manager.tabs.first)
        let globalDock = appDelegate.globalDock
        try body(appDelegate, manager, mainWorkspace, globalDock, fileExplorerState, window)
    }

    @MainActor
    private func withDefaultShortcuts(
        _ actions: [KeyboardShortcutSettings.Action],
        _ body: @MainActor () throws -> Void
    ) rethrows {
        let originals = actions.map {
            (action: $0,
             had: UserDefaults.standard.object(forKey: $0.defaultsKey) != nil,
             shortcut: KeyboardShortcutSettings.shortcut(for: $0))
        }
        for action in actions { KeyboardShortcutSettings.setShortcut(action.defaultShortcut, for: action) }
        defer {
            for entry in originals {
                if entry.had {
                    KeyboardShortcutSettings.setShortcut(entry.shortcut, for: entry.action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: entry.action)
                }
            }
        }
        try body()
    }

    @Test("Creation and split shortcuts route to the focused Dock")
    @MainActor
    func creationAndSplitShortcutsRouteToFocusedDock() throws {
#if DEBUG
        try withDockEnabled {
            try withBrowserEnabled {
                try withDefaultShortcuts([.newSurface, .openBrowser, .splitRight, .splitDown]) {
                    try withDockShortcutHarness { appDelegate, _, mainWorkspace, globalDock, fileExplorerState, window in
                        // Seed one Dock terminal so there is a focused Dock pane/panel.
                        let rootPane = try #require(globalDock.resolvePane(requestedPaneID: nil))
                        _ = try #require(globalDock.newSurface(kind: .terminal, inPane: rootPane, focus: true))

                        // Make the Dock the active right-sidebar area.
                        fileExplorerState.setVisible(true)
                        fileExplorerState.mode = .dock
                        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)

                        let mainPanelsBefore = Set(mainWorkspace.panels.keys)

                        // New Terminal (Cmd+T) -> a Dock tab is added.
                        let tabsBeforeT = globalDock.bonsplitController.allTabIds.count
                        #expect(dispatchShortcut(appDelegate, window: window, characters: "t", keyCode: 17, flags: [.command]))
                        #expect(globalDock.bonsplitController.allTabIds.count == tabsBeforeT + 1)

                        // New Browser (Cmd+Shift+L) -> a Dock browser is added.
                        let tabsBeforeL = globalDock.bonsplitController.allTabIds.count
                        #expect(dispatchShortcut(appDelegate, window: window, characters: "l", keyCode: 37, flags: [.command, .shift]))
                        #expect(globalDock.bonsplitController.allTabIds.count == tabsBeforeL + 1)
                        let browserPanelId = try #require(globalDock.focusedPanelId)
                        #expect(globalDock.browserPanel(for: browserPanelId) != nil)

                        // Split Right (Cmd+D) -> a Dock pane is added.
                        let panesBeforeD = globalDock.bonsplitController.allPaneIds.count
                        #expect(dispatchShortcut(appDelegate, window: window, characters: "d", keyCode: 2, flags: [.command]))
                        #expect(globalDock.bonsplitController.allPaneIds.count == panesBeforeD + 1)

                        // Split Down (Cmd+Shift+D) -> a Dock pane is added.
                        let panesBeforeShiftD = globalDock.bonsplitController.allPaneIds.count
                        #expect(dispatchShortcut(appDelegate, window: window, characters: "d", keyCode: 2, flags: [.command, .shift]))
                        #expect(globalDock.bonsplitController.allPaneIds.count == panesBeforeShiftD + 1)

                        // The main content area never received any of the new surfaces.
                        #expect(Set(mainWorkspace.panels.keys) == mainPanelsBefore)
                    }
                }
            }
        }
#else
        Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    @Test("New Surface shortcut stays in the main area when the Dock is unfocused")
    @MainActor
    func newSurfaceShortcutStaysInMainAreaWhenDockUnfocused() throws {
#if DEBUG
        try withDockEnabled {
            try withDefaultShortcuts([.newSurface]) {
                try withDockShortcutHarness { appDelegate, _, mainWorkspace, globalDock, fileExplorerState, window in
                    // Dock has content but is NOT the focused area; the main panel is.
                    let rootPane = try #require(globalDock.resolvePane(requestedPaneID: nil))
                    _ = try #require(globalDock.newSurface(kind: .terminal, inPane: rootPane, focus: true))
                    fileExplorerState.mode = .files
                    let mainPanelId = try #require(mainWorkspace.focusedPanelId)
                    appDelegate.noteMainPanelKeyboardFocusIntent(workspaceId: mainWorkspace.id, panelId: mainPanelId, in: window)

                    let dockTabsBefore = globalDock.bonsplitController.allTabIds.count

                    #expect(dispatchShortcut(appDelegate, window: window, characters: "t", keyCode: 17, flags: [.command]))

                    // The Dock did not receive the new surface (it went to the main area).
                    #expect(globalDock.bonsplitController.allTabIds.count == dockTabsBefore)
                }
            }
        }
#else
        Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }
}
