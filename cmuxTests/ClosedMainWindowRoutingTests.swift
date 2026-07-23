import AppKit
import Bonsplit
import Combine
import CmuxSettings
import CmuxTerminal
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TabManager {
    /// Test-fixture convenience that keeps production callers on the optional,
    /// nontrapping workspace-acquisition boundary.
    @discardableResult
    func addWorkspace(
        title: String? = nil,
        workingDirectory: String? = nil,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:],
        initialBrowserURL: URL? = nil,
        initialBrowserOmnibarVisible: Bool = true,
        initialBrowserTransparentBackground: Bool = false,
        workspaceEnvironment: [String: String] = [:],
        inheritWorkingDirectory: Bool = true,
        select: Bool = true,
        eagerLoadTerminal: Bool = false,
        placementOverride: WorkspacePlacement? = nil,
        autoWelcomeIfNeeded: Bool = true,
        autoRefreshMetadata: Bool = true,
        normalizeWorkspaceGroupsAfterInsert: Bool = true,
        allowTextBoxFocusDefault: Bool = true
    ) -> Workspace {
        guard let workspace = addWorkspaceIfActive(
            title: title,
            workingDirectory: workingDirectory,
            initialSurface: initialSurface,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalInput: initialTerminalInput,
            initialTerminalEnvironment: initialTerminalEnvironment,
            initialBrowserURL: initialBrowserURL,
            initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
            initialBrowserTransparentBackground: initialBrowserTransparentBackground,
            workspaceEnvironment: workspaceEnvironment,
            inheritWorkingDirectory: inheritWorkingDirectory,
            select: select,
            eagerLoadTerminal: eagerLoadTerminal,
            placementOverride: placementOverride,
            autoWelcomeIfNeeded: autoWelcomeIfNeeded,
            autoRefreshMetadata: autoRefreshMetadata,
            normalizeWorkspaceGroupsAfterInsert: normalizeWorkspaceGroupsAfterInsert,
            allowTextBoxFocusDefault: allowTextBoxFocusDefault
        ) else {
            preconditionFailure("Test fixture cannot create a workspace on a finalized manager")
        }
        return workspace
    }
}

private final class NonDestructiveCloseWindow: NSWindow {
    private(set) var closeCallCount = 0

    override func close() {
        closeCallCount += 1
        orderOut(nil)
    }
}

@MainActor
@Suite("Closed main window routing", .serialized)
struct ClosedMainWindowRoutingTests {
    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    @Test("Closed main window is not listed or focusable while its objects linger")
    func closedMainWindowIsNotListedOrFocusableWhileItsObjectsLinger() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowAId)
            app.unregisterMainWindowContextForTesting(windowId: windowBId)
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        windowB.makeKeyAndOrderFront(nil)
        windowA.makeKeyAndOrderFront(nil)
        TerminalController.shared.setActiveTabManager(managerA)

        let workspaceB = try #require(managerB.selectedWorkspace)
        let terminalPanelB = try #require(workspaceB.focusedTerminalPanel)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanelB.id) === terminalPanelB.surface)
        var surfacePortPublicationCount = 0
        let surfacePortCancellable = workspaceB.$surfaceListeningPorts.dropFirst().sink { _ in
            surfacePortPublicationCount += 1
        }
        defer { surfacePortCancellable.cancel() }
        #expect(TerminalController.shared.applyAgentPortPublication(
            workspaceId: workspaceB.id,
            ports: [4200]
        ))
        TerminalController.shared.applyPanelPortPublication(
            workspaceId: workspaceB.id,
            panelId: terminalPanelB.id,
            ports: [4300]
        )
        TerminalController.shared.applyPanelPortPublication(
            workspaceId: workspaceB.id,
            panelId: terminalPanelB.id,
            ports: [4300]
        )
        #expect(workspaceB.agentListeningPorts == [4200])
        #expect(workspaceB.surfaceListeningPorts[terminalPanelB.id] == [4300])
        #expect(surfacePortPublicationCount == 1)

        let baselineSummaries = app.listMainWindowSummaries()
        #expect(baselineSummaries.contains { $0.windowId == windowAId })
        #expect(baselineSummaries.contains { $0.windowId == windowBId })

        app.unregisterMainWindowContextForTesting(windowId: windowBId)
        windowB.orderOut(nil)

        #expect(!windowB.isVisible)
        #expect(!windowB.isMiniaturized)
        #expect(!app.listMainWindowSummaries().contains { $0.windowId == windowBId })
        #expect(!app.focusMainWindow(windowId: windowBId))
        #expect(!windowB.isVisible)
        #expect(app.tabManagerFor(windowId: windowBId) == nil)
    }

    @Test("Recovered visible window stays listed and focusable")
    func recoveredVisibleWindowStaysListedAndFocusable() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowAId = UUID()
        let windowCId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowC = makeMainWindow(id: windowCId)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowAId)
            app.unregisterMainWindowContextForTesting(windowId: windowCId)
            windowA.orderOut(nil)
            windowC.orderOut(nil)
        }

        let managerA = TabManager()
        let managerC = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowC,
            windowId: windowCId,
            tabManager: managerC,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        windowA.makeKeyAndOrderFront(nil)
        windowC.makeKeyAndOrderFront(nil)
        TerminalController.shared.setActiveTabManager(managerA)

        let workspaceC = try #require(managerC.selectedWorkspace)
        let terminalPanelC = try #require(workspaceC.focusedTerminalPanel)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanelC.id) === terminalPanelC.surface)

        app.unregisterMainWindowContextForTesting(windowId: windowCId)

        #expect(windowC.isVisible)
        #expect(app.listMainWindowSummaries().contains { $0.windowId == windowCId })
        #expect(app.focusMainWindow(windowId: windowCId))
    }
}

