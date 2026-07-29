import AppKit
import Bonsplit
import Combine
import CmuxControlSocket
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

    @Test("Captured main window is not refocused after its context is removed")
    func capturedMainWindowIsNotRefocusedAfterContextRemoval() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        window.isReleasedWhenClosed = false

        AppDelegate.shared = app
        app.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.orderOut(nil)

        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            window.close()
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        #expect(app.contextForMainTerminalWindow(window, reindex: false) != nil)
        app.unregisterMainWindowContextForTesting(windowId: windowId)
        #expect(app.contextForMainTerminalWindow(window, reindex: false) == nil)
        #expect(!window.isVisible)

        app.bringToFront(window, reason: .focusMainWindow)

        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test("Main window cannot be refocused after close commits")
    func mainWindowCannotBeRefocusedAfterCloseCommits() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let manager = TabManager()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        window.isReleasedWhenClosed = false

        AppDelegate.shared = app
        app.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)

        var focusResultDuringWillClose: Bool?
        let focusObserver = FocusMainWindowOnWillClose(window: window) {
            focusResultDuringWillClose = app.focusMainWindow(windowId: windowId)
        }

        withExtendedLifetime(focusObserver) {
            window.close()
        }

        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        #expect(focusResultDuringWillClose == false)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test("Production close teardown cannot re-register and refocus its window")
    func productionCloseTeardownCannotReRegisterAndRefocusItsWindow() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let manager = TabManager()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let controller = MainWindowController(window: window)

        AppDelegate.shared = app
        controller.onCloseCommitted = { closingWindow in
            app.markMainWindowCloseCommitted(closingWindow)
        }
        app.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)

        var focusResultDuringControllerTeardown: Bool?
        controller.onClose = {
            app.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
            focusResultDuringControllerTeardown = app.focusMainWindow(windowId: windowId)
        }

        window.close()

        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        #expect(focusResultDuringControllerTeardown == false)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test("project.open with focus false preserves the active window and workspace")
    func projectOpenWithoutFocusPreservesActiveContext() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let managerA = TabManager()
        let managerB = TabManager()
        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)

        AppDelegate.shared = app
        app.tabManager = managerA
        TerminalController.shared.setActiveTabManager(managerA)
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
        windowA.makeKeyAndOrderFront(nil)
        app.setActiveMainWindow(windowA)

        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowAId)
            app.unregisterMainWindowContextForTesting(windowId: windowBId)
            managerA.tabs.forEach { $0.teardownAllPanels() }
            managerB.tabs.forEach { $0.teardownAllPanels() }
            windowA.orderOut(nil)
            windowB.orderOut(nil)
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        let initiallySelectedWorkspace = try #require(managerB.selectedWorkspace)
        let backgroundWorkspace = managerB.addWorkspace(
            title: "Background project",
            select: false
        )
        let panelCountBeforeOpen = backgroundWorkspace.panels.count
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: true,
            windowID: windowBId,
            groupID: nil,
            workspaceID: backgroundWorkspace.id,
            surfaceID: nil,
            paneID: nil
        )

        let result = TerminalController.shared.withSocketCommandPolicy(
            commandKey: "project.open",
            isV2: true,
            params: ["focus": false]
        ) {
            TerminalController.shared.controlProjectOpen(
                routing: routing,
                path: FileManager.default.temporaryDirectory.path,
                requestedFocus: false
            )
        }

        guard case .opened = result else {
            Issue.record("Expected background project surface creation")
            return
        }
        #expect(backgroundWorkspace.panels.count == panelCountBeforeOpen + 1)
        #expect(managerB.selectedTabId == initiallySelectedWorkspace.id)
        #expect(app.tabManager === managerA)
        #expect(TerminalController.shared.activeTabManagerForCallerNotification() === managerA)
    }

    @Test("Noninteractive close commits before inspector teardown")
    func noninteractiveCloseCommitsBeforeInspectorTeardown() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let manager = TabManager()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        window.isReleasedWhenClosed = false

        AppDelegate.shared = app
        app.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)

        var wasCommittedDuringTeardown = false
        var focusResultDuringTeardown: Bool?
        app.closeMainWindowWithoutInteractiveVeto(window) { closingWindow in
            wasCommittedDuringTeardown = app.isMainWindowCloseCommitted(closingWindow)
            app.registerMainWindow(
                closingWindow,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
            focusResultDuringTeardown = app.focusMainWindow(windowId: windowId)
        }

        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        #expect(wasCommittedDuringTeardown)
        #expect(focusResultDuringTeardown == false)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
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
        #expect(app.windowId(for: managerB) == nil)
    }

    @Test("Recovered visible window stays routable but cannot focus without context")
    func recoveredVisibleWindowStaysRoutableButCannotFocusWithoutContext() throws {
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
        let managerA = TabManager()
        let managerC = TabManager()
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowAId)
            app.unregisterMainWindowContextForTesting(windowId: windowCId)
            managerA.tabs.forEach { $0.teardownAllPanels() }
            managerC.tabs.forEach { $0.teardownAllPanels() }
            windowA.orderOut(nil)
            windowC.orderOut(nil)
        }

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
        app.setActiveMainWindow(windowA)

        let workspaceC = try #require(managerC.selectedWorkspace)
        let terminalPanelC = try #require(workspaceC.focusedTerminalPanel)
        let unselectedWorkspaceC = managerC.addWorkspace(title: "Unavailable target", select: false)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanelC.id) === terminalPanelC.surface)
        let workspaceA = try #require(managerA.selectedWorkspace)
        let routingC = ControlRoutingSelectors(
            hasWindowIDParam: true,
            windowID: windowCId,
            groupID: nil,
            workspaceID: nil,
            surfaceID: nil,
            paneID: nil
        )
        // The registered context is the sole live routing owner.
        #expect(app.recoverableMainWindowRoute(windowId: windowCId) == nil)

        app.unregisterMainWindowContextForTesting(windowId: windowCId)

        // Detachment transfers non-focus routing authority to the recovery ledger.
        #expect(app.recoverableMainWindowRoute(windowId: windowCId)?.tabManager === managerC)
        #expect(windowC.isVisible)
        #expect(app.listMainWindowSummaries().contains { $0.windowId == windowCId })
        #expect(app.tabManagerFor(windowId: windowCId) === managerC)
        #expect(!app.moveWorkspaceToWindow(
            workspaceId: workspaceA.id,
            windowId: windowCId,
            focus: false
        ))
        #expect(managerA.tabs.contains { $0.id == workspaceA.id })
        #expect(!managerC.tabs.contains { $0.id == workspaceA.id })
        #expect(!app.focusMainWindow(windowId: windowCId))
        #expect(!app.focusScriptableMainWindow(windowId: windowCId, bringToFront: true))
        #expect(app.tabManager === managerA)
        #expect(TerminalController.shared.activeTabManagerForCallerNotification() === managerA)
        #expect(
            TerminalController.shared.controlSelectWorkspace(
                routing: routingC,
                workspaceID: unselectedWorkspaceC.id
            ) == .tabManagerUnavailable
        )
        #expect(managerC.selectedTabId == workspaceC.id)
        #expect(app.tabManager === managerA)
        #expect(TerminalController.shared.activeTabManagerForCallerNotification() === managerA)

        #expect(
            TerminalController.shared.controlSelectNextWorkspace(routing: routingC)
                == .tabManagerUnavailable
        )
        #expect(managerC.selectedTabId == workspaceC.id)
        #expect(
            TerminalController.shared.controlSelectPreviousWorkspace(routing: routingC)
                == .tabManagerUnavailable
        )
        #expect(managerC.selectedTabId == workspaceC.id)
        #expect(
            TerminalController.shared.controlSelectLastWorkspace(routing: routingC)
                == .tabManagerUnavailable
        )
        #expect(managerC.selectedTabId == workspaceC.id)

        let paneC = try #require(workspaceC.bonsplitController.focusedPaneId)
        #expect(
            TerminalController.shared.controlPaneFocus(
                workspace: workspaceC,
                paneID: paneC.id,
                tabManager: managerC
            ) == .tabManagerUnavailable
        )
        #expect(
            TerminalController.shared.controlSurfaceFocus(
                routing: routingC,
                surfaceID: terminalPanelC.id
            ) == .tabManagerUnavailable
        )
        #expect(app.tabManager === managerA)
        #expect(TerminalController.shared.activeTabManagerForCallerNotification() === managerA)

        let panelCountBeforeProjectOpen = workspaceC.panels.count
        let projectOpenResult = TerminalController.shared.withSocketCommandPolicy(
            commandKey: "project.open",
            isV2: true,
            params: ["focus": true]
        ) {
            TerminalController.shared.controlProjectOpen(
                routing: routingC,
                path: FileManager.default.temporaryDirectory.path,
                requestedFocus: true
            )
        }
        if case .opened = projectOpenResult {
            Issue.record("Rejected window focus still created a project surface")
        }
        #expect(workspaceC.panels.count == panelCountBeforeProjectOpen)
        #expect(managerC.selectedTabId == workspaceC.id)

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-closed-window-\(UUID().uuidString).txt"
        )
        try Data("closed-window".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let panelCountBeforeFileOpen = workspaceC.panels.count
        let fileOpenResult = TerminalController.shared.withSocketCommandPolicy(
            commandKey: "file.open",
            isV2: true,
            params: ["focus": true]
        ) {
            TerminalController.shared.v2FileOpen(params: [
                "window_id": windowCId.uuidString,
                "workspace_id": workspaceC.id.uuidString,
                "path": [fileURL.path],
                "focus": true,
            ])
        }
        if case .ok = fileOpenResult {
            Issue.record("Rejected window focus still opened a file surface")
        }
        #expect(workspaceC.panels.count == panelCountBeforeFileOpen)
        #expect(managerC.selectedTabId == workspaceC.id)

        let globalSearchWorkspace = unselectedWorkspaceC
        let globalSearchPanel = try #require(globalSearchWorkspace.focusedTerminalPanel)
        app.openGlobalSearchHit(
            SearchIndexHit(
                id: "closed-window-hit",
                windowID: windowCId,
                workspaceID: globalSearchWorkspace.id,
                panelID: globalSearchPanel.id,
                kind: .title,
                title: "Unavailable target",
                location: "Unavailable target",
                anchor: "",
                snippet: "needle",
                rank: 0,
                timestamp: Date(timeIntervalSince1970: 0)
            ),
            query: "needle"
        )
        #expect(managerC.selectedTabId == workspaceC.id)
        #expect(app.tabManager === managerA)
        #expect(TerminalController.shared.activeTabManagerForCallerNotification() === managerA)

        #expect(!app.workspaceMoveTargets(
            excludingWorkspaceId: workspaceA.id,
            referenceWindowId: windowAId
        ).contains { $0.windowId == windowCId })

        #expect(!app.moveWorkspaceToWindow(
            workspaceId: workspaceA.id,
            windowId: windowCId,
            focus: true
        ))
        #expect(managerA.tabs.contains { $0.id == workspaceA.id })
        #expect(!managerC.tabs.contains { $0.id == workspaceA.id })
        #expect(app.tabManager === managerA)
        #expect(TerminalController.shared.activeTabManagerForCallerNotification() === managerA)

        windowC.orderOut(nil)
        #expect(app.recoverableMainWindowRoute(windowId: windowCId) == nil)
        windowC.makeKeyAndOrderFront(nil)
        #expect(app.recoverableMainWindowRoute(windowId: windowCId) == nil)
        #expect(!app.listMainWindowSummaries().contains { $0.windowId == windowCId })
        #expect(app.tabManagerFor(windowId: windowCId) == nil)
        #expect(app.windowId(for: managerC) == nil)
    }

    @Test("Initial and menu-bar routing skip close-committed contexts")
    func initialAndMenuBarRoutingSkipCloseCommittedContexts() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let closingManager = TabManager()
        let closingWindowId = UUID()
        let closingWindow = makeMainWindow(id: closingWindowId)
        let previousConfirmationHandler = app.debugCloseMainWindowConfirmationHandler

        AppDelegate.shared = app
        app.tabManager = closingManager
        app.debugCloseMainWindowConfirmationHandler = { _ in true }
        TerminalController.shared.setActiveTabManager(closingManager)
        app.registerMainWindow(
            closingWindow,
            windowId: closingWindowId,
            tabManager: closingManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.markMainWindowCloseCommitted(closingWindow)

        var replacementWindowId: UUID?
        defer {
            if let replacementWindowId,
               let replacementWindow = app.windowForMainWindowId(replacementWindowId) {
                replacementWindow.close()
            }
            app.unregisterMainWindowContextForTesting(windowId: closingWindowId)
            closingManager.tabs.forEach { $0.teardownAllPanels() }
            closingWindow.orderOut(nil)
            app.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        let ensuredWindowId = app.ensureInitialMainWindowIfNeeded(
            shouldActivate: false,
            suppressWelcome: true
        )
        replacementWindowId = ensuredWindowId
        #expect(ensuredWindowId != closingWindowId)

        let shownWindow = try #require(app.showMainWindowFromMenuBar())
        #expect(shownWindow !== closingWindow)
        #expect(!app.isMainWindowCloseCommitted(shownWindow))
    }

    @Test("Rejected focus blocks external input and notification acknowledgement")
    func rejectedFocusBlocksExternalInputAndNotificationAcknowledgement() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let manager = TabManager()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let sidebarSelectionState = SidebarSelectionState(selection: .notifications)
        let notificationStore = TerminalNotificationStore.shared
        let previousNotifications = notificationStore.notifications
        let previousNotificationStore = app.notificationStore

        AppDelegate.shared = app
        app.tabManager = manager
        app.notificationStore = notificationStore
        TerminalController.shared.setActiveTabManager(manager)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)

        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        let notification = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Rejected focus",
            subtitle: "test",
            body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_888_888),
            isRead: false
        )
        notificationStore.replaceNotificationsForTesting([notification])
        let context = try #require(app.contextForMainTerminalWindow(window, reindex: false))
        app.markMainWindowCloseCommitted(window)

        defer {
            notificationStore.replaceNotificationsForTesting(previousNotifications)
            app.notificationStore = previousNotificationStore
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        #expect(!app.pasteTextInPreferredMainWindowFromExternalLink(
            "rejected-input",
            preferredWindow: window,
            shouldBringToFront: true
        ))
        #expect(!app.openNotificationInContext(
            context,
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            notificationId: notification.id
        ))
        #expect(notificationStore.notifications.first(where: { $0.id == notification.id })?.isRead == false)
        if case .notifications = sidebarSelectionState.selection {
            // Expected: focus rejection leaves the notification view untouched.
        } else {
            Issue.record("Rejected focus changed the sidebar selection")
        }
    }

    @Test("Recoverable route never rebinds to another window with the same identifier")
    func recoverableRouteNeverRebindsToAnotherWindowWithSameIdentifier() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        var originalWindow: NSWindow? = makeMainWindow(id: windowId)
        let replacementWindow = makeMainWindow(id: windowId)
        originalWindow?.isReleasedWhenClosed = false
        replacementWindow.isReleasedWhenClosed = false

        AppDelegate.shared = app
        app.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        app.registerMainWindow(
            try #require(originalWindow),
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        originalWindow?.makeKeyAndOrderFront(nil)

        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)
        let originalWorkspaceId = workspace.id
        let originalTerminalId = terminalPanel.id

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        if let originalWindow {
            app.markMainWindowCloseCommitted(originalWindow)
            originalWindow.orderOut(nil)
            originalWindow.close()
        }
        originalWindow = nil
        let replacementManager = TabManager()
        app.registerMainWindow(
            replacementWindow,
            windowId: windowId,
            tabManager: replacementManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        replacementWindow.makeKeyAndOrderFront(nil)

        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            replacementManager.tabs.forEach { $0.teardownAllPanels() }
            replacementWindow.orderOut(nil)
            replacementWindow.close()
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        let replacementWorkspace = try #require(replacementManager.selectedWorkspace)
        let replacementTerminal = try #require(replacementWorkspace.focusedTerminalPanel)
        #expect(app.recoverableMainWindowRoute(windowId: windowId) == nil)
        #expect(app.listMainWindowSummaries().contains { $0.windowId == windowId })
        #expect(app.tabManagerFor(windowId: windowId) === replacementManager)
        #expect(replacementWorkspace.id != originalWorkspaceId)
        #expect(replacementTerminal.id != originalTerminalId)
        #expect(!replacementManager.tabs.contains { $0.id == originalWorkspaceId })
    }
}

@MainActor
private final class FocusMainWindowOnWillClose: NSObject {
    private let focus: @MainActor () -> Void

    init(window: NSWindow, focus: @escaping @MainActor () -> Void) {
        self.focus = focus
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        focus()
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
