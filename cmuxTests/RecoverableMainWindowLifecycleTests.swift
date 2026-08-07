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

    @Test("Recovery freeze preserves a stored process-detected Dock binding")
    func recoveryFreezePreservesStoredProcessDetectedDockBinding() throws {
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
            updatedAt: 1_999_999_999
        )
        store.surfaceResumeBindingsByPanelId[panel.id] = binding

        let snapshot = store.sessionSnapshot(
            includeScrollback: false,
            preserveStoredProcessDetectedResumeBindings: true,
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let terminal = try #require(
            snapshot.panels.first(where: { $0.id == panel.id })?.terminal
        )

        #expect(terminal.resumeBinding == binding)
        #expect(store.surfaceResumeBinding(panelId: panel.id) == binding)
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
}