@MainActor
@Suite("Recoverable windowless main window routing", .serialized)
struct RecoverableWindowlessMainWindowRoutingTests {
    @Test("Finalized manager rejects and tombstones a fresh visible window")
    func finalizedManagerRejectsAndTombstonesFreshVisibleWindow() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager()
        manager.finalizeAllWorkspacesForWindowClose()
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        #expect(window.isVisible)

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(!app.mainWindowContexts.values.contains { $0.windowId == windowId })
        #expect(!window.isVisible)
        #expect(app.hasCommittedMainWindowClose(window))
        #expect(!app.commitMainWindowClose(window))
        #expect(!app.commitMainWindowClose(window))
    }

    @Test("Finalized unowned manager cannot tombstone another manager's exact window")
    func finalizedUnownedManagerCannotTombstoneAnotherManagersExactWindow() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let owner = TabManager()
        let ownerWorkspace = try #require(owner.selectedWorkspace)
        let ownerPanel = try #require(ownerWorkspace.focusedTerminalPanel)
        let finalizedIntruder = TabManager()
        finalizedIntruder.finalizeAllWorkspacesForWindowClose()
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            ownerWorkspace.teardownAllPanels()
            ownerWorkspace.teardownRemoteConnection()
            window.orderOut(nil)
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: owner,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)
        #expect(app.tabManagerFor(windowId: windowId) === owner)
        #expect(window.isVisible)
        #expect(!app.hasCommittedMainWindowClose(window))

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: finalizedIntruder,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(app.tabManagerFor(windowId: windowId) === owner)
        #expect(app.mainWindowContexts.values.contains {
            $0.windowId == windowId && $0.tabManager === owner && $0.window === window
        })
        #expect(!owner.isFinalizedForWindowClose)
        #expect(owner.tabs.count == 1)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: ownerPanel.id) === ownerPanel.surface)
        #expect(window.isVisible)
        #expect(!app.hasCommittedMainWindowClose(window))
    }

    @Test("Transient windowless routing preserves the recoverable workspace")
    func transientWindowlessRoutingPreservesRecoverableWorkspace() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager()
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        TerminalController.shared.setActiveTabManager(manager)

        #expect(!app.toggleSidebarInActiveMainWindow())
        #expect(app.tabManagerFor(windowId: windowId) == nil)
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === manager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
    }

    @Test("Transient windowless route remains in session snapshots and autosave fingerprints")
    func transientWindowlessRouteRemainsSessionPersistedAndFingerprintStable() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager()
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        let workspace = try #require(manager.selectedWorkspace)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        let context = try #require(
            app.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        let baselineFingerprint = app.sessionAutosaveFingerprint(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )
        let baselineSnapshot = try #require(app.sessionSnapshotForTesting())
        #expect(baselineSnapshot.windows.map(\.windowId) == [windowId])

        // A registered context is authoritative while a recoverable entry
        // briefly overlaps it; persistence must neither duplicate the window
        // nor use the stale route's sidebar snapshot.
        app.rememberRecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: manager,
            window: nil,
            sidebarSnapshot: SessionSidebarSnapshot(
                isVisible: false,
                selection: .notifications,
                width: 480
            )
        )
        let overlappingSnapshot = try #require(app.sessionSnapshotForTesting())
        #expect(overlappingSnapshot.windows.map(\.windowId) == [windowId])
        #expect(overlappingSnapshot.windows[0].sidebar.isVisible == context.sidebarState.isVisible)
        #expect(overlappingSnapshot.windows[0].sidebar.selection == .tabs)
        #expect(
            app.sessionAutosaveFingerprint(
                includeScrollback: false,
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: .empty
            ) == baselineFingerprint
        )

        app.discardOrphanedMainWindowContext(context, allowWindowlessFallback: true)

        #expect(!app.mainWindowContexts.values.contains { $0.windowId == windowId })
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === manager)
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.window == nil)
        let windowlessSnapshot = try #require(app.sessionSnapshotForTesting())
        #expect(windowlessSnapshot.windows.map(\.windowId) == [windowId])
        #expect(windowlessSnapshot.windows[0].tabManager.workspaces.map(\.workspaceId) == [workspace.id])
        let windowlessFingerprint = app.sessionAutosaveFingerprint(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )
        #expect(windowlessFingerprint == baselineFingerprint)

        let addedWorkspace = manager.addWorkspace(initialSurface: .browser)
        let updatedSnapshot = try #require(app.sessionSnapshotForTesting())
        #expect(
            updatedSnapshot.windows[0].tabManager.workspaces.compactMap(\.workspaceId)
                == [workspace.id, addedWorkspace.id]
        )
        #expect(
            app.sessionAutosaveFingerprint(
                includeScrollback: false,
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: .empty
            ) != windowlessFingerprint
        )
    }

    @Test("Browser-only dead route is pruned on ledger access")
    func browserOnlyDeadRouteIsPrunedOnLedgerAccess() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        weak var deadManager: TabManager?
        weak var retainedRoute: RecoverableMainWindowRoute?

        do {
            let manager = TabManager()
            deadManager = manager
            let workspace = try #require(manager.selectedWorkspace)
            let terminal = try #require(workspace.focusedTerminalPanel)
            let paneId = try #require(
                workspace.bonsplitController.focusedPaneId
                    ?? workspace.bonsplitController.allPaneIds.first
            )
            let browser = try #require(
                workspace.newBrowserSurface(
                    inPane: paneId,
                    url: URL(string: "https://example.com/dead-browser-route"),
                    focus: true,
                    creationPolicy: .restoration
                )
            )
            #expect(workspace.closePanel(terminal.id, force: true))
            #expect(workspace.panels[browser.id] === browser)
            #expect(!workspace.panels.values.contains { $0 is TerminalPanel })

            app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            retainedRoute = try #require(app.recoverableMainWindowRoute(windowId: windowId))
            #expect(retainedRoute?.tabManager === manager)

            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        #expect(deadManager == nil)
        #expect(retainedRoute != nil)

        // No terminal existed when the manager died, so no terminal-registry
        // topology event can retire this route. Ledger access owns the sweep.
        #expect(app.recoverableMainWindowRoute(windowId: windowId) == nil)
        #expect(retainedRoute == nil)
    }

    @Test("Ordered-out recovery state is isolated from general window routing")
    func orderedOutRecoveryStateIsIsolatedFromGeneralWindowRouting() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager()
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            window.orderOut(nil)
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)
        let context = try #require(
            app.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        app.discardOrphanedMainWindowContext(context)
        window.orderOut(nil)

        #expect(!window.isVisible)
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === manager)
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.window === window)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
        #expect(app.tabManagerFor(windowId: windowId) == nil)
    }

    @Test("Stale duplicate cannot close a windowless recoverable owner")
    func staleDuplicateCannotCloseWindowlessRecoverableOwner() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager()
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        TerminalController.shared.setActiveTabManager(manager)
        #expect(!app.toggleSidebarInActiveMainWindow())
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.window == nil)

        let staleDuplicate = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        staleDuplicate.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        defer { staleDuplicate.orderOut(nil) }
        staleDuplicate.makeKeyAndOrderFront(nil)

        #expect(!app.commitMainWindowClose(staleDuplicate))
        #expect(!app.listMainWindowSummaries().contains { $0.windowId == windowId })
        #expect(!app.focusMainWindow(windowId: windowId))
        #expect(app.scriptableMainWindow(windowId: windowId) == nil)
        #expect(app.tabManagerFor(windowId: windowId) == nil)
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === manager)
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.window == nil)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
    }

    @Test("Windowless route reserves its ID and only its manager can reclaim it")
    func windowlessRouteReservesItsIdAndOnlyItsManagerCanReclaimIt() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let owner = TabManager()
        let windowId = app.registerMainWindowContextForTesting(tabManager: owner)
        let ownerWorkspace = try #require(owner.selectedWorkspace)
        let ownerPanel = try #require(ownerWorkspace.focusedTerminalPanel)
        let duplicateManager = TabManager()
        let duplicateWorkspace = try #require(duplicateManager.selectedWorkspace)
        let duplicatePanel = try #require(duplicateWorkspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            ownerWorkspace.teardownAllPanels()
            ownerWorkspace.teardownRemoteConnection()
            if !duplicateManager.isFinalizedForWindowClose {
                duplicateManager.finalizeAllWorkspacesForWindowClose()
            }
        }

        TerminalController.shared.setActiveTabManager(owner)
        #expect(!app.toggleSidebarInActiveMainWindow())
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === owner)
        #expect(app.availableWindowIdForNewMainWindow(preferredWindowId: windowId) == nil)

        let duplicateWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        duplicateWindow.isReleasedWhenClosed = false
        duplicateWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let replacementWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        replacementWindow.isReleasedWhenClosed = false
        replacementWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        defer {
            duplicateWindow.orderOut(nil)
            replacementWindow.orderOut(nil)
        }

        app.registerMainWindow(
            duplicateWindow,
            windowId: windowId,
            tabManager: duplicateManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(!app.mainWindowContexts.values.contains { $0.tabManager === duplicateManager })
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === owner)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: ownerPanel.id) === ownerPanel.surface)
        #expect(duplicateManager.isFinalizedForWindowClose)
        #expect(duplicateManager.tabs.isEmpty)
        #expect(duplicateWorkspace.isRetiredFromOwningTabManager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: duplicatePanel.id) == nil)

        app.registerMainWindow(
            replacementWindow,
            windowId: windowId,
            tabManager: owner,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(app.recoverableMainWindowRoute(windowId: windowId) == nil)
        #expect(app.mainWindowContexts.values.contains { $0.windowId == windowId && $0.tabManager === owner })
    }

    @Test("Browser-only windowless route reserves its ID against a foreign manager")
    func browserOnlyWindowlessRouteReservesItsIdAgainstForeignManager() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let owner = TabManager()
        let ownerWorkspace = try #require(owner.selectedWorkspace)
        let ownerTerminal = try #require(ownerWorkspace.focusedTerminalPanel)
        let ownerPaneId = try #require(
            ownerWorkspace.bonsplitController.focusedPaneId
                ?? ownerWorkspace.bonsplitController.allPaneIds.first
        )
        let ownerBrowser = try #require(
            ownerWorkspace.newBrowserSurface(
                inPane: ownerPaneId,
                url: URL(string: "https://example.com/browser-only-owner"),
                focus: true,
                creationPolicy: .restoration
            )
        )
        #expect(ownerWorkspace.closePanel(ownerTerminal.id, force: true))
        #expect(ownerWorkspace.panels[ownerBrowser.id] === ownerBrowser)
        #expect(!ownerWorkspace.panels.values.contains { $0 is TerminalPanel })

        let windowId = app.registerMainWindowContextForTesting(tabManager: owner)
        let foreignManager = TabManager()
        let foreignWorkspace = try #require(foreignManager.selectedWorkspace)
        let foreignTerminal = try #require(foreignWorkspace.focusedTerminalPanel)
        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        foreignWindow.isReleasedWhenClosed = false
        foreignWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            ownerWorkspace.teardownAllPanels()
            ownerWorkspace.teardownRemoteConnection()
            if !foreignManager.isFinalizedForWindowClose {
                foreignManager.finalizeAllWorkspacesForWindowClose()
            }
            foreignWindow.orderOut(nil)
        }

        app.unregisterMainWindowContextForTesting(windowId: windowId)

        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === owner)
        #expect(app.availableWindowIdForNewMainWindow(preferredWindowId: windowId) == nil)
        #expect(app.tabManagerFor(windowId: windowId) == nil)
        #expect(!app.listMainWindowSummaries().contains { $0.windowId == windowId })
        #expect(!app.focusMainWindow(windowId: windowId))
        #expect(app.scriptableMainWindow(windowId: windowId) == nil)

        foreignWindow.makeKeyAndOrderFront(nil)
        app.registerMainWindow(
            foreignWindow,
            windowId: windowId,
            tabManager: foreignManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === owner)
        #expect(!app.mainWindowContexts.values.contains { $0.windowId == windowId })
        #expect(app.tabManagerFor(windowId: windowId) == nil)
        #expect(!app.listMainWindowSummaries().contains { $0.windowId == windowId })
        #expect(!app.focusMainWindow(windowId: windowId))
        #expect(app.scriptableMainWindow(windowId: windowId) == nil)
        #expect(!owner.isFinalizedForWindowClose)
        #expect(owner.tabs.map(\.id) == [ownerWorkspace.id])
        #expect(ownerWorkspace.panels[ownerBrowser.id] === ownerBrowser)
        #expect(foreignManager.isFinalizedForWindowClose)
        #expect(foreignManager.tabs.isEmpty)
        #expect(foreignWorkspace.isRetiredFromOwningTabManager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: foreignTerminal.id) == nil)
        #expect(!foreignWindow.isVisible)
    }

    @Test("Stale callback cannot reassign an owned window to a recoverable ID")
    func staleCallbackCannotReassignOwnedWindowToRecoverableId() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowAId = UUID()
        let managerA = TabManager()
        let workspaceA = try #require(managerA.selectedWorkspace)
        app.registerMainWindowContextForTesting(windowId: windowAId, tabManager: managerA)
        app.unregisterMainWindowContextForTesting(windowId: windowAId)
        #expect(app.recoverableMainWindowRoute(windowId: windowAId)?.tabManager === managerA)

        let windowBId = UUID()
        let windowB = NonDestructiveCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        windowB.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowBId.uuidString)")
        let managerB = TabManager()
        let workspaceB = try #require(managerB.selectedWorkspace)
        let panelB = try #require(workspaceB.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowBId)
            app.forgetRecoverableMainWindowRoute(windowId: windowAId)
            if !managerA.isFinalizedForWindowClose {
                managerA.finalizeAllWorkspacesForWindowClose()
            }
            if !managerB.isFinalizedForWindowClose {
                managerB.finalizeAllWorkspacesForWindowClose()
            }
            workspaceA.teardownAllPanels()
            workspaceA.teardownRemoteConnection()
            workspaceB.teardownAllPanels()
            workspaceB.teardownRemoteConnection()
            windowB.orderOut(nil)
        }

        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        windowB.makeKeyAndOrderFront(nil)

        // A stale SwiftUI callback carries B's exact native window and manager,
        // but A's reserved id. Exact ownership must reject the entire tuple
        // without falling through to A's mismatch branch and closing B.
        app.registerMainWindow(
            windowB,
            windowId: windowAId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(windowB.closeCallCount == 0)
        #expect(windowB.isVisible)
        #expect(!managerB.isFinalizedForWindowClose)
        #expect(app.tabManagerFor(windowId: windowBId) === managerB)
        #expect(app.mainWindowContexts.values.contains {
            $0.windowId == windowBId && $0.tabManager === managerB && $0.window === windowB
        })
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: panelB.id) === panelB.surface)
        #expect(app.recoverableMainWindowRoute(windowId: windowAId)?.tabManager === managerA)
        #expect(!managerA.isFinalizedForWindowClose)
        #expect(managerA.tabs.map(\.id) == [workspaceA.id])
    }

    @Test("Windowless registered context rejects a foreign manager")
    func windowlessRegisteredContextRejectsForeignManager() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let owner = TabManager()
        let ownerWorkspace = try #require(owner.selectedWorkspace)
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: owner)

        let foreignWindow = NonDestructiveCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        foreignWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let foreign = TabManager()
        let foreignWorkspace = try #require(foreign.selectedWorkspace)
        let foreignPanel = try #require(foreignWorkspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            if !owner.isFinalizedForWindowClose {
                owner.finalizeAllWorkspacesForWindowClose()
            }
            if !foreign.isFinalizedForWindowClose {
                foreign.finalizeAllWorkspacesForWindowClose()
            }
            ownerWorkspace.teardownAllPanels()
            ownerWorkspace.teardownRemoteConnection()
            foreignWorkspace.teardownAllPanels()
            foreignWorkspace.teardownRemoteConnection()
            foreignWindow.orderOut(nil)
        }

        app.registerMainWindow(
            foreignWindow,
            windowId: windowId,
            tabManager: foreign,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(foreignWindow.closeCallCount == 1)
        #expect(!foreignWindow.isVisible)
        #expect(foreign.isFinalizedForWindowClose)
        #expect(foreign.tabs.isEmpty)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: foreignPanel.id) == nil)
        #expect(app.tabManagerFor(windowId: windowId) === owner)
        #expect(app.mainWindowContexts.values.contains {
            $0.windowId == windowId && $0.tabManager === owner && $0.window == nil
        })
        #expect(!owner.isFinalizedForWindowClose)
        #expect(owner.tabs.map(\.id) == [ownerWorkspace.id])
    }

    @Test("Visible owner rejects a duplicate manager and retires its terminal graph")
    func visibleOwnerRejectsDuplicateManagerAndRetiresItsTerminalGraph() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let ownerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        ownerWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let duplicateWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        duplicateWindow.isReleasedWhenClosed = false
        duplicateWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")

        let owner = TabManager()
        let ownerWorkspace = try #require(owner.selectedWorkspace)
        let ownerPanel = try #require(ownerWorkspace.focusedTerminalPanel)
        let duplicateManager = TabManager()
        let duplicateWorkspace = try #require(duplicateManager.selectedWorkspace)
        let duplicatePanel = try #require(duplicateWorkspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            ownerWorkspace.teardownAllPanels()
            ownerWorkspace.teardownRemoteConnection()
            if !duplicateManager.isFinalizedForWindowClose {
                duplicateManager.finalizeAllWorkspacesForWindowClose()
            }
            ownerWindow.orderOut(nil)
            duplicateWindow.orderOut(nil)
        }

        app.registerMainWindow(
            ownerWindow,
            windowId: windowId,
            tabManager: owner,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        ownerWindow.makeKeyAndOrderFront(nil)

        app.registerMainWindow(
            duplicateWindow,
            windowId: windowId,
            tabManager: duplicateManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(app.tabManagerFor(windowId: windowId) === owner)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: ownerPanel.id) === ownerPanel.surface)
        #expect(duplicateManager.isFinalizedForWindowClose)
        #expect(duplicateManager.tabs.isEmpty)
        #expect(duplicateWorkspace.isRetiredFromOwningTabManager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: duplicatePanel.id) == nil)
    }

    @Test("Rejected manager keeps running when another main window owns it")
    func rejectedManagerKeepsRunningWhenAnotherMainWindowOwnsIt() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let reservedWindowId = UUID()
        let reservedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        reservedWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(reservedWindowId.uuidString)")
        let reservedOwner = TabManager()
        let reservedWorkspace = try #require(reservedOwner.selectedWorkspace)
        let reservedPanel = try #require(reservedWorkspace.focusedTerminalPanel)

        let existingWindowId = UUID()
        let existingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        existingWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(existingWindowId.uuidString)")
        let duplicateWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        duplicateWindow.isReleasedWhenClosed = false
        duplicateWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(reservedWindowId.uuidString)")
        let sharedManager = TabManager()
        let sharedWorkspace = try #require(sharedManager.selectedWorkspace)
        let sharedPanel = try #require(sharedWorkspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: reservedWindowId)
            app.unregisterMainWindowContextForTesting(windowId: existingWindowId)
            reservedWorkspace.teardownAllPanels()
            reservedWorkspace.teardownRemoteConnection()
            sharedWorkspace.teardownAllPanels()
            sharedWorkspace.teardownRemoteConnection()
            reservedWindow.orderOut(nil)
            existingWindow.orderOut(nil)
            duplicateWindow.orderOut(nil)
        }

        app.registerMainWindow(
            reservedWindow,
            windowId: reservedWindowId,
            tabManager: reservedOwner,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        reservedWindow.makeKeyAndOrderFront(nil)
        app.registerMainWindow(
            existingWindow,
            windowId: existingWindowId,
            tabManager: sharedManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        existingWindow.makeKeyAndOrderFront(nil)

        app.registerMainWindow(
            duplicateWindow,
            windowId: reservedWindowId,
            tabManager: sharedManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(!sharedManager.isFinalizedForWindowClose)
        #expect(sharedManager.tabs.count == 1)
        #expect(app.tabManagerFor(windowId: existingWindowId) === sharedManager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: sharedPanel.id) === sharedPanel.surface)
        #expect(app.tabManagerFor(windowId: reservedWindowId) === reservedOwner)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: reservedPanel.id) === reservedPanel.surface)
    }

    @Test("Fresh window cannot alias a live owner's manager")
    func freshWindowCannotAliasLiveOwnersManager() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let ownerWindowId = UUID()
        let ownerWindow = NonDestructiveCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        ownerWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(ownerWindowId.uuidString)")

        let aliasWindowId = UUID()
        let aliasWindow = NonDestructiveCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        aliasWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(aliasWindowId.uuidString)")

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: aliasWindowId)
            app.unregisterMainWindowContextForTesting(windowId: ownerWindowId)
            app.forgetRecoverableMainWindowRoute(windowId: aliasWindowId)
            app.forgetRecoverableMainWindowRoute(windowId: ownerWindowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            ownerWindow.orderOut(nil)
            aliasWindow.orderOut(nil)
        }

        app.registerMainWindow(
            ownerWindow,
            windowId: ownerWindowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        ownerWindow.makeKeyAndOrderFront(nil)
        aliasWindow.makeKeyAndOrderFront(nil)

        app.registerMainWindow(
            aliasWindow,
            windowId: aliasWindowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(aliasWindow.closeCallCount == 1)
        #expect(!aliasWindow.isVisible)
        #expect(!app.commitMainWindowClose(aliasWindow))
        #expect(!manager.isFinalizedForWindowClose)
        #expect(manager.window === ownerWindow)
        #expect(manager.tabs.map(\.id) == [workspace.id])
        #expect(app.tabManagerFor(windowId: ownerWindowId) === manager)
        #expect(app.tabManagerFor(windowId: aliasWindowId) == nil)
        #expect(app.mainWindowContexts.values.filter { $0.tabManager === manager }.count == 1)
        #expect(app.mainWindowContexts.values.contains {
            $0.windowId == ownerWindowId && $0.tabManager === manager && $0.window === ownerWindow
        })
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
    }

    @Test("Fresh window cannot alias a windowless recoverable owner's manager")
    func freshWindowCannotAliasWindowlessRecoverableOwnersManager() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let ownerWindowId = UUID()
        let ownerWindow = NonDestructiveCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        ownerWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(ownerWindowId.uuidString)")

        let aliasWindowId = UUID()
        let aliasWindow = NonDestructiveCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        aliasWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(aliasWindowId.uuidString)")

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: aliasWindowId)
            app.unregisterMainWindowContextForTesting(windowId: ownerWindowId)
            app.forgetRecoverableMainWindowRoute(windowId: aliasWindowId)
            app.forgetRecoverableMainWindowRoute(windowId: ownerWindowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            ownerWindow.orderOut(nil)
            aliasWindow.orderOut(nil)
        }

        app.registerMainWindow(
            ownerWindow,
            windowId: ownerWindowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        ownerWindow.makeKeyAndOrderFront(nil)
        let ownerContext = try #require(
            app.mainWindowContexts.values.first { $0.windowId == ownerWindowId }
        )
        app.discardOrphanedMainWindowContext(ownerContext)
        let ownerRoute = try #require(app.recoverableMainWindowRoute(windowId: ownerWindowId))
        ownerRoute.window = nil
        ownerWindow.identifier = nil
        ownerWindow.orderOut(nil)
        aliasWindow.makeKeyAndOrderFront(nil)

        app.registerMainWindow(
            aliasWindow,
            windowId: aliasWindowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(aliasWindow.closeCallCount == 1)
        #expect(!aliasWindow.isVisible)
        #expect(!app.commitMainWindowClose(aliasWindow))
        #expect(!manager.isFinalizedForWindowClose)
        #expect(manager.tabs.map(\.id) == [workspace.id])
        #expect(app.recoverableMainWindowRoute(windowId: ownerWindowId)?.tabManager === manager)
        #expect(app.tabManagerFor(windowId: aliasWindowId) == nil)
        #expect(!app.mainWindowContexts.values.contains { $0.tabManager === manager })
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
    }
}

