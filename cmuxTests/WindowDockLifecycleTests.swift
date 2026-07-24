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
        surfaceIdToPanelId[tabId] = panel.id
        return panel
    }
}

/// Per-window Dock registry lifecycle: every main window owns an independent
/// `DockSplitStore` (created lazily, owner id == window id) that is torn down
/// with its window, and multiple windows render their Docks simultaneously —
/// there is no cross-window render-host gating.
/// See https://github.com/manaflow-ai/cmux/issues/7142.
@Suite("Per-window Dock lifecycle", .serialized)
struct WindowDockLifecycleTests {
    @MainActor
    private func withIsolatedAppDelegate(_ body: (AppDelegate) throws -> Void) rethrows {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer {
            for context in Array(appDelegate.mainWindowContexts.values) {
                appDelegate.unregisterMainWindowContextForTesting(windowId: context.windowId)
            }
            AppDelegate.shared = previousAppDelegate
        }
        try body(appDelegate)
    }

    @Test("Closing a main window refuses to discard a failed note autosave")
    @MainActor
    func mainWindowCloseRefusesFailedNoteAutosave() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-window-close-note-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try "block".write(to: blocker, atomically: true, encoding: .utf8)

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        AppDelegate.shared = appDelegate
        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        let workspace = try #require(manager.selectedWorkspace)
        let dock = WorkspaceFloatingDock(
            id: UUID(),
            workspaceId: workspace.id,
            title: "Unsaved note",
            frame: CGRect(x: 0, y: 0, width: 520, height: 380),
            noteFilePath: blocker.appendingPathComponent("note.md").path,
            initialContent: .note,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        workspace.floatingDocks.append(dock)
        let note = try #require(dock.notePanel)
        await note.loadTextContent().value
        note.updateTextContent("must remain recoverable")
        defer {
            try? note.applyPersistedAutosavedTextContent("")
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            workspace.teardownAllPanels()
            window.orderOut(nil)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        #expect(appDelegate.closeMainWindow(windowId: windowId))
        for _ in 0..<20 where !note.hasAutosaveError {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(appDelegate.mainWindow(for: windowId) === window)
        #expect(note.isDirty)
        #expect(note.textContent == "must remain recoverable")
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

    @Test("Window Dock tears down with its window")
    @MainActor
    func windowDockTearsDownOnWindowUnregister() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        var unregistered = false
        defer {
            if !unregistered {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }
            manager.tabs.forEach { $0.teardownAllPanels() }
        }

        let dock = appDelegate.windowDock(forWindowId: windowId)
        let panel = try dock.seedTestPanel()
        let panelId = panel.id
        #expect(dock.containsPanel(panelId))
        #expect(AppDelegate.isWindowDockRoutingId(windowId))

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        unregistered = true

        // The store was dropped from the registry and its panels torn down —
        // no PTY outlives the window.
        #expect(appDelegate.existingWindowDock(forWindowId: windowId) == nil)
        #expect(!AppDelegate.isWindowDockRoutingId(windowId))
        #expect(!dock.containsPanel(panelId))
        #expect(dock.panels.isEmpty)
        #expect(!dock.isVisibleInUI)
        #expect(panel.closeCount == 1)
        // A closed window's manager can never seed a NEW Dock (it would have
        // no teardown owner); manager-based lookup fails closed instead.
        #expect(appDelegate.windowDock(for: manager) == nil)
    }

    @Test("Runtime close routes window Dock surfaces through the Dock store")
    @MainActor
    func runtimeCloseRoutesWindowDockTerminals() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
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

    @Test("Runtime close routes workspace floating Dock surfaces through their own store")
    @MainActor
    func runtimeCloseRoutesWorkspaceFloatingDockSurfaces() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
        }

        let workspace = try #require(manager.selectedWorkspace)
        let dock = try #require(workspace.createFloatingDock(initialContent: .note))
        let panel = try #require(dock.notePanel)

        #expect(appDelegate.closeWindowDockRuntimeSurface(surfaceId: panel.id, force: true))
        #expect(!dock.store.containsPanel(panel.id))
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

    @Test("Moving the last main panel preserves a workspace that owns floating Docks")
    @MainActor
    func externalDropPreservesSourceWorkspaceWithFloatingDock() throws {
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

        let sourceWorkspace = try #require(manager.tabs.first)
        let sourcePanelId = try #require(sourceWorkspace.panels.keys.first)
        let sourceTabId = try #require(sourceWorkspace.surfaceIdFromPanelId(sourcePanelId))
        let floatingDock = try #require(sourceWorkspace.createFloatingDock(initialContent: .note))
        let destinationWorkspace = manager.addWorkspace(
            initialSurface: .terminal,
            select: false,
            eagerLoadTerminal: true
        )
        let destinationDock = destinationWorkspace.dockSplit
        let destinationPane = try #require(destinationDock.bonsplitController.allPaneIds.first)

        let moved = appDelegate.moveSurfaceIntoDock(
            sourceTabId: sourceTabId.uuid,
            destinationDock: destinationDock,
            destination: .insert(targetPane: destinationPane, targetIndex: nil)
        )

        #expect(moved)
        #expect(manager.tabs.contains(where: { $0 === sourceWorkspace }))
        #expect(sourceWorkspace.floatingDock(id: floatingDock.id) === floatingDock)
        #expect(sourceWorkspace.panels[sourcePanelId] == nil)
        #expect(sourceWorkspace.panels.count == 1)
        #expect(destinationDock.containsPanel(sourcePanelId))
    }

    @Test("Floating Docks reject panels that cannot be restored")
    @MainActor
    func externalDropIntoFloatingDockRejectsUnsupportedPanel() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = manager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        let floatingDock = try #require(workspace.createFloatingDock(initialContent: .note))
        let destinationPane = try #require(floatingDock.store.bonsplitController.allPaneIds.first)
        let sourceDock = appDelegate.windowDock(forWindowId: windowId)
        let unsupportedPanel = try sourceDock.seedTestPanel()
        let sourceTabId = try #require(sourceDock.surfaceId(forPanelId: unsupportedPanel.id))

        #expect(!appDelegate.canMoveSurfaceIntoDock(
            sourceTabId: sourceTabId.uuid,
            destinationDock: floatingDock.store
        ))
        #expect(!appDelegate.moveSurfaceIntoDock(
            sourceTabId: sourceTabId.uuid,
            destinationDock: floatingDock.store,
            destination: .insert(targetPane: destinationPane, targetIndex: nil)
        ))
        #expect(sourceDock.containsPanel(unsupportedPanel.id))
        #expect(!floatingDock.store.containsPanel(unsupportedPanel.id))
    }

    @Test("Floating Dock browsers participate in WebView ownership lookup")
    @MainActor
    func floatingDockBrowserWebViewOwnership() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = manager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        let floatingDock = try #require(workspace.createFloatingDock(initialContent: .browser))
        let browser = try #require(floatingDock.store.panels.values.first as? BrowserPanel)
        let webView = try #require(browser.webView as? CmuxWebView)
        browser.searchState = BrowserSearchState()

        #expect(appDelegate.browserFindBarIsVisible(for: webView))
    }

    @Test("External drop keeps remote tmux mirror panes out of Dock")
    @MainActor
    func externalDropIntoOwnWindowDockRejectsRemoteTmuxMirrorPanel() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
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
