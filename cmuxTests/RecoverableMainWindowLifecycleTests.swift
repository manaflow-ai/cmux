import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Recoverable main window lifecycle", .serialized)
struct RecoverableMainWindowLifecycleTests {
    @Test("Production windowless prune preserves the orphaned session")
    func productionWindowlessPrunePreservesOrphanedSession() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        var manager: TabManager? = TabManager()
        weak var releasedManager = manager
        let notificationStore = TerminalNotificationStore.shared
        let previousNotificationStore = app.notificationStore
        let previousNotifications = notificationStore.notifications
        let unrelatedNotificationTabId = UUID()
        let configFrameSignature = "issue-9666-windowless-freeze"
        let snapshot: AppSessionSnapshot
        app.notificationStore = notificationStore
        defer {
            notificationStore.replaceNotificationsForTesting(previousNotifications)
            app.notificationStore = previousNotificationStore
            app.commandPaletteWindowStore.removeWindow(unrelatedNotificationTabId)
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            window.orderOut(nil)
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let workspaceId: UUID
        let workspacePanelId: UUID
        let workspaceDockPanelId: UUID
        let windowDockPanelId: UUID
        do {
            let liveManager = try #require(manager)
            app.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: liveManager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
            let workspace = try #require(liveManager.selectedWorkspace)
            workspaceId = workspace.id
            let workspacePanel = try #require(workspace.focusedTerminalPanel)
            workspacePanelId = workspacePanel.id
            app.commandPaletteWindowStore.markOpenRequested(windowId, now: 10)
            app.commandPaletteWindowStore.registerWindow(unrelatedNotificationTabId)
            app.commandPaletteWindowStore.markOpenRequested(
                unrelatedNotificationTabId,
                now: 10
            )
            notificationStore.replaceNotificationsForTesting([
                terminalNotification(tabId: windowId, surfaceId: nil, title: "Window"),
                terminalNotification(
                    tabId: workspaceId,
                    surfaceId: workspacePanelId,
                    title: "Workspace"
                ),
                terminalNotification(
                    tabId: unrelatedNotificationTabId,
                    surfaceId: nil,
                    title: "Unrelated"
                ),
            ])
            workspace.surfaceResumeBindingsByPanelId[workspacePanelId] =
                unverifiedProcessDetectedResumeBinding()
            app.windowConfigFrames[windowId] = SessionConfigFrameRing(entries: [
                SessionConfigFrameEntry(
                    signature: configFrameSignature,
                    frame: SessionRectSnapshot(
                        x: 10,
                        y: 20,
                        width: 500,
                        height: 320
                    ),
                    display: nil,
                    lastUsedAt: 1_999_999_999
                )
            ])

            let workspaceDock = workspace.dockSplit
            let workspaceDockPanel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspaceDockPanelId = workspaceDockPanel.id
            workspaceDock.panels[workspaceDockPanelId] = workspaceDockPanel
            workspaceDock.surfaceResumeBindingsByPanelId[workspaceDockPanelId] =
                unverifiedProcessDetectedResumeBinding()

            let context = try #require(
                app.mainWindowContexts.values.first { $0.windowId == windowId }
            )
            let windowDock = context.windowDockStore()
            let windowDockPanel = TerminalPanel(
                workspaceId: windowId,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            windowDockPanelId = windowDockPanel.id
            windowDock.panels[windowDockPanelId] = windowDockPanel
            windowDock.surfaceResumeBindingsByPanelId[windowDockPanelId] =
                unverifiedProcessDetectedResumeBinding()

            // Drive the production predicate: both the weak context reference
            // and AppKit identifier lookup fail before prune transitions the
            // already-registered lifecycle record.
            window.orderOut(nil)
            app.debugResetShortcutRoutingStateForTesting()
            context.window = nil
            window.identifier = NSUserInterfaceItemIdentifier(
                "cmux.orphaned.\(windowId.uuidString)"
            )
            app.tabManager = liveManager
            _ = app.preferredMainWindowContextForWorkspaceCreation(
                debugSource: "issue9666-windowless-regression"
            )

            #expect(!app.mainWindowContexts.values.contains { $0.windowId == windowId })
            let route = try #require(app.recoverableMainWindowRoute(windowId: windowId))
            #expect(route.window == nil)
            #expect(route.tabManager === liveManager)
            #expect(route.frozenWindowSnapshot == nil)
            #expect(!app.recoverableMainWindowRoutes().contains { $0.windowId == windowId })
            #expect(app.tabManagerFor(windowId: windowId) == nil)
            #expect(liveManager.tabs.contains { !$0.panels.isEmpty })
            #expect(app.commandPaletteWindowStore.isPendingOpenRaw(windowId))
            #expect(
                app.commandPaletteWindowStore.isPendingOpenRaw(unrelatedNotificationTabId)
            )
            #expect(notificationStore.notifications.count == 3)

            snapshot = try #require(app.sessionSnapshotForTesting())

            let frozenRoute = try #require(
                app.recoverableMainWindowRoute(windowId: windowId)
            )
            #expect(frozenRoute.tabManager == nil)
            #expect(frozenRoute.frozenWindowSnapshot != nil)
            #expect(liveManager.tabs.allSatisfy { $0.panels.isEmpty })
            #expect(!app.commandPaletteWindowStore.isPendingOpenRaw(windowId))
            #expect(
                app.commandPaletteWindowStore.isPendingOpenRaw(unrelatedNotificationTabId)
            )
            #expect(notificationStore.notifications.map(\.tabId) == [unrelatedNotificationTabId])
            #expect(app.windowConfigFrames[windowId] == nil)
        }

        manager = nil
        #expect(releasedManager == nil)

        let restoredWindow = try #require(
            snapshot.windows.first { $0.windowId == windowId }
        )
        #expect(restoredWindow.configFrames?.map(\.signature) == [configFrameSignature])
        let restoredWorkspace = try #require(
            restoredWindow.tabManager.workspaces.first { $0.workspaceId == workspaceId }
        )
        try expectManualRecoveryBinding(
            restoredWorkspace.panels.first { $0.id == workspacePanelId }?.terminal?.resumeBinding
        )
        let restoredWorkspaceDock = try #require(restoredWorkspace.dock)
        try expectManualRecoveryBinding(
            restoredWorkspaceDock.panels.first(where: { $0.id == workspaceDockPanelId })?
                .terminal?.resumeBinding
        )
        let restoredWindowDock = try #require(restoredWindow.dock)
        try expectManualRecoveryBinding(
            restoredWindowDock.panels.first(where: { $0.id == windowDockPanelId })?
                .terminal?.resumeBinding
        )
    }

    @Test("Recovery freeze preserves a verified process-detected binding")
    func recoveryFreezePreservesVerifiedProcessDetectedBinding() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let manager = TabManager()
        defer {
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            window.orderOut(nil)
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let binding = unverifiedProcessDetectedResumeBinding()
        workspace.surfaceResumeBindingsByPanelId[panelId] = binding

        let context = try #require(
            app.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        window.orderOut(nil)
        context.window = nil
        window.identifier = NSUserInterfaceItemIdentifier(
            "cmux.orphaned.\(windowId.uuidString)"
        )
        app.discardOrphanedMainWindowContext(context)

        let route = try #require(app.recoverableMainWindowRoute(windowId: windowId))
        #expect(route.window == nil)
        #expect(route.tabManager === manager)
        #expect(route.frozenWindowSnapshot == nil)

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(
                workspaceId: workspace.id,
                panelId: panelId
            ): binding,
        ])
        let snapshot = try #require(
            app.debugBuildSessionSnapshotForTesting(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )
        )
        let restoredBinding = try #require(
            snapshot.windows
                .first(where: { $0.windowId == windowId })?
                .tabManager.workspaces
                .first(where: { $0.workspaceId == workspace.id })?
                .panels.first(where: { $0.id == panelId })?
                .terminal?.resumeBinding
        )

        #expect(restoredBinding.command == binding.command)
        #expect(restoredBinding.checkpointId == binding.checkpointId)
        #expect(restoredBinding.allowsAutomaticResume)
        #expect(restoredBinding.approvalPolicy == .auto)
        #expect(restoredBinding.approvalRecordId == binding.approvalRecordId)
        #expect(
            app.recoverableMainWindowRoute(windowId: windowId)?.frozenWindowSnapshot != nil
        )
    }

    @Test("Dismissed recovered window remains restorable and focusable")
    func dismissedRecoveredWindowRemainsRestorableAndFocusable() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let manager = TabManager()
        defer {
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            window.orderOut(nil)
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
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

        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.focusedTerminalPanel)
        #expect(
            GhosttyApp.terminalSurfaceRegistry.surface(id: terminal.id)
                === terminal.surface
        )

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        app.dismissMainWindowFromWindowChrome(window)
        window.orderOut(nil)

        #expect(!window.isVisible)
        #expect(app.listMainWindowSummaries().contains { $0.windowId == windowId })
        #expect(app.scriptableMainWindow(windowId: windowId)?.tabManager === manager)
        #expect(app.scriptableMainWindows().contains { $0.windowId == windowId })
        let snapshot = try #require(app.sessionSnapshotForTesting())
        #expect(snapshot.windows.contains { $0.windowId == windowId })
        #expect(app.focusMainWindow(windowId: windowId))
        #expect(window.isVisible)
    }

    @Test("Closing a recovered window uses normal close finalization")
    func closingRecoveredWindowUsesNormalCloseFinalization() throws {
        _ = NSApplication.shared
        ClosedItemHistoryStore.shared.removeAll()
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        let survivorWindowId = UUID()
        let closingWindowId = UUID()
        let survivorWindow = makeMainWindow(id: survivorWindowId)
        let closingWindow = makeMainWindow(id: closingWindowId)
        let survivorManager = TabManager()
        let closingManager = TabManager()
        defer {
            app.unregisterMainWindowContextForTesting(windowId: survivorWindowId)
            app.forgetRecoverableMainWindowRoute(windowId: survivorWindowId)
            app.forgetRecoverableMainWindowRoute(windowId: closingWindowId)
            survivorWindow.orderOut(nil)
            closingWindow.orderOut(nil)
            ClosedItemHistoryStore.shared.removeAll()
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        app.registerMainWindow(
            survivorWindow,
            windowId: survivorWindowId,
            tabManager: survivorManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            closingWindow,
            windowId: closingWindowId,
            tabManager: closingManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        survivorWindow.makeKeyAndOrderFront(nil)
        closingWindow.makeKeyAndOrderFront(nil)

        let closingWorkspace = try #require(closingManager.selectedWorkspace)
        let closingTerminal = try #require(closingWorkspace.focusedTerminalPanel)
        #expect(
            GhosttyApp.terminalSurfaceRegistry.surface(id: closingTerminal.id)
                === closingTerminal.surface
        )

        app.unregisterMainWindowContextForTesting(windowId: closingWindowId)
        #expect(app.listMainWindowSummaries().contains { $0.windowId == closingWindowId })

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: closingWindow
        )

        #expect(!app.listMainWindowSummaries().contains { $0.windowId == closingWindowId })
        #expect(app.tabManagerFor(windowId: closingWindowId) == nil)
        #expect(app.tabManagerForWindowTeardown(windowId: closingWindowId) === closingManager)
        let sessionSnapshot = try #require(app.sessionSnapshotForTesting())
        #expect(sessionSnapshot.windows.contains { $0.windowId == survivorWindowId })
        #expect(!sessionSnapshot.windows.contains { $0.windowId == closingWindowId })

        let historyItem = try #require(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
        let historyRecord = try #require(
            ClosedItemHistoryStore.shared.removeRecord(id: historyItem.id)?.record
        )
        guard case .window(let closedWindow) = historyRecord.entry else {
            Issue.record("Expected recovered close to record window history")
            return
        }
        #expect(closedWindow.windowId == closingWindowId)
        #expect(closedWindow.workspaceIds == [closingWorkspace.id])
    }

    @Test("Frozen Dock snapshot honors each scrollback request")
    func frozenDockSnapshotHonorsEachScrollbackRequest() throws {
        let panelId = UUID()
        let frozenSnapshot = SessionSplitContainerSnapshot(
            focusedPanelId: panelId,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [panelId],
                selectedPanelId: panelId
            )),
            panels: [SessionPanelSnapshot(
                id: panelId,
                type: .terminal,
                title: "Dock terminal",
                customTitle: nil,
                directory: "/tmp",
                isPinned: false,
                isManuallyUnread: false,
                listeningPorts: [],
                ttyName: nil,
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: "/tmp",
                    scrollback: "preserved output"
                ),
                browser: nil,
                markdown: nil,
                filePreview: nil,
                rightSidebarTool: nil
            )]
        )
        let dockState = MainWindowRouteDockState.frozen(frozenSnapshot)

        let withoutScrollback = dockState.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: nil
        )
        let withScrollback = dockState.sessionSnapshot(
            includeScrollback: true,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: nil
        )

        #expect(withoutScrollback.panels.first?.terminal?.scrollback == nil)
        #expect(withScrollback.panels.first?.terminal?.scrollback == "preserved output")
        #expect(frozenSnapshot.panels.first?.terminal?.scrollback == "preserved output")
    }

    @Test("Frozen window snapshot strips scrollback from every container")
    func frozenWindowSnapshotStripsScrollbackFromEveryContainer() throws {
        let workspacePanelId = UUID()
        let workspaceDockPanelId = UUID()
        let windowDockPanelId = UUID()
        var workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [workspacePanelId],
                selectedPanelId: workspacePanelId
            )),
            panels: [terminalPanelSnapshot(
                id: workspacePanelId,
                scrollback: "workspace output"
            )],
            statusEntries: [],
            logEntries: []
        )
        workspace.dock = splitContainerSnapshot(
            panel: terminalPanelSnapshot(
                id: workspaceDockPanelId,
                scrollback: "workspace dock output"
            )
        )
        let frozen = SessionWindowSnapshot(
            windowId: UUID(),
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspace]
            ),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: SessionPersistencePolicy.defaultSidebarWidth
            ),
            dock: splitContainerSnapshot(
                panel: terminalPanelSnapshot(
                    id: windowDockPanelId,
                    scrollback: "window dock output"
                )
            )
        )

        let lightweight = frozen.respectingScrollbackInclusion(false)
        let full = frozen.respectingScrollbackInclusion(true)

        #expect(lightweight.tabManager.workspaces[0].panels[0].terminal?.scrollback == nil)
        #expect(lightweight.tabManager.workspaces[0].dock?.panels[0].terminal?.scrollback == nil)
        #expect(lightweight.dock?.panels[0].terminal?.scrollback == nil)
        #expect(full.tabManager.workspaces[0].panels[0].terminal?.scrollback == "workspace output")
        #expect(full.tabManager.workspaces[0].dock?.panels[0].terminal?.scrollback == "workspace dock output")
        #expect(full.dock?.panels[0].terminal?.scrollback == "window dock output")
        #expect(frozen.dock?.panels[0].terminal?.scrollback == "window dock output")
    }

    @Test("Browser-only close retires its closing lifecycle record immediately")
    func browserOnlyCloseRetiresClosingLifecycleRecordImmediately() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let manager = TabManager()
        defer {
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            window.orderOut(nil)
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.focusedTerminalPanel)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            url: nil,
            focus: true,
            creationPolicy: .restoration
        ))
        #expect(workspace.closePanel(terminal.id, force: true))
        #expect(workspace.panels[browser.id] != nil)
        #expect(!workspace.panels.values.contains { $0 is TerminalPanel })

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        #expect(app.tabManagerForWindowTeardown(windowId: windowId) === manager)

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )

        #expect(app.tabManagerForWindowTeardown(windowId: windowId) == nil)
        #expect(app.mainWindowLifecycleCoordinator.teardownRoute(windowId: windowId) == nil)
    }

    @Test("Recovery freeze makes an unverified process-detected Dock binding manual")
    func recoveryFreezeMakesUnverifiedProcessDetectedDockBindingManual() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        store.panels[panel.id] = panel

        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach-session -t recovered",
            cwd: "/tmp",
            checkpointId: "recovered",
            source: "process-detected",
            autoResume: true,
            approvalPolicy: .auto,
            approvalRecordId: "previously-approved",
            updatedAt: 1_999_999_999
        )
        store.surfaceResumeBindingsByPanelId[panel.id] = binding

        let snapshot = store.sessionSnapshot(
            includeScrollback: false,
            downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable: true,
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let terminal = try #require(
            snapshot.panels.first(where: { $0.id == panel.id })?.terminal
        )
        let frozenBinding = try #require(terminal.resumeBinding)

        #expect(frozenBinding.command == binding.command)
        #expect(frozenBinding.checkpointId == binding.checkpointId)
        #expect(!frozenBinding.allowsAutomaticResume)
        #expect(frozenBinding.autoResume == false)
        #expect(frozenBinding.approvalPolicy == .manual)
        #expect(frozenBinding.approvalRecordId == nil)
        #expect(store.surfaceResumeBinding(panelId: panel.id) == frozenBinding)
    }

    @Test("Autosave projection bounds full route fingerprints")
    func autosaveProjectionBoundsFullRouteFingerprints() {
        let orderedWindowIds = (0..<15).map { _ in UUID() }
        let projection = MainWindowRouteAutosaveProjection(
            orderedWindowIds: orderedWindowIds,
            previouslyPersistedWindowIds: [orderedWindowIds[2], orderedWindowIds[14]],
            maximumFingerprintWindows: 3
        )

        #expect(projection.orderedWindowIds == orderedWindowIds)
        #expect(
            projection.fingerprintWindowIds == [
                orderedWindowIds[2],
                orderedWindowIds[14],
                orderedWindowIds[0],
            ]
        )
    }

    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        window.isReleasedWhenClosed = false
        return window
    }

    private func unverifiedProcessDetectedResumeBinding() -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach-session -t recovered",
            cwd: "/tmp",
            checkpointId: "recovered",
            source: "process-detected",
            autoResume: true,
            approvalPolicy: .auto,
            approvalRecordId: "previously-approved",
            updatedAt: 1_999_999_999
        )
    }

    private func terminalNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: "Recovery lifecycle",
            body: "Body",
            createdAt: Date(timeIntervalSince1970: 1_999_999_999),
            isRead: false
        )
    }

    private func expectManualRecoveryBinding(
        _ binding: SurfaceResumeBindingSnapshot?
    ) throws {
        let binding = try #require(binding)
        #expect(binding.command == "tmux attach-session -t recovered")
        #expect(binding.checkpointId == "recovered")
        #expect(binding.autoResume == false)
        #expect(binding.approvalPolicy == .manual)
        #expect(binding.approvalRecordId == nil)
    }

    private func terminalPanelSnapshot(
        id: UUID,
        scrollback: String
    ) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "Terminal",
            customTitle: nil,
            directory: "/tmp",
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: "/tmp",
                scrollback: scrollback
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }

    private func splitContainerSnapshot(
        panel: SessionPanelSnapshot
    ) -> SessionSplitContainerSnapshot {
        SessionSplitContainerSnapshot(
            focusedPanelId: panel.id,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [panel.id],
                selectedPanelId: panel.id
            )),
            panels: [panel]
        )
    }
}