@MainActor
@Suite("Ghost main window context lifecycle", .serialized)
struct GhostMainWindowContextLifecycleTests {
    private func expectRetiredWorkspaceRejectsPanelCreation(
        named operation: String,
        _ createPanel: (Workspace, PaneID) -> UUID?
    ) throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(
            workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first
        )
        defer {
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        manager.finalizeAllWorkspacesForWindowClose()
        #expect(workspace.isRetiredFromOwningTabManager)
        #expect(workspace.bonsplitController.allPaneIds.contains(paneId))
        let paneIdsAfterRetirement = workspace.bonsplitController.allPaneIds
        let tabIdsByPaneAfterRetirement = Dictionary(
            uniqueKeysWithValues: paneIdsAfterRetirement.map { paneId in
                (paneId.id, workspace.bonsplitController.tabs(inPane: paneId).map(\.id))
            }
        )

        let latePanelId = createPanel(workspace, paneId)
        let message = Comment(rawValue: "\(operation) repopulated a retired workspace")

        #expect(latePanelId == nil, message)
        #expect(workspace.panels.isEmpty, message)
        #expect(workspace.bonsplitController.allPaneIds == paneIdsAfterRetirement, message)
        #expect(
            Dictionary(
                uniqueKeysWithValues: workspace.bonsplitController.allPaneIds.map { paneId in
                    (paneId.id, workspace.bonsplitController.tabs(inPane: paneId).map(\.id))
                }
            ) == tabIdsByPaneAfterRetirement,
            message
        )
        #expect(manager.tabs.isEmpty, message)
    }

    private func makeMainWindow(id: UUID) -> NonDestructiveCloseWindow {
        let window = NonDestructiveCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    @Test("Finalized manager rejects startup workspace recovery")
    func finalizedManagerRejectsStartupWorkspaceRecovery() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        manager.finalizeAllWorkspacesForWindowClose()

        #expect(!manager.recoverEmptyWorkspaceAfterStartupIfNeeded())
        #expect(manager.tabs.isEmpty)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) == nil)
    }

    @Test("Activating the first main window retires the unowned launch bootstrap manager")
    func activatingFirstMainWindowRetiresUnownedLaunchBootstrapManager() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let bootstrapManager = TabManager(initialTerminalInput: "")
        let bootstrapWorkspace = try #require(bootstrapManager.selectedWorkspace)
        let bootstrapPanel = try #require(bootstrapWorkspace.focusedTerminalPanel)
        let windowManager = TabManager(initialTerminalInput: "")
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            if !bootstrapManager.isFinalizedForWindowClose {
                bootstrapManager.finalizeAllWorkspacesForWindowClose()
            }
            if !windowManager.isFinalizedForWindowClose {
                windowManager.finalizeAllWorkspacesForWindowClose()
            }
            bootstrapWorkspace.teardownAllPanels()
            bootstrapWorkspace.teardownRemoteConnection()
            window.orderOut(nil)
        }

        app.tabManager = bootstrapManager
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: windowManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.setActiveMainWindow(window)

        #expect(app.tabManager === windowManager)
        #expect(bootstrapManager.isFinalizedForWindowClose)
        #expect(bootstrapManager.tabs.isEmpty)
        #expect(bootstrapWorkspace.isRetiredFromOwningTabManager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: bootstrapPanel.id) == nil)
    }

    @Test("Finalized manager rejects late workspace acquisition")
    func finalizedManagerRejectsLateWorkspaceAcquisition() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        manager.finalizeAllWorkspacesForWindowClose()
        let registryIdsAfterFinalization = Set(
            GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id)
        )
        var acquisitionExecuted = false

        let lateWorkspace = manager.acquireWorkspaceIfActive {
            acquisitionExecuted = true
            return manager.addWorkspace(initialTerminalCommand: "/usr/bin/true")
        }

        #expect(!acquisitionExecuted)
        #expect(lateWorkspace.map { _ in true } == nil)
        #expect(manager.tabs.isEmpty)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) == nil)
        #expect(Set(GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id)) == registryIdsAfterFinalization)
    }

    @Test("Finalized manager rejects guarded direct workspace creation")
    func finalizedManagerRejectsGuardedDirectWorkspaceCreation() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        defer {
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        manager.finalizeAllWorkspacesForWindowClose()
        let registryIdsAfterFinalization = Set(
            GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id)
        )

        let lateWorkspace = manager.addWorkspaceIfActive(
            initialTerminalCommand: "/usr/bin/true"
        )
        defer {
            lateWorkspace?.teardownAllPanels()
            lateWorkspace?.teardownRemoteConnection()
        }

        #expect(lateWorkspace == nil)
        #expect(manager.tabs.isEmpty)
        #expect(Set(GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id)) == registryIdsAfterFinalization)
    }

    @Test("Retired workspace rejects late terminal surface acquisition")
    func retiredWorkspaceRejectsLateTerminalSurfaceAcquisition() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        let paneId = try #require(
            workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
        )
        defer {
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        manager.finalizeAllWorkspacesForWindowClose()
        let registryIdsAfterFinalization = Set(
            GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id)
        )

        let latePanel = workspace.newTerminalSurface(
            inPane: paneId,
            initialCommand: "/usr/bin/true"
        )

        #expect(workspace.isRetiredFromOwningTabManager)
        #expect(latePanel == nil)
        #expect(workspace.panels.isEmpty)
        #expect(manager.tabs.isEmpty)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) == nil)
        #expect(Set(GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id)) == registryIdsAfterFinalization)
    }

    @Test("Retired workspace rejects late non-terminal surface creation")
    func retiredWorkspaceRejectsLateNonTerminalSurfaceCreation() throws {
        try expectRetiredWorkspaceRejectsPanelCreation(named: "newBrowserSurface") { workspace, paneId in
            workspace.newBrowserSurface(
                inPane: paneId,
                url: URL(string: "https://example.com/retired-workspace"),
                focus: false,
                creationPolicy: .restoration
            )?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "newMarkdownSurface") { workspace, paneId in
            workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: "/tmp/cmux-retired-workspace.md",
                focus: false
            )?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "newProjectSurface") { workspace, paneId in
            workspace.newProjectSurface(
                inPane: paneId,
                projectPath: "/tmp/cmux-retired-workspace.xcodeproj",
                focus: false
            )?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "newFilePreviewSurface") { workspace, paneId in
            workspace.newFilePreviewSurface(
                inPane: paneId,
                filePath: "/tmp/cmux-retired-workspace.txt",
                focus: false
            )?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "newRightSidebarToolSurface") { workspace, paneId in
            workspace.newRightSidebarToolSurface(
                inPane: paneId,
                mode: .files,
                focus: false
            )?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "newAgentSessionSurface") { workspace, paneId in
            workspace.newAgentSessionSurface(
                inPane: paneId,
                rendererKind: .react,
                focus: false
            )?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "openFileSurfaces") { workspace, paneId in
            workspace.openFileSurfaces(
                inPane: paneId,
                filePaths: [
                    "/tmp/cmux-retired-workspace-open.md",
                    "/tmp/cmux-retired-workspace-open.txt",
                    "/tmp/cmux-retired-workspace-open.xcodeproj",
                ],
                focus: false
            ).first?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "splitPaneWithMarkdown") { workspace, paneId in
            workspace.splitPaneWithMarkdown(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                filePath: "/tmp/cmux-retired-workspace-split.md"
            )?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "splitPaneWithFilePreview") { workspace, paneId in
            workspace.splitPaneWithFilePreview(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                filePath: "/tmp/cmux-retired-workspace-split.txt"
            )?.id
        }
    }

    @Test("Retired workspace rejects direct split and mirror surface creation")
    func retiredWorkspaceRejectsDirectSplitAndMirrorSurfaceCreation() throws {
        try expectRetiredWorkspaceRejectsPanelCreation(named: "splitPaneWithNewTerminal") { workspace, paneId in
            workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: nil,
                initialInput: nil
            )?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "addRemoteTmuxDisplayPane") { workspace, _ in
            workspace.addRemoteTmuxDisplayPane(
                remotePaneId: 42,
                focus: false,
                onInput: { _ in }
            )?.id
        }
        try expectRetiredWorkspaceRejectsPanelCreation(named: "bonsplitController.splitPane") { workspace, paneId in
            workspace.bonsplitController.splitPane(
                paneId,
                orientation: .horizontal,
                withTab: nil
            )?.id
        }
    }

    @Test("Stale context key exact owner can commit its close")
    func staleContextKeyExactOwnerCanCommitItsClose() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            window.orderOut(nil)
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)

