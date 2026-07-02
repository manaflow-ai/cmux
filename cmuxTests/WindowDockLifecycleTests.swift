import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Per-window Dock registry lifecycle: every main window owns an independent
/// `DockSplitStore` (created lazily, owner id == window id) that is torn down
/// with its window, and multiple windows render their Docks simultaneously —
/// there is no cross-window render-host gating.
/// See https://github.com/manaflow-ai/cmux/issues/7142.
@Suite("Per-window Dock lifecycle", .serialized)
struct WindowDockLifecycleTests {
    @Test("Each window gets its own independent Dock store")
    @MainActor
    func windowDocksAreIndependentPerWindow() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let firstManager = TabManager(autoWelcomeIfNeeded: false)
        let secondManager = TabManager(autoWelcomeIfNeeded: false)
        let firstWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: firstManager)
        let secondWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: secondManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: secondWindowId)
            firstManager.tabs.forEach { $0.teardownAllPanels() }
            secondManager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let firstDock = appDelegate.windowDock(forWindowId: firstWindowId)
        let secondDock = appDelegate.windowDock(forWindowId: secondWindowId)

        #expect(firstDock !== secondDock)
        #expect(firstDock.workspaceId == firstWindowId)
        #expect(secondDock.workspaceId == secondWindowId)
        #expect(firstDock.scope == .global)
        // Repeated access returns the same store, and manager-based lookup
        // resolves the same per-window instance.
        #expect(appDelegate.windowDock(forWindowId: firstWindowId) === firstDock)
        #expect(appDelegate.windowDock(for: firstManager) === firstDock)
        #expect(appDelegate.windowDock(for: secondManager) === secondDock)
        // Both owner ids route as Dock ids, as does the legacy alias.
        #expect(AppDelegate.isWindowDockRoutingId(firstWindowId))
        #expect(AppDelegate.isWindowDockRoutingId(secondWindowId))
        #expect(AppDelegate.isWindowDockRoutingId(AppDelegate.windowDockAliasWorkspaceId))
        #expect(!AppDelegate.isWindowDockRoutingId(UUID()))
    }

    @Test("Window Dock tears down with its window")
    @MainActor
    func windowDockTearsDownOnWindowUnregister() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        var unregistered = false
        defer {
            if !unregistered {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let dock = appDelegate.windowDock(forWindowId: windowId)
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        let panelId = try #require(dock.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        #expect(dock.containsPanel(panelId))

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        unregistered = true

        // The store was dropped from the registry and its panels torn down —
        // no PTY outlives the window.
        #expect(appDelegate.existingWindowDock(forWindowId: windowId) == nil)
        #expect(!AppDelegate.isWindowDockRoutingId(windowId))
        #expect(!dock.containsPanel(panelId))
        #expect(dock.panels.isEmpty)
        #expect(!dock.isVisibleInUI)
        // A closed window's manager can never seed a NEW Dock (it would have
        // no teardown owner); manager-based lookup fails closed instead.
        #expect(appDelegate.windowDock(for: manager) == nil)
        #expect(appDelegate.existingWindowDocks.isEmpty)
    }

    @Test("Moving a window's last main panel into its own Dock is rejected")
    @MainActor
    func lastPanelMoveIntoOwnWindowDockIsRejected() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        #expect(manager.tabs.count == 1)
        #expect(workspace.panels.count == 1)
        let panelId = try #require(workspace.panels.keys.first)
        let bonsplitTabId = try #require(workspace.surfaceIdFromPanelId(panelId))
        let dock = appDelegate.windowDock(forWindowId: windowId)
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)

        // Accepting the move would empty the window's only workspace, close the
        // window, and tear down the destination Dock with the moved surface in
        // it — so the move is rejected and the surface stays put.
        let moved = appDelegate.moveSurfaceIntoDock(
            sourceTabId: bonsplitTabId.uuid,
            destinationDock: dock,
            destination: .insert(targetPane: dockPane, targetIndex: nil)
        )
        #expect(!moved)
        #expect(workspace.panels[panelId] != nil)
        #expect(!dock.containsPanel(panelId))
        #expect(appDelegate.existingWindowDock(forWindowId: windowId) === dock)
    }

    @Test("Docks in two windows render simultaneously without render-host gating")
    @MainActor
    func windowDocksRenderSimultaneouslyInBothWindows() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let firstManager = TabManager(autoWelcomeIfNeeded: false)
        let secondManager = TabManager(autoWelcomeIfNeeded: false)
        let firstWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: firstManager)
        let secondWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: secondManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: secondWindowId)
            firstManager.tabs.forEach { $0.teardownAllPanels() }
            secondManager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let firstDock = appDelegate.windowDock(forWindowId: firstWindowId)
        let secondDock = appDelegate.windowDock(forWindowId: secondWindowId)
        let firstPane = try #require(firstDock.bonsplitController.allPaneIds.first)
        let secondPane = try #require(secondDock.bonsplitController.allPaneIds.first)
        let firstPanelId = try #require(firstDock.newSurface(kind: .terminal, inPane: firstPane, focus: true))
        let secondPanelId = try #require(secondDock.newSurface(kind: .terminal, inPane: secondPane, focus: true))
        let firstPanel = try #require(firstDock.panels[firstPanelId] as? TerminalPanel)
        let secondPanel = try #require(secondDock.panels[secondPanelId] as? TerminalPanel)

        // Each window's Dock panel activates its store independently — with the
        // retired single Global Dock, the second window showed an inactive-host
        // placeholder instead of live content.
        firstDock.setActive(isVisible: true, mode: .dock, visibilityHostId: UUID())
        secondDock.setActive(isVisible: true, mode: .dock, visibilityHostId: UUID())

        #expect(firstDock.isVisibleInUI)
        #expect(secondDock.isVisibleInUI)
        #expect(firstPanel.hostedView.debugPortalVisibleInUI)
        #expect(secondPanel.hostedView.debugPortalVisibleInUI)
    }
}
