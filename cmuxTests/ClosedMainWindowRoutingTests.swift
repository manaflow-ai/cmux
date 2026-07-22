import AppKit
import Bonsplit
import Combine
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
        #expect(app.tabManagerFor(windowId: windowBId) === managerB)
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
        #expect(app.tabManagerFor(windowId: windowId) === manager)
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === manager)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
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
        #expect(app.tabManagerFor(windowId: windowId) === manager)
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.tabManager === manager)
        #expect(app.recoverableMainWindowRoute(windowId: windowId)?.window == nil)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
    }
}

@MainActor
@Suite("Ghost main window context lifecycle", .serialized)
struct GhostMainWindowContextLifecycleTests {
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

        // Drive the installed AppKit close observer without asking AppKit to
        // destroy a synthetic contentless test window (which crashes its
        // private layout machinery). Keep the NSWindow and SwiftUI-owned
        // models alive, then reproduce issue #8349's late registration.
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

        // A retained, already-closed NSWindow emits no second notification.
        // The socket/API fallback calls this same authoritative transaction.
        #expect(!app.commitMainWindowClose(window))

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