#if DEBUG
        let injectedMismatch = app.debugInjectWindowContextKeyMismatch(windowId: windowId)
        #expect(injectedMismatch)
        guard injectedMismatch else { return }
#else
        Issue.record("debugInjectWindowContextKeyMismatch requires a Debug test host")
        return
#endif

        #expect(app.commitMainWindowClose(window))
        #expect(!app.mainWindowContexts.values.contains { $0.windowId == windowId })
        #expect(manager.isFinalizedForWindowClose)
        #expect(manager.tabs.isEmpty)
        #expect(workspace.isRetiredFromOwningTabManager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) == nil)
    }

    @Test("Mismatched context key cannot reject or finalize an unrelated registration")
    func mismatchedContextKeyCannotRejectOrFinalizeUnrelatedRegistration() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let ownerWindowId = UUID()
        let candidateWindowId = UUID()
        let ownerWindow = makeMainWindow(id: ownerWindowId)
        let candidateWindow = makeMainWindow(id: candidateWindowId)
        let ownerManager = TabManager()
        let candidateManager = TabManager()
        let ownerWorkspace = try #require(ownerManager.selectedWorkspace)
        let candidateWorkspace = try #require(candidateManager.selectedWorkspace)
        let ownerTerminal = try #require(ownerWorkspace.focusedTerminalPanel)
        let candidateTerminal = try #require(candidateWorkspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: ownerWindowId)
            app.unregisterMainWindowContextForTesting(windowId: candidateWindowId)
            if !ownerManager.isFinalizedForWindowClose {
                ownerManager.finalizeAllWorkspacesForWindowClose()
            }
            if !candidateManager.isFinalizedForWindowClose {
                candidateManager.finalizeAllWorkspacesForWindowClose()
            }
            ownerWorkspace.teardownAllPanels()
            ownerWorkspace.teardownRemoteConnection()
            candidateWorkspace.teardownAllPanels()
            candidateWorkspace.teardownRemoteConnection()
            ownerWindow.orderOut(nil)
            candidateWindow.orderOut(nil)
        }

        app.registerMainWindow(
            ownerWindow,
            windowId: ownerWindowId,
            tabManager: ownerManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        let ownerContext = try #require(
            app.mainWindowContexts.values.first { $0.windowId == ownerWindowId }
        )

        // Model a stale ObjectIdentifier entry (including address reuse): the
        // candidate's key points at an unrelated context whose weak window is
        // still the exact live owner window.
        app.mainWindowContexts[ObjectIdentifier(candidateWindow)] = ownerContext

        app.registerMainWindow(
            candidateWindow,
            windowId: candidateWindowId,
            tabManager: candidateManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        let candidateContext = try #require(
            app.mainWindowContexts.values.first { $0.windowId == candidateWindowId }
        )
        #expect(app.mainWindowContexts[ObjectIdentifier(ownerWindow)] === ownerContext)
        #expect(ownerContext.window === ownerWindow)
        #expect(ownerContext.tabManager === ownerManager)
        #expect(app.mainWindowContexts[ObjectIdentifier(candidateWindow)] === candidateContext)
        #expect(candidateContext.window === candidateWindow)
        #expect(candidateContext.tabManager === candidateManager)
        #expect(!ownerManager.isFinalizedForWindowClose)
        #expect(!candidateManager.isFinalizedForWindowClose)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: ownerTerminal.id) === ownerTerminal.surface)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: candidateTerminal.id) === candidateTerminal.surface)
    }

    @Test("Mismatched context key cannot commit an unrelated live graph")
    func mismatchedContextKeyCannotCommitUnrelatedLiveGraph() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let ownerWindowId = UUID()
        let unrelatedWindowId = UUID()
        let ownerWindow = makeMainWindow(id: ownerWindowId)
        let unrelatedWindow = makeMainWindow(id: unrelatedWindowId)
        let ownerManager = TabManager()
        let ownerWorkspace = try #require(ownerManager.selectedWorkspace)
        let ownerTerminal = try #require(ownerWorkspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: ownerWindowId)
            if !ownerManager.isFinalizedForWindowClose {
                ownerManager.finalizeAllWorkspacesForWindowClose()
            }
            ownerWorkspace.teardownAllPanels()
            ownerWorkspace.teardownRemoteConnection()
            ownerWindow.orderOut(nil)
            unrelatedWindow.orderOut(nil)
        }

        app.registerMainWindow(
            ownerWindow,
            windowId: ownerWindowId,
            tabManager: ownerManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        let ownerContext = try #require(
            app.mainWindowContexts.values.first { $0.windowId == ownerWindowId }
        )

        app.mainWindowContexts[ObjectIdentifier(unrelatedWindow)] = ownerContext

        #expect(!app.commitMainWindowClose(unrelatedWindow))
        #expect(app.mainWindowContexts[ObjectIdentifier(unrelatedWindow)] == nil)
        #expect(app.mainWindowContexts[ObjectIdentifier(ownerWindow)] === ownerContext)
        #expect(ownerContext.window === ownerWindow)
        #expect(!ownerManager.isFinalizedForWindowClose)
        #expect(ownerManager.tabs.contains { $0 === ownerWorkspace })
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: ownerTerminal.id) === ownerTerminal.surface)
    }

    @Test("Ordered-out recoverable owner can commit its close")
    func orderedOutRecoverableOwnerCanCommitItsClose() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            window.orderOut(nil)
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)
        let context = try #require(
            app.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        app.discardOrphanedMainWindowContext(context)
        window.orderOut(nil)

        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.window === window)
        #expect(app.commitMainWindowClose(window))
        #expect(app.recoverableMainWindowRoute(windowId: windowId) == nil)
        #expect(manager.tabs.isEmpty)
        #expect(workspace.isRetiredFromOwningTabManager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) == nil)
    }

    @Test("Retained closed window cannot respawn its context or terminal")
    func retainedClosedWindowCannotRespawnItsContextOrTerminal() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let manager = TabManager()
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let fileExplorerState = FileExplorerState()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        manager.requestBackgroundWorkspaceLoad(for: workspace.id)
        manager.retainBackgroundWorkspaceMount(for: workspace.id)
        manager.retainDebugWorkspaceLoads(for: [workspace.id])
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            window.orderOut(nil)
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState
        )
        window.makeKeyAndOrderFront(nil)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)

        // Drive the installed AppKit close observer while the non-destructive
        // fixture keeps the synthetic contentless window alive. Then reproduce
        // issue #8349's late SwiftUI registration.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        window.orderOut(nil)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState
        )
        #expect(window.closeCallCount == 1)

        // A retained, already-closed NSWindow emits no second notification.
        // The socket/API fallback calls this same authoritative transaction.
        #expect(!app.commitMainWindowClose(window))
        #expect(app.windowForMainWindowId(windowId) == nil)
        #expect(!app.focusMainWindow(windowId: windowId))
        #expect(!window.isVisible)

        #expect(app.tabManagerFor(windowId: windowId) == nil)
        #expect(app.recoverableMainWindowRoute(windowId: windowId) == nil)
        #expect(!app.listMainWindowSummaries().contains { $0.windowId == windowId })
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) == nil)
        #expect(manager.tabs.isEmpty)
        #expect(workspace.owningTabManager == nil)
        #expect(manager.pendingBackgroundWorkspaceLoadIds.isEmpty)
        #expect(manager.mountedBackgroundWorkspaceLoadIds.isEmpty)
        #expect(manager.debugPinnedWorkspaceLoadIds.isEmpty)
    }

    @Test("Closing an ignored duplicate window preserves the live owner")
    func closingIgnoredDuplicateWindowPreservesLiveOwner() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let liveWindow = makeMainWindow(id: windowId)
        let duplicateWindow = makeMainWindow(id: windowId)
        let manager = TabManager()
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let fileExplorerState = FileExplorerState()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            liveWindow.orderOut(nil)
            duplicateWindow.orderOut(nil)
        }

        app.registerMainWindow(
            liveWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState
        )
        liveWindow.makeKeyAndOrderFront(nil)

        // An ignored duplicate's controller can still deliver a close callback
        // carrying the live owner's restored id. Identity, not id, owns close.
        #expect(!app.commitMainWindowClose(duplicateWindow))
        #expect(app.tabManagerFor(windowId: windowId) === manager)
        #expect(app.listMainWindowSummaries().contains { $0.windowId == windowId })
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
    }
}

