import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Ctrl-Tab / Ctrl-Shift-Tab, Next/Previous Surface (Cmd-Shift-] / [) and the View menu items
/// step the focused pane's tabs and never change the selected sidebar workspace, whether the
/// pane holds one tab or several, in the main tree or the Dock. #18939 sent a one-tab pane to
/// the next workspace; Next/Previous Workspace stay the only workspace-stepping keys.
@MainActor
@Suite(.serialized)
struct TabStepShortcutsStayInPaneTests {
    private typealias Harness = DockShortcutRoutingTests.Harness

    private static let controlTab = DockRoutingStoredShortcut(
        key: "\t", command: false, shift: false, option: false, control: true
    )
    private static let controlShiftTab = DockRoutingStoredShortcut(
        key: "\t", command: false, shift: true, option: false, control: true
    )
    private static let nextSurface = DockRoutingStoredShortcut(
        key: "]", command: true, shift: true, option: false, control: false
    )
    private static let previousSurface = DockRoutingStoredShortcut(
        key: "[", command: true, shift: true, option: false, control: false
    )
    private static let forwardStrokes = [controlTab, nextSurface]
    private static let backwardStrokes = [controlShiftTab, previousSurface]

    @Test("A one-tab main pane keeps the workspace for every tab-step key")
    func oneTabMainPaneKeepsWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await DockShortcutRoutingTests.withHarness { harness in
                let other = try Self.addBackgroundWorkspaces(to: harness)
                let panel = try #require(harness.mainWorkspace.focusedPanelId)
                try Self.focusMain(panel, in: harness)

                for stroke in Self.forwardStrokes + Self.backwardStrokes {
                    #expect(DockShortcutRoutingTests.dispatch(stroke, in: harness))
                    #expect(harness.tabManager.selectedTabId == harness.mainWorkspace.id, "\(stroke) left the workspace")
                    #expect(harness.mainWorkspace.focusedPanelId == panel)
                }
                #expect(!other.contains(harness.tabManager.selectedTabId ?? UUID()))
            }
        }
    }

    @Test("A two-tab main pane steps its tabs, wrapping, and keeps the workspace")
    func twoTabMainPaneStepsTabs() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await DockShortcutRoutingTests.withHarness { harness in
                _ = try Self.addBackgroundWorkspaces(to: harness)
                let workspace = harness.mainWorkspace
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
                let order = workspace.bonsplitController.tabs(inPane: pane).compactMap {
                    workspace.panelIdFromSurfaceId($0.id)
                }
                #expect(order.count == 2)

                for (forward, backward) in zip(Self.forwardStrokes, Self.backwardStrokes) {
                    try Self.focusMain(order[0], in: harness)
                    workspace.focusPanel(order[0])
                    try #require(workspace.focusedPanelId == order[0])
                    #expect(DockShortcutRoutingTests.dispatch(forward, in: harness))
                    #expect(workspace.focusedPanelId == order[1], "\(forward) did not step the pane")
                    #expect(DockShortcutRoutingTests.dispatch(forward, in: harness))
                    #expect(workspace.focusedPanelId == order[0], "\(forward) did not wrap in the pane")
                    #expect(DockShortcutRoutingTests.dispatch(backward, in: harness))
                    #expect(workspace.focusedPanelId == order[1], "\(backward) did not wrap back")
                    #expect(harness.tabManager.selectedTabId == workspace.id)
                }
            }
        }
    }

    @Test("Rebinding or clearing Next/Previous Surface never falls through to a workspace step")
    func clearedOrReboundSurfaceShortcutsKeepWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await DockShortcutRoutingTests.withHarness { harness in
                _ = try Self.addBackgroundWorkspaces(to: harness)
                let panel = try #require(harness.mainWorkspace.focusedPanelId)
                try Self.focusMain(panel, in: harness)

                KeyboardShortcutSettings.setShortcut(.unbound, for: .nextSurface)
                KeyboardShortcutSettings.setShortcut(.unbound, for: .prevSurface)
                for stroke in Self.forwardStrokes + Self.backwardStrokes {
                    _ = DockShortcutRoutingTests.dispatch(stroke, in: harness)
                    #expect(harness.tabManager.selectedTabId == harness.mainWorkspace.id, "cleared: \(stroke)")
                }

                let custom = DockShortcutRoutingTests.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(custom, for: .nextSurface)
                for stroke in [custom] + Self.forwardStrokes + Self.backwardStrokes {
                    _ = DockShortcutRoutingTests.dispatch(stroke, in: harness)
                    #expect(harness.tabManager.selectedTabId == harness.mainWorkspace.id, "rebound: \(stroke)")
                }
            }
        }
    }

    @Test("A one-tab Dock pane keeps the workspace and the Dock tab")
    func oneTabDockPaneKeepsWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await DockShortcutRoutingTests.withHarness { harness in
                _ = try Self.addBackgroundWorkspaces(to: harness)
                let panel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let mainPanel = harness.mainWorkspace.focusedPanelId

                for stroke in Self.forwardStrokes + Self.backwardStrokes {
                    #expect(DockShortcutRoutingTests.dispatch(stroke, in: harness))
                    #expect(harness.tabManager.selectedTabId == harness.mainWorkspace.id, "\(stroke) left the workspace")
                    #expect(harness.dock.focusedPanelId == panel)
                    #expect(harness.mainWorkspace.focusedPanelId == mainPanel)
                }
            }
        }
    }

    @Test("A two-tab Dock pane steps the Dock's tabs and keeps the workspace")
    func twoTabDockPaneStepsDockTabs() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await DockShortcutRoutingTests.withHarness { harness in
                _ = try Self.addBackgroundWorkspaces(to: harness)
                let first = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let second = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )

                for (forward, backward) in zip(Self.forwardStrokes, Self.backwardStrokes) {
                    harness.dock.focusPanel(first)
                    #expect(DockShortcutRoutingTests.dispatch(forward, in: harness))
                    #expect(harness.dock.focusedPanelId == second, "\(forward) did not step the Dock")
                    #expect(DockShortcutRoutingTests.dispatch(backward, in: harness))
                    #expect(harness.dock.focusedPanelId == first, "\(backward) did not step the Dock back")
                    #expect(harness.tabManager.selectedTabId == harness.mainWorkspace.id)
                }
            }
        }
    }

    /// The View menu's Next/Previous Surface items call `AppDelegate.stepFocusedSurface`, which
    /// #18939 had replaced with the workspace fallthrough.
    @Test("The View menu items step pane tabs and keep the workspace, main tree and Dock")
    func viewMenuSurfaceStepsKeepWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await DockShortcutRoutingTests.withHarness { harness in
                _ = try Self.addBackgroundWorkspaces(to: harness)
                let workspace = harness.mainWorkspace
                let app = harness.appDelegate
                func menu(_ forward: Bool) {
                    app.stepFocusedSurface(
                        forward: forward, tabManager: harness.tabManager, preferredWindow: harness.window
                    )
                }

                // One-tab main pane.
                let first = try #require(workspace.focusedPanelId)
                try Self.focusMain(first, in: harness)
                for forward in [true, false] {
                    menu(forward)
                    #expect(harness.tabManager.selectedTabId == workspace.id, "one-tab main, forward=\(forward)")
                    #expect(workspace.focusedPanelId == first)
                }

                // Two-tab main pane.
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
                let order = workspace.bonsplitController.tabs(inPane: pane).compactMap {
                    workspace.panelIdFromSurfaceId($0.id)
                }
                try #require(order.count == 2)
                workspace.focusPanel(order[0])
                try Self.focusMain(order[0], in: harness)
                menu(true)
                #expect(workspace.focusedPanelId == order[1])
                menu(false)
                #expect(workspace.focusedPanelId == order[0])
                #expect(harness.tabManager.selectedTabId == workspace.id)

                // One-tab, then two-tab, Dock pane.
                harness.fileExplorerState.setVisible(true)
                harness.fileExplorerState.mode = .dock
                app.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: harness.window)
                let dockFirst = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                try #require(app.focusedDockStoreForShortcut(preferredWindow: harness.window) === harness.dock)
                for forward in [true, false] {
                    menu(forward)
                    #expect(harness.tabManager.selectedTabId == workspace.id, "one-tab Dock, forward=\(forward)")
                    #expect(harness.dock.focusedPanelId == dockFirst)
                }
                let dockSecond = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(dockFirst)
                menu(true)
                #expect(harness.dock.focusedPanelId == dockSecond)
                menu(false)
                #expect(harness.dock.focusedPanelId == dockFirst)
                #expect(harness.tabManager.selectedTabId == workspace.id)
                #expect(workspace.focusedPanelId == order[0])
            }
        }
    }

    /// Two more sidebar workspaces, so a stray workspace step would change the selection.
    private static func addBackgroundWorkspaces(to harness: Harness) throws -> Set<UUID> {
        var ids: Set<UUID> = []
        for _ in 0..<2 {
            let workspace = try #require(harness.tabManager.addWorkspaceIfActive(
                select: false, placementOverride: .end,
                autoWelcomeIfNeeded: false, autoRefreshMetadata: false
            ))
            ids.insert(workspace.id)
        }
        harness.tabManager.selectWorkspace(harness.mainWorkspace)
        try #require(harness.tabManager.tabs.count == 3)
        try #require(harness.tabManager.selectedTabId == harness.mainWorkspace.id)
        return ids
    }

    /// Hands keyboard ownership from the harness's Dock to a main-tree panel.
    private static func focusMain(_ panelId: UUID, in harness: Harness) throws {
        harness.fileExplorerState.setVisible(false)
        harness.fileExplorerState.mode = .files
        harness.appDelegate.noteMainPanelKeyboardFocusIntent(
            workspaceId: harness.mainWorkspace.id,
            panelId: panelId,
            in: harness.window
        )
        try #require(harness.appDelegate.focusedDockStoreForShortcut(preferredWindow: harness.window) == nil)
    }
}
