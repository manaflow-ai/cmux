import AppKit
import Bonsplit
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class WindowDockTestPanel: Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    let displayTitle = "Test Dock Panel"
    let displayIcon: String? = "terminal.fill"
    var isDirty = false

    private(set) var closeCount = 0
    private(set) var focusCount = 0
    private(set) var unfocusCount = 0
    private(set) var flashCount = 0

    func close() {
        closeCount += 1
    }

    func focus() {
        focusCount += 1
    }

    func unfocus() {
        unfocusCount += 1
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        flashCount += 1
    }
}

private extension DockSplitStore {
    @discardableResult
    func seedTestPanel() throws -> WindowDockTestPanel {
        try seedTestPanel(WindowDockTestPanel())
    }

    @discardableResult
    func seedTestPanel(_ panel: WindowDockTestPanel) throws -> WindowDockTestPanel {
        let pane = try #require(bonsplitController.allPaneIds.first)
        panels[panel.id] = panel
        let tabId = try #require(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: "terminal",
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        bindSurface(tabId, toPanelId: panel.id)
        return panel
    }
}

/// Per-window Dock registry lifecycle: every main window owns an independent
/// `DockSplitStore` (created lazily, owner id == window id) that transfers
/// across context replacement and retires with its authoritative route, while
/// multiple windows render their Docks simultaneously without cross-window
/// render-host gating.
/// See https://github.com/manaflow-ai/cmux/issues/7142.
@Suite("Per-window Dock lifecycle", .serialized)
struct WindowDockLifecycleTests {
    @MainActor
    private func drainMainActorQueue() async {
        await Task.yield()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        await Task.yield()
    }

    @MainActor
    private func withIsolatedAppDelegate(_ body: (AppDelegate) throws -> Void) rethrows {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer {
            for windowId in Set(appDelegate.mainWindowContexts.values.map(\.windowId)) {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            }
            AppDelegate.shared = previousAppDelegate
        }
        try body(appDelegate)
    }

    @Test("Each window gets its own independent Dock store")
    @MainActor
    func windowDocksAreIndependentPerWindow() {
        withIsolatedAppDelegate { appDelegate in
            let firstManager = TabManager(autoWelcomeIfNeeded: false)
            let secondManager = TabManager(autoWelcomeIfNeeded: false)
            let firstWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: firstManager)
            let secondWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: secondManager)
            defer {
                firstManager.tabs.forEach { $0.teardownAllPanels() }
                secondManager.tabs.forEach { $0.teardownAllPanels() }
            }

            let firstDock = appDelegate.windowDock(forWindowId: firstWindowId)
            let secondDock = appDelegate.windowDock(forWindowId: secondWindowId)