@MainActor
@Suite("Final close routing regressions", .serialized)
struct FinalCloseRoutingRegressionTests {
    private func makeMainWindow(id: UUID) -> NonDestructiveCloseWindow {
        let window = NonDestructiveCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    @Test("Windowless owner rejects a same-identifier close request")
    func windowlessOwnerRejectsSameIdentifierCloseRequest() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let duplicateWindow = makeMainWindow(id: windowId)
        let ownerWindow = makeMainWindow(id: windowId)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            ownerWindow.orderOut(nil)
            duplicateWindow.orderOut(nil)
        }

        app.registerMainWindow(
            ownerWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        ownerWindow.makeKeyAndOrderFront(nil)
        let context = try #require(
            app.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        app.discardOrphanedMainWindowContext(context)
        let route = try #require(app.recoverableMainWindowRoute(windowId: windowId))
        route.window = nil
        ownerWindow.identifier = nil
        ownerWindow.orderOut(nil)
        duplicateWindow.makeKeyAndOrderFront(nil)

        // An AppKit identifier is a lookup hint, never window authority.
        #expect(app.windowForMainWindowId(windowId) == nil)
        #expect(!app.closeMainWindow(windowId: windowId, recordHistory: false))
        #expect(!manager.isFinalizedForWindowClose)
        #expect(manager.tabs.contains { $0 === workspace })
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === manager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
#if DEBUG
        #expect(!app.isClosedWindowHistorySuppressedForTesting(windowId: windowId))
#endif
    }

