import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cross-window Dock routing over the socket API: Dock-scoped commands anchor
/// to the Dock's owning window, explicitly contradictory selectors fail
/// closed, the legacy Global Dock alias keeps routing to the caller's window,
/// and the focused-close shortcut acts on its own window's Dock only.
/// See https://github.com/manaflow-ai/cmux/issues/7142.
@Suite("Window Dock socket routing", .serialized)
struct WindowDockRoutingSocketTests {
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
    private func v2Result(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let envelope = try v2Envelope(method: method, params: params)
        if envelope["ok"] as? Bool != true {
            Issue.record("Expected \(method) to succeed: \(envelope)")
        }
        return try #require(envelope["result"] as? [String: Any])
    }

    @MainActor
    private func withDockEnabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.dockEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
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
            // Unregistering the window context also tears down that window's Dock.
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        try body(manager, workspace, windowId)
    }

    @Test("Legacy global Dock alias workspace_id routes to the caller window's Dock")
    @MainActor
    func legacyDockAliasRoutesToCallerWindowDock() throws {
        try withDockEnabled {
            try withSocketAppContext { _, _, windowId in
                let createResult = try v2Result(
                    method: "surface.create",
                    params: ["placement": "dock", "type": "terminal", "focus": true]
                )
                let dockSurfaceIdRaw = try #require(createResult["dock_surface_id"] as? String)
                let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))

                // The retired app-wide Global Dock's owner id keeps routing for
                // CLI compatibility: it resolves to the Dock of the window the
                // command targets, and results report that Dock's real owner id.
                let listResult = try v2Result(
                    method: "surface.list",
                    params: ["workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString]
                )
                let surfaces = try #require(listResult["surfaces"] as? [[String: Any]])
                #expect(listResult["workspace_id"] as? String == windowId.uuidString)
                #expect(surfaces.contains { $0["id"] as? String == dockSurfaceId.uuidString })

                // A supplied-but-unresolvable selector fails closed instead of
                // degrading to the focused-Dock fallback.
                let unresolvedEnvelope = try v2Envelope(method: "browser.tab.list", params: [
                    "workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString,
                    "surface_id": "",
                ])
                #expect(unresolvedEnvelope["ok"] as? Bool == false)
                let unresolvedError = try #require(unresolvedEnvelope["error"] as? [String: Any])
                #expect(unresolvedError["code"] as? String == "invalid_params")

                let closeResult = try v2Result(
                    method: "surface.close",
                    params: ["workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString]
                )
                #expect(closeResult["workspace_id"] as? String == windowId.uuidString)
                #expect(closeResult["surface_id"] as? String == dockSurfaceId.uuidString)
                let windowDock = try #require(AppDelegate.shared?.existingWindowDock(forWindowId: windowId))
                #expect(!windowDock.containsPanel(dockSurfaceId))
            }
        }
    }

    @Test("Window Dock pane routing and focused close stay in their own window's Dock")
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
                // Unregistering each window context also tears down its Dock.
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
            let activeWindowDock = appDelegate.windowDock(forWindowId: activeWindowId)
            let dockPane = try #require(activeWindowDock.bonsplitController.allPaneIds.first)
            let result = try v2Result(method: "surface.create", params: [
                "placement": "dock",
                "type": "terminal",
                "pane_id": dockPane.id.uuidString,
                "window_id": activeWindowId.uuidString,
            ])
            let dockSurfaceIdRaw = try #require(result["dock_surface_id"] as? String)
            let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))
            #expect(result["window_id"] as? String == activeWindowId.uuidString)
            #expect(result["workspace_id"] as? String == activeWindowId.uuidString)
            #expect(activeWindowDock.containsPanel(dockSurfaceId))
            #expect(appDelegate.existingWindowDock(forWindowId: dockWindowId) == nil)
            #expect(activeWorkspace._dockSplit?.containsPanel(dockSurfaceId) != true)
            #expect(dockWorkspace._dockSplit?.containsPanel(dockSurfaceId) != true)

            // Seed the second window's own Dock so the focused close below has a
            // panel to act on in ITS window.
            let otherWindowDock = appDelegate.windowDock(forWindowId: dockWindowId)
            #expect(otherWindowDock !== activeWindowDock)
            let otherPane = try #require(otherWindowDock.resolvePane(requestedPaneID: nil))
            let otherDockSurfaceId = try #require(otherWindowDock.newSurface(kind: .terminal, inPane: otherPane, focus: true))

            // An explicit window_id that contradicts the Dock named by
            // workspace_id fails closed instead of re-homing the report.
            let crossListEnvelope = try v2Envelope(method: "surface.list", params: [
                "workspace_id": activeWindowId.uuidString,
                "window_id": dockWindowId.uuidString,
            ])
            #expect(crossListEnvelope["ok"] as? Bool == false)

            // A Dock-owner workspace_id alone routes to (and reports) the
            // owning window, wherever the caller runs.
            let ownerList = try v2Result(method: "surface.list", params: [
                "workspace_id": activeWindowId.uuidString,
            ])
            #expect(ownerList["workspace_id"] as? String == activeWindowId.uuidString)
            #expect(ownerList["window_id"] as? String == activeWindowId.uuidString)

            // Explicitly naming two different windows' Docks fails closed.
            let conflictEnvelope = try v2Envelope(method: "browser.tab.list", params: [
                "workspace_id": activeWindowId.uuidString,
                "surface_id": otherDockSurfaceId.uuidString,
            ])
            #expect(conflictEnvelope["ok"] as? Bool == false)
            let conflictError = try #require(conflictEnvelope["error"] as? [String: Any])
            #expect(conflictError["code"] as? String == "invalid_params")

            // Read-style Dock commands share the same fail-closed selector
            // semantics; they do not have later surface/pane containment guards.
            let readSurfaceConflict = try v2Envelope(method: "surface.list", params: [
                "workspace_id": activeWindowId.uuidString,
                "surface_id": otherDockSurfaceId.uuidString,
            ])
            #expect(readSurfaceConflict["ok"] as? Bool == false)
            let readPaneConflict = try v2Envelope(method: "pane.list", params: [
                "workspace_id": activeWindowId.uuidString,
                "pane_id": otherPane.id.uuidString,
            ])
            #expect(readPaneConflict["ok"] as? Bool == false)
            let aliasSurfaceConflict = try v2Envelope(method: "surface.list", params: [
                "workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString,
                "surface_id": otherDockSurfaceId.uuidString,
            ])
            #expect(aliasSurfaceConflict["ok"] as? Bool == false)
            let aliasPaneConflict = try v2Envelope(method: "pane.list", params: [
                "workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString,
                "pane_id": otherPane.id.uuidString,
            ])
            #expect(aliasPaneConflict["ok"] as? Bool == false)

            // A workspace_id naming a NON-Dock scope contradicts a Dock surface
            // selector the same way.
            let workspaceScopeConflict = try v2Envelope(method: "browser.tab.list", params: [
                "workspace_id": dockWorkspace.id.uuidString,
                "surface_id": otherDockSurfaceId.uuidString,
            ])
            #expect(workspaceScopeConflict["ok"] as? Bool == false)

            // Focusing a Dock surface by id targets its owning window even when
            // the caller's context resolved elsewhere; an explicit contradictory
            // window_id or Dock-owner workspace_id fails closed instead.
            let crossFocusEnvelope = try v2Envelope(method: "surface.focus", params: [
                "surface_id": dockSurfaceId.uuidString,
                "window_id": dockWindowId.uuidString,
            ])
            #expect(crossFocusEnvelope["ok"] as? Bool == false)
            let ownerConflictFocusEnvelope = try v2Envelope(method: "surface.focus", params: [
                "surface_id": dockSurfaceId.uuidString,
                "workspace_id": dockWindowId.uuidString,
            ])
            #expect(ownerConflictFocusEnvelope["ok"] as? Bool == false)
            let focusResult = try v2Result(method: "surface.focus", params: [
                "surface_id": dockSurfaceId.uuidString,
            ])
            #expect(focusResult["window_id"] as? String == activeWindowId.uuidString)
            #expect(focusResult["workspace_id"] as? String == activeWindowId.uuidString)
            #expect(activeWindowDock.focusedPanelId == dockSurfaceId)

            // Dock creates mutate immediately, so contradictory owner selectors
            // must be rejected before adding panels to either Dock.
            let activeDockPanelCount = activeWindowDock.panels.count
            let otherDockPanelCount = otherWindowDock.panels.count
            let conflictingSurfaceCreate = try v2Envelope(method: "surface.create", params: [
                "placement": "dock",
                "type": "terminal",
                "window_id": activeWindowId.uuidString,
                "workspace_id": dockWindowId.uuidString,
            ])
            #expect(conflictingSurfaceCreate["ok"] as? Bool == false)
            let surfaceCreateError = try #require(conflictingSurfaceCreate["error"] as? [String: Any])
            #expect(surfaceCreateError["code"] as? String == "invalid_params")
            #expect(activeWindowDock.panels.count == activeDockPanelCount)
            #expect(otherWindowDock.panels.count == otherDockPanelCount)

            let conflictingPaneCreate = try v2Envelope(method: "pane.create", params: [
                "placement": "dock",
                "type": "terminal",
                "direction": "right",
                "window_id": activeWindowId.uuidString,
                "workspace_id": dockWindowId.uuidString,
            ])
            #expect(conflictingPaneCreate["ok"] as? Bool == false)
            let paneCreateError = try #require(conflictingPaneCreate["error"] as? [String: Any])
            #expect(paneCreateError["code"] as? String == "invalid_params")
            #expect(activeWindowDock.panels.count == activeDockPanelCount)
            #expect(otherWindowDock.panels.count == otherDockPanelCount)

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
            // The focused close acted on the second window's OWN Dock; the first
            // window's Dock panel is untouched.
            #expect(!otherWindowDock.containsPanel(otherDockSurfaceId))
            #expect(activeWindowDock.containsPanel(dockSurfaceId))
            #expect(dockWorkspace.panels.count == mainPanelCount)
            #expect(dockWorkspace.focusedPanelId == focusedMainPanel)
        }
#else
        Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }
}