            #expect(firstDock !== secondDock)
            #expect(firstDock.workspaceId == firstWindowId)
            #expect(secondDock.workspaceId == secondWindowId)
            #expect(firstDock.scope == .global)
            #expect(appDelegate.windowDock(forWindowId: firstWindowId) === firstDock)
            #expect(appDelegate.existingWindowDock(forWindowId: firstWindowId) === firstDock)
            #expect(appDelegate.existingWindowDock(forWindowId: secondWindowId) === secondDock)
            #expect(appDelegate.existingWindowDock(forWindowId: UUID()) == nil)
            #expect(Set(appDelegate.existingWindowDocks.map(\.workspaceId)) == [firstWindowId, secondWindowId])
        }
    }

    @Test("Workspace panel teardown keeps its Dock reusable")
    @MainActor
    func workspacePanelTeardownKeepsDockReusable() throws {
        let workspace = Workspace()
        defer { workspace.retireFromOwningTabManager() }

        let dock = try #require(workspace.dockSplit)
        let firstPanel = try dock.seedTestPanel()

        workspace.teardownAllPanels()

        #expect(dock.panels.isEmpty)
        #expect(!dock.isRetired)
        #expect(workspace.dockSplit === dock)

        let replacementPanel = try dock.seedTestPanel()
        #expect(replacementPanel.id != firstPanel.id)
    }

    @Test("Retired workspaces reject late panel callbacks")
    @MainActor
    func retiredWorkspaceRejectsLatePanelCallbacks() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = manager.addWorkspace(
            title: "Cloud VM",
            initialSurface: .cloudVMLoading,
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false
        )
        defer {
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
        }

        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let dock = try #require(workspace.dockSplit)
        let dockPaneId = try #require(dock.bonsplitController.allPaneIds.first)
        workspace.retireFromOwningTabManager()

        #expect(
            workspace.replaceCloudVMLoadingSurfaceWithTerminal(
                workspaceId: workspace.id,
                initialCommand: "cmux vm-pty-connect --id stale",
                focus: false
            ) == nil
        )
        #expect(workspace.newNotificationsSurface(inPane: paneId) == nil)
        #expect(workspace.openOrFocusNotificationsSurface(inPane: paneId) == nil)
        #expect(
            !dock.handleExternalFileDrop(
                BonsplitController.ExternalFileDropRequest(
                    urls: [URL(fileURLWithPath: "/tmp/stale-preview.txt")],
                    destination: .insert(targetPane: dockPaneId, targetIndex: nil)
                )
            )
        )
    }

    @Test("Finalized managers reject late session restoration")
    @MainActor
    func finalizedManagerRejectsLateSessionRestoration() {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        manager.finalizeAllWorkspacesForWindowClose()
        let remaps = manager.restoreSessionSnapshot(snapshot)

        #expect(remaps.isEmpty)
        #expect(manager.tabs.isEmpty)
    }

    @Test("Window Dock tears down on authoritative route removal")
    @MainActor
    func windowDockTearsDownOnAuthoritativeRouteRemoval() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let appDelegate = try #require(AppDelegate.shared)
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            var unregistered = false
            defer {
                if !unregistered {
                    appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                }
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
            }

            let dock = appDelegate.windowDock(forWindowId: windowId)
            let panel = try dock.seedTestPanel()
            let panelId = panel.id
            let paneId = try #require(
                dock.bonsplitController.focusedPaneId ?? dock.bonsplitController.allPaneIds.first
            )
            #expect(dock.containsPanel(panelId))
            #expect(AppDelegate.isWindowDockRoutingId(windowId))

            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            unregistered = true
            // Test unregistration models a recoverable SwiftUI context loss. The
            // explicit forget below is the authoritative window-close boundary.
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            let registryIdsAfterUnregister = Set(
                GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id)
            )

            let latePanelId = dock.newSurface(
                kind: .terminal,
                inPane: paneId,
                command: "/usr/bin/true",
                focus: false
            )

            // The store was dropped from the registry and its panels torn down —
            // no PTY outlives the window, even when a stale UI callback retains
            // the old store and tries to create another panel.
            #expect(appDelegate.existingWindowDock(forWindowId: windowId) == nil)
            #expect(!AppDelegate.isWindowDockRoutingId(windowId))
            #expect(dock.isRetired)
            #expect(latePanelId == nil)
            #expect(!dock.containsPanel(panelId))
            #expect(dock.panels.isEmpty)
            #expect(!dock.isVisibleInUI)
            #expect(panel.closeCount == 1)
            #expect(Set(GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id)) == registryIdsAfterUnregister)
            // A closed window's manager can never seed a NEW Dock (it would have
            // no teardown owner); manager-based lookup fails closed instead.
            #expect(appDelegate.windowDock(for: manager) == nil)
        }
    }

    @Test("Recoverable context replacement preserves and re-adopts the window Dock")
    @MainActor
    func recoverableContextReplacementPreservesWindowDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager =
                TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            AppDelegate.shared = appDelegate

            let manager = TabManager(autoWelcomeIfNeeded: false)
            let windowId = appDelegate.registerMainWindowContextForTesting(
                tabManager: manager
            )
            let replacementWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            replacementWindow.isReleasedWhenClosed = false
            replacementWindow.identifier = NSUserInterfaceItemIdentifier(
                "cmux.main.\(windowId.uuidString)"
            )
            defer {
                if appDelegate.mainWindowContexts.values.contains(where: {
                    $0.windowId == windowId
                }) {
                    appDelegate.unregisterMainWindowContextForTesting(
                        windowId: windowId
                    )
                }
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                if !manager.isFinalizedForWindowClose {
                    manager.finalizeAllWorkspacesForWindowClose()
                }
                replacementWindow.orderOut(nil)
                replacementWindow.close()
                TerminalController.shared.setActiveTabManager(previousActiveManager)
                AppDelegate.shared = previousAppDelegate
            }

            let dock = appDelegate.windowDock(forWindowId: windowId)
            let panel = try dock.seedTestPanel()

            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)

            #expect(!dock.isRetired)
            #expect(dock.containsPanel(panel.id))
            #expect(appDelegate.existingWindowDock(forWindowId: windowId) === dock)
            #expect(appDelegate.windowDockForRegisteredOwner(windowId) === dock)
            #expect(appDelegate.existingWindowDocks.contains { $0 === dock })
            #expect(
                appDelegate.recoverableMainWindowRoute(windowId: windowId)?
                    .windowDock === dock
            )
            let recoverableSnapshot = try #require(
                appDelegate.sessionSnapshotForTesting()?.windows.first(where: {
                    $0.windowId == windowId
                })
            )
            #expect(recoverableSnapshot.dock != nil)

            appDelegate.registerMainWindow(
                replacementWindow,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )

            #expect(appDelegate.existingWindowDock(forWindowId: windowId) === dock)
            #expect(appDelegate.recoverableMainWindowRoute(windowId: windowId) == nil)
            #expect(!dock.isRetired)
            #expect(dock.containsPanel(panel.id))

            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            #expect(!dock.isRetired)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)

            #expect(dock.isRetired)
            #expect(!dock.containsPanel(panel.id))
            #expect(panel.closeCount == 1)
        }
    }

    @Test("Abandoned browser-only route retires its transferred Dock when its owner deinitializes")
    @MainActor
    func abandonedBrowserOnlyRouteRetiresTransferredDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager =
                TerminalController.shared.activeTabManagerForCallerNotification()
            let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
            let appDelegate = AppDelegate()
            AppDelegate.shared = appDelegate
            BrowserAvailabilitySettings.setDisabled(false)

            var manager: TabManager? = TabManager(autoWelcomeIfNeeded: false)
            weak var releasedManager = manager
            let workspace = try #require(manager?.selectedWorkspace)
            let terminal = try #require(workspace.focusedTerminalPanel)
            let workspacePane = try #require(
                workspace.bonsplitController.focusedPaneId
                    ?? workspace.bonsplitController.allPaneIds.first
            )
            let workspaceBrowser = try #require(
                workspace.newBrowserSurface(
                    inPane: workspacePane,
                    url: URL(string: "https://example.com/route-owner"),
                    focus: true,
                    creationPolicy: .restoration
                )
            )
            #expect(workspace.closePanel(terminal.id, force: true))
            #expect(workspace.browserPanel(for: workspaceBrowser.id) === workspaceBrowser)
            #expect(!workspace.panels.values.contains { $0 is TerminalPanel })
            // Drain the initial terminal's unregister before a recoverable route
            // exists, so no terminal-topology callback can satisfy this test.
            await drainMainActorQueue()

            let windowId = appDelegate.registerMainWindowContextForTesting(
                tabManager: try #require(manager)
            )
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let dockBrowserId = try #require(
                dock.newSurface(
                    kind: .browser,
                    inPane: dockPane,
                    url: URL(string: "https://example.com/transferred-dock"),
                    focus: true
                )
            )
            defer {
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                workspace.teardownAllPanels()
                TerminalController.shared.setActiveTabManager(previousActiveManager)
                BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled)
                AppDelegate.shared = previousAppDelegate
            }

            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            #expect(!dock.isRetired)
            #expect(dock.containsPanel(dockBrowserId))

            manager = nil
            await drainMainActorQueue()

            #expect(releasedManager == nil)
            #expect(dock.isRetired)
            #expect(!dock.containsPanel(dockBrowserId))
            #expect(dock.panels.isEmpty)
        }
    }

    @Test("Runtime close routes window Dock surfaces through the Dock store")
    @MainActor
    func runtimeCloseRoutesWindowDockTerminals() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
        }

        let dock = appDelegate.windowDock(forWindowId: windowId)
        let panel = try dock.seedTestPanel()

        // Ghostty runtime closes (Ctrl-D / child exit) route by the surface's
        // owner id, which for a window Dock is a window id no TabManager tab
        // matches — the Dock-aware path must close the panel instead.
        #expect(appDelegate.closeWindowDockRuntimeSurface(surfaceId: panel.id, force: true))
        #expect(!dock.containsPanel(panel.id))
        #expect(panel.closeCount == 1)

        // Non-Dock surfaces fall through to the workspace close path untouched.
        #expect(!appDelegate.closeWindowDockRuntimeSurface(surfaceId: UUID(), force: true))
    }

    @Test("Window Dock close confirmation uses the owning window manager")
    @MainActor
    func windowDockCloseConfirmationUsesOwningWindowManager() async throws {
        // Async body (yield loop below): gate against the other suites' async
        // app-context tests so the swapped-in globals stay ours across awaits.
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let activeManager = TabManager(autoWelcomeIfNeeded: false)
            let dockManager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = activeManager
            let activeWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: activeManager)
            let dockWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: dockManager)
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: activeWindowId)
                appDelegate.unregisterMainWindowContextForTesting(windowId: dockWindowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: activeWindowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: dockWindowId)
                activeManager.tabs.forEach { $0.teardownAllPanels() }
                dockManager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let dock = appDelegate.windowDock(forWindowId: dockWindowId)
            let panel = WindowDockTestPanel()
            panel.isDirty = true
            try dock.seedTestPanel(panel)
            let tabId = try #require(dock.surfaceId(forPanelId: panel.id))
            let paneId = try #require(dock.paneId(forPanelId: panel.id))
            let tab = try #require(dock.bonsplitController.tabs(inPane: paneId).first { $0.id == tabId })

            var activeManagerPromptCount = 0
            activeManager.confirmCloseHandler = { _, _, _ in
                activeManagerPromptCount += 1
                return false
            }
            var dockManagerPromptCount = 0
            dockManager.confirmCloseHandler = { _, _, _ in
                dockManagerPromptCount += 1
                return false
            }

            #expect(!dock.splitTabBar(dock.bonsplitController, shouldCloseTab: tab, inPane: paneId))
            for _ in 0..<10 where dockManagerPromptCount == 0 {
                await Task.yield()
            }

            #expect(dockManagerPromptCount == 1)
            #expect(activeManagerPromptCount == 0)
            #expect(dock.containsPanel(panel.id))
        }
    }

    @Test("Triggering flash on a Dock panel does not change Dock focus")
    @MainActor
    func triggerFlashDoesNotChangeDockFocus() throws {
        try withIsolatedAppDelegate { appDelegate in
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                manager.tabs.forEach { $0.teardownAllPanels() }
            }
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let focusedPanel = try dock.seedTestPanel()
            let flashedPanel = try dock.seedTestPanel()
            dock.focusPanel(focusedPanel.id)

            #expect(dock.focusedPanelId == focusedPanel.id)
            dock.triggerFocusFlash(panelId: flashedPanel.id)

            #expect(flashedPanel.flashCount == 1)
            #expect(flashedPanel.focusCount == 0)
            #expect(dock.focusedPanelId == focusedPanel.id)
        }
    }

    @Test("External drop can move a window's last main panel into its own Dock")
    @MainActor
    func externalDropMovesLastMainPanelIntoOwnWindowDock() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
        }

        let workspace = try #require(manager.tabs.first)
        #expect(manager.tabs.count == 1)
        #expect(workspace.panels.count == 1)
        let panelId = try #require(workspace.panels.keys.first)
        let bonsplitTabId = try #require(workspace.surfaceIdFromPanelId(panelId))
        let sourcePane = try #require(workspace.paneId(forPanelId: panelId))
        let dock = appDelegate.windowDock(forWindowId: windowId)
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)

        // Mirrors Bonsplit's external drop callback after a Dock pane has
        // already accepted hover for a tab dragged from the main split area.
        let moved = dock.bonsplitController.onExternalTabDrop?(.init(
            tabId: bonsplitTabId,
            sourcePaneId: sourcePane,
            destination: .insert(targetPane: dockPane, targetIndex: nil)
        )) ?? false

        #expect(moved)
        #expect(workspace.panels[panelId] == nil)
        #expect(dock.containsPanel(panelId))
        #expect(workspace.panels.count == 1)
        let replacementPanelId = try #require(workspace.panels.keys.first)
        #expect(replacementPanelId != panelId)
        #expect(workspace.surfaceIdFromPanelId(replacementPanelId) != nil)
        #expect(appDelegate.existingWindowDock(forWindowId: windowId) === dock)
    }

    @Test("External drop keeps remote tmux mirror panes out of Dock")
    @MainActor
    func externalDropIntoOwnWindowDockRejectsRemoteTmuxMirrorPanel() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
        }

        let workspace = try #require(manager.tabs.first)
        workspace.isRemoteTmuxMirror = true
        let panelId = try #require(workspace.panels.keys.first)
        let bonsplitTabId = try #require(workspace.surfaceIdFromPanelId(panelId))
        let sourcePane = try #require(workspace.paneId(forPanelId: panelId))
        let dock = appDelegate.windowDock(forWindowId: windowId)
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)

        let moved = dock.bonsplitController.onExternalTabDrop?(.init(
            tabId: bonsplitTabId,
            sourcePaneId: sourcePane,
            destination: .insert(targetPane: dockPane, targetIndex: nil)
        )) ?? false

        #expect(!moved)
        #expect(!dock.containsPanel(panelId))
        #expect(workspace.panels[panelId] != nil)
        #expect(workspace.isRemoteTmuxMirror)
        #expect(workspace.panels.count == 1)
    }

    @Test("Docks in two windows render simultaneously without render-host gating")
    @MainActor
    func windowDocksRenderSimultaneouslyInBothWindows() throws {
        try withIsolatedAppDelegate { appDelegate in
            let firstManager = TabManager(autoWelcomeIfNeeded: false)
            let secondManager = TabManager(autoWelcomeIfNeeded: false)
            let firstWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: firstManager)
            let secondWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: secondManager)
            defer {
                firstManager.tabs.forEach { $0.teardownAllPanels() }
                secondManager.tabs.forEach { $0.teardownAllPanels() }
            }
            let firstDock = appDelegate.windowDock(forWindowId: firstWindowId)
            let secondDock = appDelegate.windowDock(forWindowId: secondWindowId)
            let firstPanel = try firstDock.seedTestPanel()
            let secondPanel = try secondDock.seedTestPanel()

            // Each window's Dock panel marks its own store visible independently —
            // the retired single Global Dock had one render host, so a second host
            // was gated behind an inactive placeholder instead of live content.
            firstDock.setVisibleInUI(true, hostId: UUID())
            secondDock.setVisibleInUI(true, hostId: UUID())

            #expect(firstDock.isVisibleInUI)
            #expect(secondDock.isVisibleInUI)
            #expect(firstPanel.focusCount == 1)
            #expect(secondPanel.focusCount == 1)
        }
    }
}