    @Test("Close request targets the exact recoverable owner instead of a duplicate")
    func closeRequestTargetsExactRecoverableOwnerInsteadOfDuplicate() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let duplicateWindow = makeMainWindow(id: windowId)
        let ownerWindow = makeMainWindow(id: windowId)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            ownerWindow.orderOut(nil)
            duplicateWindow.orderOut(nil)
        }

        app.registerMainWindow(
            ownerWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        ownerWindow.makeKeyAndOrderFront(nil)
        let context = try #require(
            app.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        app.discardOrphanedMainWindowContext(context)
        ownerWindow.orderFront(nil)
        duplicateWindow.makeKeyAndOrderFront(nil)

        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.window === ownerWindow)
        #expect(app.windowForMainWindowId(windowId) === ownerWindow)
        #expect(app.closeMainWindow(windowId: windowId, recordHistory: false))
        #expect(manager.isFinalizedForWindowClose)
        #expect(manager.tabs.isEmpty)
        #expect(workspace.isRetiredFromOwningTabManager)
        #expect(app.recoverableMainWindowRoute(windowId: windowId) == nil)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) == nil)
#if DEBUG
        #expect(!app.isClosedWindowHistorySuppressedForTesting(windowId: windowId))
#endif
    }

    @Test("Route-only close records window history before finalization")
    func routeOnlyCloseRecordsWindowHistoryBeforeFinalization() throws {
        _ = NSApplication.shared
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        defer {
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            window.orderOut(nil)
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)
        let context = try #require(
            app.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        app.discardOrphanedMainWindowContext(context)
        window.orderOut(nil)

        #expect(ClosedItemHistoryStore.shared.menuSnapshot().totalItemCount == 0)
        #expect(app.commitMainWindowClose(window))

        let menuSnapshot = ClosedItemHistoryStore.shared.menuSnapshot()
        #expect(menuSnapshot.totalItemCount == 1)
        let historyItem = try #require(menuSnapshot.items.first)
        let removedRecord = try #require(
            ClosedItemHistoryStore.shared.removeRecord(id: historyItem.id)?.record
        )
        switch removedRecord.entry {
        case .window(let entry):
            #expect(entry.windowId == windowId)
            #expect(entry.snapshot.windowId == windowId)
            #expect(entry.workspaceIds.contains(workspace.id))
            #expect(
                entry.snapshot.tabManager.workspaces.contains {
                    $0.workspaceId == workspace.id
                }
            )
            #expect(!entry.snapshot.tabManager.workspaces.isEmpty)
        case .panel, .workspace:
            Issue.record("Route-only main-window close recorded a non-window history entry")
        }

        #expect(manager.isFinalizedForWindowClose)
        #expect(manager.tabs.isEmpty)
        #expect(workspace.isRetiredFromOwningTabManager)
    }
}

@MainActor
@Suite("Main window key observation ownership", .serialized)
struct MainWindowKeyObservationOwnershipTests {
    private func makeMainWindow(id: UUID) -> NonDestructiveCloseWindow {
        let window = NonDestructiveCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    @Test("Observed same-ID duplicate cannot steal or close a live owner")
    func observedSameIdDuplicateCannotStealOrCloseLiveOwner() throws {
        _ = NSApplication.shared
        let app = try #require(AppDelegate.shared)
        let previousManager = app.tabManager
        let previousSidebarState = app.sidebarState
        let previousSidebarSelectionState = app.sidebarSelectionState
        let previousFileExplorerState = app.fileExplorerState
        let previousTerminalManager = TerminalController.shared.activeTabManagerForCallerNotification()

        let windowId = UUID()
        let ownerWindow = makeMainWindow(id: windowId)
        let duplicateWindow = makeMainWindow(id: windowId)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            ownerWindow.orderOut(nil)
            duplicateWindow.orderOut(nil)
            app.tabManager = previousManager
            app.sidebarState = previousSidebarState
            app.sidebarSelectionState = previousSidebarSelectionState
            app.fileExplorerState = previousFileExplorerState
            TerminalController.shared.setActiveTabManager(previousTerminalManager)
        }

        app.registerMainWindow(
            ownerWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        // Posting through NotificationCenter exercises the observer installed
        // by applicationDidFinishLaunching, including the production reindex path.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: ownerWindow)
        #expect(app.tabManager === manager)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: duplicateWindow)
        #expect(!app.commitMainWindowClose(duplicateWindow))

        #expect(!manager.isFinalizedForWindowClose)
        #expect(manager.tabs.map(\.id) == [workspace.id])
        #expect(app.mainWindowContexts.values.contains {
            $0.windowId == windowId && $0.tabManager === manager && $0.window === ownerWindow
        })
        #expect(app.tabManagerFor(windowId: windowId) === manager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
    }

    @Test("Observed same-ID duplicate cannot steal a windowless owner before validated replacement")
    func observedSameIdDuplicateCannotStealWindowlessOwnerBeforeValidatedReplacement() throws {
        _ = NSApplication.shared
        let app = try #require(AppDelegate.shared)
        let previousManager = app.tabManager
        let previousSidebarState = app.sidebarState
        let previousSidebarSelectionState = app.sidebarSelectionState
        let previousFileExplorerState = app.fileExplorerState
        let previousTerminalManager = TerminalController.shared.activeTabManagerForCallerNotification()

        let windowId = UUID()
        let originalWindow = makeMainWindow(id: windowId)
        let duplicateWindow = makeMainWindow(id: windowId)
        let replacementWindow = makeMainWindow(id: windowId)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            originalWindow.orderOut(nil)
            duplicateWindow.orderOut(nil)
            replacementWindow.orderOut(nil)
            app.tabManager = previousManager
            app.sidebarState = previousSidebarState
            app.sidebarSelectionState = previousSidebarSelectionState
            app.fileExplorerState = previousFileExplorerState
            TerminalController.shared.setActiveTabManager(previousTerminalManager)
        }

        app.registerMainWindow(
            originalWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: originalWindow)
        #expect(app.tabManager === manager)

        let context = try #require(
            app.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        context.window = nil
        manager.window = nil
        originalWindow.identifier = nil

        duplicateWindow.makeKeyAndOrderFront(nil)
        #expect(app.windowForMainWindowId(windowId) == nil)
        #expect(app.scriptableMainWindow(windowId: windowId) == nil)
        #expect(!app.focusMainWindow(windowId: windowId))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: duplicateWindow)
        #expect(!app.commitMainWindowClose(duplicateWindow))
        #expect(!manager.isFinalizedForWindowClose)
        #expect(manager.tabs.map(\.id) == [workspace.id])
        #expect(app.mainWindowContexts.values.contains {
            $0 === context && $0.windowId == windowId && $0.tabManager === manager && $0.window == nil
        })
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)

        // Registration is the ownership-validation boundary. Once the same
        // manager supplies the reserved ID, the replacement may be adopted.
        app.registerMainWindow(
            replacementWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(app.mainWindowContexts[ObjectIdentifier(replacementWindow)] === context)
        #expect(context.window === replacementWindow)
        #expect(manager.window === replacementWindow)
        #expect(app.windowForMainWindowId(windowId) === replacementWindow)
        #expect(!manager.isFinalizedForWindowClose)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
    }

    @Test("Observed same-ID duplicate cannot close a recoverable owner")
    func observedSameIdDuplicateCannotCloseRecoverableOwner() throws {
        _ = NSApplication.shared
        let app = try #require(AppDelegate.shared)
        let previousManager = app.tabManager
        let previousSidebarState = app.sidebarState
        let previousSidebarSelectionState = app.sidebarSelectionState
        let previousFileExplorerState = app.fileExplorerState
        let previousTerminalManager = TerminalController.shared.activeTabManagerForCallerNotification()

        let windowId = UUID()
        let ownerWindow = makeMainWindow(id: windowId)
        let duplicateWindow = makeMainWindow(id: windowId)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            ownerWindow.orderOut(nil)
            duplicateWindow.orderOut(nil)
            app.tabManager = previousManager
            app.sidebarState = previousSidebarState
            app.sidebarSelectionState = previousSidebarSelectionState
            app.fileExplorerState = previousFileExplorerState
            TerminalController.shared.setActiveTabManager(previousTerminalManager)
        }

        app.registerMainWindow(
            ownerWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: ownerWindow)
        #expect(app.tabManager === manager)

        let context = try #require(
            app.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        app.discardOrphanedMainWindowContext(context)
        let route = try #require(app.recoverableMainWindowRoute(windowId: windowId))
        route.window = nil
        manager.window = nil
        ownerWindow.identifier = nil

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: duplicateWindow)
        #expect(!app.commitMainWindowClose(duplicateWindow))

        #expect(!manager.isFinalizedForWindowClose)
        #expect(manager.tabs.map(\.id) == [workspace.id])
        #expect(!app.mainWindowContexts.values.contains { $0.windowId == windowId })
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === manager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
    }
}

@MainActor
@Suite("Workspace shared agent observer retirement", .serialized)
struct WorkspaceSharedAgentObserverRetirementTests {
    @Test("Retirement rejects queued and future shared agent index publications")
    func retirementRejectsQueuedAndFutureSharedAgentIndexPublications() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        defer {
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }

        await drainMainActorQueue()
        var publicationCount = 0
        let publication = workspace.objectWillChange.sink {
            publicationCount += 1
        }
        defer { publication.cancel() }

        NotificationCenter.default.post(
            name: .sharedLiveAgentIndexDidChange,
            object: SharedLiveAgentIndex.shared,
            userInfo: ["workspaceId": workspace.id]
        )
        await drainMainActorQueue()
        #expect(publicationCount > 0)

        // Queue one final matching publication, then retire before its
        // MainActor task can mutate the workspace.
        NotificationCenter.default.post(
            name: .sharedLiveAgentIndexDidChange,
            object: SharedLiveAgentIndex.shared,
            userInfo: ["workspaceId": workspace.id]
        )
        workspace.retireFromOwningTabManager()
        let countAfterRetirement = publicationCount
        await drainMainActorQueue()
        #expect(publicationCount == countAfterRetirement)

        for _ in 0..<3 {
            NotificationCenter.default.post(
                name: .sharedLiveAgentIndexDidChange,
                object: SharedLiveAgentIndex.shared,
                userInfo: ["workspaceId": workspace.id]
            )
        }
        await drainMainActorQueue()
        #expect(publicationCount == countAfterRetirement)
    }

    private func drainMainActorQueue() async {
        await Task.yield()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        await Task.yield()
    }
}

@MainActor
@Suite("Window zombie regressions", .serialized)
struct WindowZombieRegressionTests {
    @Test("SwiftUI window state does not own its native window")
    func swiftUIWindowStateDoesNotOwnItsNativeWindow() {
        weak var releasedWindow: NSWindow?
        var reference: WeakWindowReference?

        autoreleasepool {
            var window: NSWindow? = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            releasedWindow = window
            reference = WeakWindowReference(window)
            window = nil
        }

        #expect(reference?.window == nil)
        #expect(releasedWindow == nil)
    }

    @Test("Closed Settings window is fully retired")
    func closedSettingsWindowIsFullyRetired() async {
        _ = NSApplication.shared
        closeSettingsWindows()
        defer { closeSettingsWindows() }

        var closingWindowNumber: Int?
        weak var releasedWindow: NSWindow?
        autoreleasepool {
            let presenter = SettingsWindowPresenter()
            presenter.show()
            var closingWindow = settingsWindow()
            #expect(closingWindow != nil)
            guard closingWindow != nil else { return }
            closingWindowNumber = closingWindow?.windowNumber
            releasedWindow = closingWindow
            closingWindow?.close()
            closingWindow = nil
        }
        let didRetireWindow = await settleWindowLifecycle {
            releasedWindow == nil
                && (closingWindowNumber.map { !isWindowServerWindowAlive($0) } ?? true)
        }

        #expect(didRetireWindow)
        #expect(releasedWindow == nil)
        #expect(closingWindowNumber != nil)
        if let closingWindowNumber {
            #expect(!isWindowServerWindowAlive(closingWindowNumber))
        }
    }

    @Test("Closed detached main window is fully retired")
    func closedDetachedMainWindowIsFullyRetired() async {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        let previousConfirmationHandler = app.debugCloseMainWindowConfirmationHandler
        app.debugCloseMainWindowConfirmationHandler = { _ in true }
        var survivorWindowId: UUID?
        weak var releasedWindow: NSWindow?
        defer {
            if let leakedWindow = releasedWindow {
                leakedWindow.windowController?.window = nil
                leakedWindow.delegate = nil
                leakedWindow.contentViewController = nil
                leakedWindow.contentView = nil
                leakedWindow.orderOut(nil)
            }
            if let survivorWindowId,
               let survivor = app.windowForMainWindowId(survivorWindowId) {
                survivor.close()
            }
            app.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        survivorWindowId = app.createMainWindow(shouldActivate: false)
        let closingWindowId = app.createMainWindow(shouldActivate: false)
        var closingWindow = app.windowForMainWindowId(closingWindowId)
        #expect(closingWindow != nil)
        guard closingWindow != nil else { return }
        let closingWindowNumber = closingWindow?.windowNumber
        releasedWindow = closingWindow

        autoreleasepool {
            closingWindow?.close()
            closingWindow = nil
        }
        let didRetireWindow = await settleWindowLifecycle {
            releasedWindow == nil
                && (closingWindowNumber.map { !isWindowServerWindowAlive($0) } ?? true)
        }

        #expect(didRetireWindow)
        #expect(releasedWindow?.windowController == nil)
        #expect(releasedWindow?.contentViewController == nil)
        #expect(releasedWindow?.contentView == nil)
        #expect(closingWindowNumber != nil)
        if let closingWindowNumber {
            #expect(!isWindowServerWindowAlive(closingWindowNumber))
        }
    }

    @Test("Committed close preserves the controller release callback")
    func committedClosePreservesControllerReleaseCallback() async throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        let previousConfirmationHandler = app.debugCloseMainWindowConfirmationHandler
        app.debugCloseMainWindowConfirmationHandler = { _ in true }
        var survivorWindowId: UUID?
        defer {
            if let survivorWindowId,
               let survivor = app.windowForMainWindowId(survivorWindowId) {
                survivor.close()
            }
            app.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        survivorWindowId = app.createMainWindow(shouldActivate: false)
        let closingWindowId = app.createMainWindow(shouldActivate: false)
        let retainedWindow = try #require(app.windowForMainWindowId(closingWindowId))
        defer {
            retainedWindow.delegate = nil
            retainedWindow.contentViewController = nil
            retainedWindow.contentView = nil
            retainedWindow.orderOut(nil)
        }

        #expect(app.commitMainWindowClose(retainedWindow))
        #expect(retainedWindow.contentView != nil)
        retainedWindow.close()

        let didReleaseGraph = await settleWindowLifecycle {
            retainedWindow.windowController == nil
                && retainedWindow.contentViewController == nil
                && retainedWindow.contentView == nil
        }
        #expect(didReleaseGraph)
    }

    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.settings" && $0.isVisible
        }
    }

    private func closeSettingsWindows() {
        for window in NSApp.windows where window.identifier?.rawValue == "cmux.settings" {
            window.orderOut(nil)
            window.identifier = nil
            window.close()
        }
    }

    private func settleWindowLifecycle(
        until condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard clock.now < deadline else { return false }
            await Task.yield()
            try? await clock.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func isWindowServerWindowAlive(_ windowNumber: Int) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            .optionIncludingWindow,
            CGWindowID(windowNumber)
        ) as? [[CFString: Any]] else {
            return false
        }
        return !windows.isEmpty
    }
}
