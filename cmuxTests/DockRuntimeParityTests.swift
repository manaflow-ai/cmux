import AppKit
import Bonsplit
import Combine
import CmuxControlSocket
import CmuxNotifications
import CmuxTerminal
import Foundation
import Observation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class DockRuntimeParityPanel: Panel, ObservableObject {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    let displayTitle: String
    let displayIcon: String? = "terminal.fill"
    var isDirty = false

    private(set) var flashReasons: [WorkspaceAttentionFlashReason] = []
    private(set) var closeCount = 0

    init(id: UUID = UUID(), title: String) {
        self.id = id
        displayTitle = title
    }

    func close() {
        closeCount += 1
    }
    func focus() {}
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        flashReasons.append(reason)
    }
}

@MainActor
private final class DockRuntimeParityUnreadObserver {
    var publicationCount = 0
    var totalUnreadCounts: [Int] = []
}

@MainActor
private extension DockSplitStore {
    @discardableResult
    func seedRuntimeParityPanel(_ panel: any Panel) throws -> PaneID {
        let pane = try #require(bonsplitController.allPaneIds.first)
        panels[panel.id] = panel
        let tabID = try #require(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: panel.panelType.rawValue,
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        bindSurface(tabID, toPanelId: panel.id)
        installAttentionRouting(for: panel)
        return pane
    }
}

@MainActor
@Suite("Dock runtime parity", .serialized)
struct DockRuntimeParityTests {
    private static let socketWorker = DispatchQueue(label: "DockRuntimeParityTests.socketWorker")

    @Test("Reconciling a stale tab alias preserves the live panel owner")
    func reconcilingStaleTabAliasPreservesLivePanelOwner() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = DockRuntimeParityPanel(title: "Shared panel")
        let paneID = try dock.seedRuntimeParityPanel(panel)
        let liveTabID = try #require(dock.surfaceId(forPanelId: panel.id))
        let staleAliasID = try #require(
            dock.bonsplitController.createTab(
                title: "Stale alias",
                icon: panel.displayIcon,
                kind: panel.panelType.rawValue,
                isDirty: false,
                inPane: paneID
            )
        )
        // Seed only the stale forward alias; the live tab must remain the
        // authoritative reverse mapping for this fixture.
        dock.surfaceIdToPanelId[staleAliasID] = panel.id

        #expect(dock.bonsplitController.closeTab(staleAliasID))

        #expect(dock.panel(for: liveTabID) === panel)
        #expect(dock.surfaceId(forPanelId: panel.id) == liveTabID)
        #expect(dock.surfaceIdToPanelId[staleAliasID] == nil)
        #expect(panel.closeCount == 0)
    }

    @Test("Dock pane ownership follows split, close, and implicit move closure")
    func dockPaneOwnershipFollowsBonsplitLifecycle() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let otherDock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)

        #expect(dock.containsPane(rootPane.id))
        #expect(!otherDock.containsPane(rootPane.id))
        #expect(DockSplitStore.liveStore(containingPane: rootPane.id) === dock)

        let closingTab = Bonsplit.Tab(title: "Closing tab")
        let closedPane = try #require(
            dock.bonsplitController.splitPane(
                rootPane,
                orientation: .horizontal,
                withTab: closingTab
            )
        )
        #expect(dock.containsPane(closedPane.id))
        #expect(DockSplitStore.liveStore(containingPane: closedPane.id) === dock)

        #expect(dock.bonsplitController.closeTab(closingTab.id))
        #expect(!dock.containsPane(closedPane.id))
        #expect(DockSplitStore.liveStore(containingPane: closedPane.id) == nil)

        let explicitlyClosedPane = try #require(
            dock.bonsplitController.splitPane(
                rootPane,
                orientation: .horizontal,
                withTab: Bonsplit.Tab(title: "Explicitly closed pane")
            )
        )
        #expect(dock.bonsplitController.closePane(explicitlyClosedPane))
        #expect(!dock.containsPane(explicitlyClosedPane.id))

        let movingTab = try #require(
            dock.bonsplitController.createTab(
                title: "Moving tab",
                inPane: rootPane
            )
        )
        let destinationPane = try #require(
            dock.bonsplitController.splitPane(
                rootPane,
                orientation: .vertical,
                withTab: Bonsplit.Tab(title: "Destination tab")
            )
        )
        #expect(dock.bonsplitController.moveTab(movingTab, toPane: destinationPane))

        #expect(!dock.containsPane(rootPane.id))
        #expect(dock.containsPane(destinationPane.id))
        #expect(DockSplitStore.liveStore(containingPane: destinationPane.id) === dock)
    }

    private func socketEnvelope(
        method: String,
        params: [String: Any] = [:]
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(line)
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func socketEnvelopeOnWorker(
        method: String,
        params: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let controller = TerminalController.shared
        let raw = await withCheckedContinuation { continuation in
            Self.socketWorker.async {
                continuation.resume(returning: controller.handleSocketLine(line))
            }
        }
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func socketResult(
        method: String,
        params: [String: Any] = [:]
    ) throws -> [String: Any] {
        let envelope = try socketEnvelope(method: method, params: params)
        try #require(envelope["ok"] as? Bool == true, "\(envelope)")
        return try #require(envelope["result"] as? [String: Any])
    }

    private func waitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        for await _ in readiness { break }
    }

    private func withAppContext(
        fileExplorerState: FileExplorerState? = FileExplorerState(),
        _ body: @MainActor (AppDelegate, TabManager, Workspace, UUID) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let defaults = UserDefaults.standard
            let dockEnabledKey = RightSidebarBetaFeatureSettings.dockEnabledKey
            let previousDockEnabled = defaults.object(forKey: dockEnabledKey)
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            defaults.set(true, forKey: dockEnabledKey)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowID = UUID()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
            appDelegate.registerMainWindow(
                window,
                windowId: windowID,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: fileExplorerState
            )
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
                manager.tabs.forEach { $0.teardownAllPanels() }
                window.orderOut(nil)
                window.close()
                AppDelegate.shared = previousAppDelegate
                if let previousDockEnabled {
                    defaults.set(previousDockEnabled, forKey: dockEnabledKey)
                } else {
                    defaults.removeObject(forKey: dockEnabledKey)
                }
            }

            let workspace = try #require(manager.tabs.first)
            try await body(appDelegate, manager, workspace, windowID)
        }
    }

    @Test("Workspace panel unread invalidates only its keyed state")
    func workspacePanelUnreadInvalidatesOnlyItsKeyedState() async throws {
        try await withAppContext { _, _, workspace, _ in
            let panelID = try #require(workspace.focusedPanelId)
            let workspaceObserver = DockRuntimeParityUnreadObserver()
            let workspaceObservation = workspace.objectWillChange.sink {
                workspaceObserver.publicationCount += 1
            }
            let keyedInvalidationCount = OSAllocatedUnfairLock(initialState: 0)
            withObservationTracking {
                _ = workspace.manualUnreadPanelIds
            } onChange: {
                keyedInvalidationCount.withLock { $0 += 1 }
            }
            defer {
                workspaceObservation.cancel()
                workspace.clearManualUnread(panelId: panelID)
            }

            workspace.markPanelUnread(panelID)

            #expect(workspace.manualUnreadPanelIds == [panelID])
            #expect(keyedInvalidationCount.withLock { $0 } == 1)
            #expect(workspaceObserver.publicationCount == 0)
        }
    }

    @Test("Failed window Dock unread jump does not reveal its owner window")
    func failedWindowDockUnreadJumpDoesNotRevealOwnerWindow() async throws {
        try await withAppContext(fileExplorerState: nil) { appDelegate, _, _, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let window = try #require(appDelegate.windowForMainWindowId(windowID))
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let panel = DockRuntimeParityPanel(title: "Unavailable Dock unread")
            try dock.seedRuntimeParityPanel(panel)
            notificationStore.markRead(forTabId: windowID)
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.markRead(forTabId: windowID)
                appDelegate.notificationStore = previousNotificationStore
            }

            #expect(!window.isVisible)
            #expect(notificationStore.markWindowDockSurfaceUnread(
                windowId: windowID,
                surfaceId: panel.id
            ))

            _ = appDelegate.jumpToLatestUnread()

            #expect(!window.isVisible)
            #expect(notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: panel.id
            ))
        }
    }

    @Test("Unavailable workspace Dock focus preserves window and workspace selection")
    func unavailableWorkspaceDockFocusPreservesWindowAndSelection() async throws {
        try await withAppContext { appDelegate, manager, selectedWorkspace, windowID in
            let targetWorkspace = manager.addWorkspace(title: "Dock focus target", select: false)
            let targetDock = try #require(targetWorkspace.dockSplit)
            let initiallyFocusedPanel = DockRuntimeParityPanel(title: "Initially focused")
            let targetPanel = DockRuntimeParityPanel(title: "Focus target")
            try targetDock.seedRuntimeParityPanel(initiallyFocusedPanel)
            try targetDock.seedRuntimeParityPanel(targetPanel)
            targetDock.focusPanel(initiallyFocusedPanel.id)

            let window = try #require(appDelegate.windowForMainWindowId(windowID))
            window.orderOut(nil)
            #expect(manager.selectedTabId == selectedWorkspace.id)
            #expect(targetDock.focusedPanelId == initiallyFocusedPanel.id)
            #expect(!window.isVisible)

            let defaults = UserDefaults.standard
            let dockEnabledKey = RightSidebarBetaFeatureSettings.dockEnabledKey
            defaults.set(false, forKey: dockEnabledKey)
            defer { defaults.set(true, forKey: dockEnabledKey) }

            let envelope = try socketEnvelope(method: "surface.focus", params: [
                "workspace_id": targetWorkspace.id.uuidString,
                "surface_id": targetPanel.id.uuidString,
            ])

            #expect(envelope["ok"] as? Bool == false)
            let error = try #require(envelope["error"] as? [String: Any])
            #expect(error["code"] as? String == "unavailable")
            #expect(manager.selectedTabId == selectedWorkspace.id)
            #expect(targetDock.focusedPanelId == initiallyFocusedPanel.id)
            #expect(!window.isVisible)
        }
    }

    @Test("Toggle Unread mutates only the focused window Dock surface")
    func toggleUnreadMutatesOnlyFocusedWindowDockSurface() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let window = try #require(appDelegate.windowForMainWindowId(windowID))
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let panel = DockRuntimeParityPanel(title: "Focused Dock unread")
            let otherPanel = DockRuntimeParityPanel(title: "Other Dock unread")
            try dock.seedRuntimeParityPanel(panel)
            try dock.seedRuntimeParityPanel(otherPanel)
            notificationStore.markRead(forTabId: windowID)
            notificationStore.replaceNotificationsForTesting([
                TerminalNotification(
                    id: UUID(),
                    tabId: windowID,
                    surfaceId: panel.id,
                    title: "Focused Dock notification",
                    subtitle: "",
                    body: "Focused",
                    createdAt: .now,
                    isRead: false
                ),
                TerminalNotification(
                    id: UUID(),
                    tabId: windowID,
                    surfaceId: otherPanel.id,
                    title: "Other Dock notification",
                    subtitle: "",
                    body: "Other",
                    createdAt: .now,
                    isRead: false
                ),
            ])
            appDelegate.notificationStore = notificationStore
            dock.focusPanel(panel.id)
            appDelegate.keyboardFocusCoordinator(for: window)?
                .noteRightSidebarInteraction(mode: .dock)
            defer {
                notificationStore.replaceNotificationsForTesting([])
                notificationStore.markRead(forTabId: windowID)
                appDelegate.notificationStore = previousNotificationStore
            }

            #expect(workspace.manualUnreadPanelIds.isEmpty)
            #expect(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))
            #expect(!notificationStore.hasUnreadNotification(
                forTabId: windowID,
                surfaceId: panel.id
            ))
            #expect(!notificationStore.hasVisibleNotificationIndicator(
                forTabId: windowID,
                surfaceId: panel.id
            ))
            #expect(notificationStore.hasUnreadNotification(
                forTabId: windowID,
                surfaceId: otherPanel.id
            ))
            #expect(!notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: panel.id
            ))

            #expect(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))
            #expect(notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: panel.id
            ))
            #expect(workspace.manualUnreadPanelIds.isEmpty)

            #expect(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))
            #expect(!notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: panel.id
            ))
            #expect(notificationStore.hasUnreadNotification(
                forTabId: windowID,
                surfaceId: otherPanel.id
            ))
            #expect(workspace.manualUnreadPanelIds.isEmpty)
        }
    }

    @Test("Mark Oldest skips only the focused Dock surface when jumping")
    func markOldestSkipsOnlyFocusedDockSurfaceWhenJumping() async throws {
        try await withAppContext(fileExplorerState: FileExplorerState()) {
            appDelegate, _, workspace, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let window = try #require(appDelegate.windowForMainWindowId(windowID))
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let focusedPanel = DockRuntimeParityPanel(title: "Focused Dock surface")
            let otherUnreadPanel = DockRuntimeParityPanel(title: "Other Dock unread")
            try dock.seedRuntimeParityPanel(focusedPanel)
            try dock.seedRuntimeParityPanel(otherUnreadPanel)
            notificationStore.markRead(forTabId: windowID)
            appDelegate.notificationStore = notificationStore
            dock.focusPanel(focusedPanel.id)
            appDelegate.keyboardFocusCoordinator(for: window)?
                .noteRightSidebarInteraction(mode: .dock)
            #expect(notificationStore.markWindowDockSurfaceUnread(
                windowId: windowID,
                surfaceId: otherUnreadPanel.id
            ))
            defer {
                notificationStore.markRead(forTabId: windowID)
                appDelegate.notificationStore = previousNotificationStore
            }

            _ = appDelegate.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
                preferredWindow: window
            )

            #expect(notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: focusedPanel.id
            ))
            #expect(!notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: otherUnreadPanel.id
            ))
            #expect(dock.focusedPanelId == otherUnreadPanel.id)
            #expect(workspace.manualUnreadPanelIds.isEmpty)
        }
    }

    @Test("Mark Oldest ignores notifications on sibling Dock surfaces")
    func markOldestIgnoresSiblingDockSurfaceNotification() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let window = try #require(appDelegate.windowForMainWindowId(windowID))
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let focusedPanel = DockRuntimeParityPanel(title: "Focused Dock surface")
            let siblingPanel = DockRuntimeParityPanel(title: "Sibling Dock notification")
            try dock.seedRuntimeParityPanel(focusedPanel)
            try dock.seedRuntimeParityPanel(siblingPanel)
            notificationStore.markRead(forTabId: windowID)
            notificationStore.replaceNotificationsForTesting([
                TerminalNotification(
                    id: UUID(),
                    tabId: windowID,
                    surfaceId: siblingPanel.id,
                    title: "Sibling Dock notification",
                    subtitle: "",
                    body: "Sibling",
                    createdAt: .now,
                    isRead: false
                ),
            ])
            appDelegate.notificationStore = notificationStore
            dock.focusPanel(focusedPanel.id)
            appDelegate.keyboardFocusCoordinator(for: window)?
                .noteRightSidebarInteraction(mode: .dock)
            defer {
                notificationStore.replaceNotificationsForTesting([])
                notificationStore.markRead(forTabId: windowID)
                appDelegate.notificationStore = previousNotificationStore
            }

            _ = appDelegate.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
                preferredWindow: window
            )

            #expect(notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: focusedPanel.id
            ))
            #expect(!notificationStore.hasUnreadNotification(
                forTabId: windowID,
                surfaceId: siblingPanel.id
            ))
            #expect(dock.focusedPanelId == siblingPanel.id)
            #expect(workspace.manualUnreadPanelIds.isEmpty)
        }
    }

    @Test("Window Dock unread changes the session autosave fingerprint")
    func windowDockUnreadChangesSessionAutosaveFingerprint() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let panel = DockRuntimeParityPanel(title: "Persisted Dock unread")
            try dock.seedRuntimeParityPanel(panel)
            notificationStore.markRead(forTabId: windowID)
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.markRead(forTabId: windowID)
                appDelegate.notificationStore = previousNotificationStore
            }

            let cleanFingerprint = try #require(appDelegate.sessionAutosaveFingerprint(
                includeScrollback: false,
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: .empty
            ))
            #expect(notificationStore.markWindowDockSurfaceUnread(
                windowId: windowID,
                surfaceId: panel.id
            ))
            let unreadFingerprint = try #require(appDelegate.sessionAutosaveFingerprint(
                includeScrollback: false,
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: .empty
            ))

            #expect(unreadFingerprint != cleanFingerprint)
        }
    }

    @Test("Notification delivery excludes hidden workspace Docks without breaking scoped flashes")
    func notificationDeliveryExcludesHiddenWorkspaceDocks() async throws {
        try await withAppContext { appDelegate, manager, workspace, windowID in
            let workspaceDock = workspace.requiredDockSplitForTesting
            let globalDock = appDelegate.windowDock(forWindowId: windowID)
            let workspacePanel = DockRuntimeParityPanel(title: "Workspace Dock")
            let globalPanel = DockRuntimeParityPanel(title: "Global Dock")
            try workspaceDock.seedRuntimeParityPanel(workspacePanel)
            try globalDock.seedRuntimeParityPanel(globalPanel)

            let workspaceDelivery = appDelegate.agentNotificationDeliveryTarget(
                claimedTabId: workspace.id,
                surfaceId: workspacePanel.id
            )
            #expect(workspaceDelivery == nil)
            let globalDelivery = appDelegate.agentNotificationDeliveryTarget(
                claimedTabId: workspace.id,
                surfaceId: globalPanel.id
            )
            #expect(globalDelivery?.tabId == globalDock.workspaceId)
            #expect(globalDelivery?.surfaceId == globalPanel.id)

            workspace.triggerNotificationFocusFlash(
                panelId: workspacePanel.id,
                requiresSplit: false,
                shouldFocus: false
            )
            workspace.triggerNotificationFocusFlash(
                panelId: globalPanel.id,
                requiresSplit: false,
                shouldFocus: false
            )
            manager.workspaceTriggerNotificationDismissFlash(
                workspaceId: workspace.id,
                panelId: workspacePanel.id
            )
            manager.workspaceTriggerNotificationDismissFlash(
                workspaceId: globalDock.workspaceId,
                panelId: globalPanel.id
            )
            manager.workspaceTriggerUnreadIndicatorDismissFlash(
                workspaceId: workspace.id,
                panelId: workspacePanel.id
            )
            manager.workspaceTriggerUnreadIndicatorDismissFlash(
                workspaceId: globalDock.workspaceId,
                panelId: globalPanel.id
            )

            let expected: [WorkspaceAttentionFlashReason] = [
                .notificationArrival,
                .notificationDismiss,
                .unreadIndicatorDismiss,
            ]
            #expect(workspacePanel.flashReasons == expected)
            #expect(globalPanel.flashReasons == expected)
        }
    }

    @Test("Notification opens fail closed for hidden workspace Docks")
    func notificationOpensOnlyRenderedWindowDockPanels() async throws {
        let sidebarState = FileExplorerState()
        let previousSidebarVisibility = sidebarState.isVisible
        let previousSidebarMode = sidebarState.mode
        sidebarState.setVisible(false)
        sidebarState.mode = .files
        defer {
            sidebarState.mode = previousSidebarMode
            sidebarState.setVisible(previousSidebarVisibility)
        }

        try await withAppContext(fileExplorerState: sidebarState) { appDelegate, _, workspace, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let workspaceDock = try #require(workspace.dockSplit)
            let globalDock = appDelegate.windowDock(forWindowId: windowID)
            let workspacePanel = DockRuntimeParityPanel(title: "Workspace Dock")
            let initiallyFocusedGlobalPanel = DockRuntimeParityPanel(title: "Initially focused")
            let globalPanel = DockRuntimeParityPanel(title: "Global Dock")
            try workspaceDock.seedRuntimeParityPanel(workspacePanel)
            try globalDock.seedRuntimeParityPanel(initiallyFocusedGlobalPanel)
            try globalDock.seedRuntimeParityPanel(globalPanel)
            globalDock.focusPanel(initiallyFocusedGlobalPanel.id)

            let workspaceNotification = TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: workspacePanel.id,
                title: "Workspace Dock",
                subtitle: "",
                body: "Unread",
                createdAt: .now,
                isRead: false
            )
            let globalNotification = TerminalNotification(
                id: UUID(),
                tabId: globalDock.workspaceId,
                surfaceId: globalPanel.id,
                title: "Global Dock",
                subtitle: "",
                body: "Unread",
                createdAt: .now,
                isRead: false
            )
            notificationStore.replaceNotificationsForTesting([
                workspaceNotification,
                globalNotification,
            ])
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.replaceNotificationsForTesting([])
                appDelegate.notificationStore = previousNotificationStore
            }

            #expect(!appDelegate.openTerminalNotification(workspaceNotification))
            #expect(notificationStore.hasUnreadNotification(
                forTabId: workspace.id,
                surfaceId: workspacePanel.id
            ))
            #expect(!sidebarState.isVisible)
            #expect(sidebarState.mode == .files)
            #expect(globalDock.focusedPanelId == initiallyFocusedGlobalPanel.id)

            #expect(appDelegate.openTerminalNotification(globalNotification))
            #expect(globalDock.focusedPanelId == globalPanel.id)
            #expect(sidebarState.isVisible)
            #expect(sidebarState.mode == .dock)
            #expect(notificationStore.hasUnreadNotification(
                forTabId: workspace.id,
                surfaceId: workspacePanel.id
            ))
            #expect(!notificationStore.hasUnreadNotification(
                forTabId: globalDock.workspaceId,
                surfaceId: globalPanel.id
            ))
        }
    }

    @Test("Focusing a window Dock panel dismisses its unread notification")
    func focusingWindowDockPanelDismissesUnreadNotification() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            notificationStore.replaceNotificationsForTesting([])
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.replaceNotificationsForTesting([])
                appDelegate.notificationStore = previousNotificationStore
            }

            let dock = appDelegate.windowDock(forWindowId: windowID)
            let panel = DockRuntimeParityPanel(title: "Window Dock")
            try dock.seedRuntimeParityPanel(panel)
            let unreadProjection = DockUnreadPanelProjection(
                source: notificationStore.sidebarUnread,
                workspaceID: dock.workspaceId,
                panelIDs: [panel.id],
                isActive: true,
                agentAttentionSource: dock.agentNeedsInputAttention
            )
            notificationStore.replaceNotificationsForTesting([
                TerminalNotification(
                    id: UUID(),
                    tabId: dock.workspaceId,
                    surfaceId: panel.id,
                    title: "Dock",
                    subtitle: "",
                    body: "Unread",
                    createdAt: .now,
                    isRead: false
                ),
            ])

            #expect(notificationStore.hasUnreadNotification(
                forTabId: dock.workspaceId,
                surfaceId: panel.id
            ))
            #expect(unreadProjection.unreadPanelIDs == [panel.id])
            #expect(TerminalNotificationStore.dockBadgeLabel(
                unreadCount: notificationStore.unreadCount,
                isEnabled: true
            ) == "1")

            dock.focusPanelFromDockInteraction(panel.id, window: nil)

            #expect(!notificationStore.hasUnreadNotification(
                forTabId: dock.workspaceId,
                surfaceId: panel.id
            ))
            #expect(unreadProjection.unreadPanelIDs.isEmpty)
            #expect(notificationStore.unreadCount == 0)
            #expect(TerminalNotificationStore.dockBadgeLabel(
                unreadCount: notificationStore.unreadCount,
                isEnabled: true
            ) == nil)
            #expect(panel.flashReasons == [.notificationDismiss])
        }
    }

    @Test("Opening a window Dock notification clears its focused indicator and restores scroll")
    func openingWindowDockNotificationClearsFocusedIndicatorAndRestoresScroll() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let terminal = TerminalPanel(
                workspaceId: windowID,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            defer { terminal.surface.releaseSurfaceForTesting() }
            try dock.seedRuntimeParityPanel(terminal)

            let scrollPosition = TerminalNotificationScrollPosition(
                row: 120,
                totalRows: 500,
                rowSpaceRevision: 7
            )
            terminal.hostedView.notificationScrollRestoreState = NotificationScrollRestoreState(
                replay: .replaying(expectedEndBoundary: "dock-notification-open"),
                request: .idle
            )
            let notification = TerminalNotification(
                id: UUID(),
                tabId: windowID,
                surfaceId: terminal.id,
                title: "Dock terminal",
                subtitle: "",
                body: "Restore this transcript position",
                createdAt: .now,
                isRead: false,
                scrollPosition: scrollPosition
            )
            notificationStore.replaceNotificationsForTesting([notification])
            notificationStore.setFocusedReadIndicator(
                forTabId: windowID,
                surfaceId: terminal.id
            )
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.replaceNotificationsForTesting([])
                notificationStore.clearFocusedReadIndicator(forTabId: windowID)
                appDelegate.notificationStore = previousNotificationStore
            }

            #expect(
                notificationStore.focusedReadIndicatorSurfaceId(forTabId: windowID)
                    == terminal.id
            )
            #expect(!terminal.hostedView.hasPendingNotificationScrollRestore)

            #expect(appDelegate.openTerminalNotification(notification))

            #expect(
                notificationStore.focusedReadIndicatorSurfaceId(forTabId: windowID) == nil
            )
            #expect(
                terminal.hostedView.notificationScrollRestoreState.pendingPosition
                    == scrollPosition
            )
        }
    }

    @Test("Clearing workspace manual unread preserves window Dock pane unread")
    func clearingWorkspaceManualUnreadPreservesWindowDockPaneUnread() {
        let notificationStore = TerminalNotificationStore.shared
        let ownerID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        defer { notificationStore.markRead(forTabId: ownerID) }

        notificationStore.markUnread(forTabId: ownerID)
        notificationStore.markUnread(forTabId: ownerID, surfaceId: firstSurfaceID)
        notificationStore.markUnread(forTabId: ownerID, surfaceId: secondSurfaceID)

        #expect(notificationStore.clearManualUnread(forTabId: ownerID))
        #expect(!notificationStore.hasManualUnread(forTabId: ownerID))
        #expect(notificationStore.hasManualUnread(
            forTabId: ownerID,
            surfaceId: firstSurfaceID
        ))
        #expect(notificationStore.hasManualUnread(
            forTabId: ownerID,
            surfaceId: secondSurfaceID
        ))
    }

    @Test("Whole-owner mark read clears every window Dock pane unread")
    func wholeOwnerMarkReadClearsEveryWindowDockPaneUnread() {
        let notificationStore = TerminalNotificationStore.shared
        let ownerID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        defer { notificationStore.markRead(forTabId: ownerID) }

        notificationStore.markUnread(forTabId: ownerID)
        notificationStore.markUnread(forTabId: ownerID, surfaceId: firstSurfaceID)
        notificationStore.markUnread(forTabId: ownerID, surfaceId: secondSurfaceID)

        notificationStore.markRead(forTabId: ownerID)

        #expect(!notificationStore.hasManualUnread(forTabId: ownerID))
        #expect(!notificationStore.hasManualUnread(
            forTabId: ownerID,
            surfaceId: firstSurfaceID
        ))
        #expect(!notificationStore.hasManualUnread(
            forTabId: ownerID,
            surfaceId: secondSurfaceID
        ))
    }

    @Test("Jump to unread focuses the exact window Dock pane")
    func jumpToUnreadFocusesExactWindowDockPane() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            notificationStore.replaceNotificationsForTesting([])
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.markRead(forTabId: windowID)
                notificationStore.replaceNotificationsForTesting([])
                appDelegate.notificationStore = previousNotificationStore
            }

            let dock = appDelegate.windowDock(forWindowId: windowID)
            let initiallyFocusedPanel = DockRuntimeParityPanel(title: "Initially focused")
            let unreadPanel = DockRuntimeParityPanel(title: "Unread")
            try dock.seedRuntimeParityPanel(initiallyFocusedPanel)
            try dock.seedRuntimeParityPanel(unreadPanel)
            dock.focusPanel(initiallyFocusedPanel.id)
            notificationStore.markUnread(
                forTabId: windowID,
                surfaceId: unreadPanel.id
            )

            _ = appDelegate.jumpToLatestUnread()

            #expect(dock.focusedPanelId == unreadPanel.id)
            #expect(notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: unreadPanel.id
            ) == false)
        }
    }

    @Test("Jump to unread opens the most recently marked window Dock pane")
    func jumpToUnreadPrefersMostRecentlyMarkedWindowDockPane() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            notificationStore.replaceNotificationsForTesting([])
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.markRead(forTabId: windowID)
                notificationStore.replaceNotificationsForTesting([])
                appDelegate.notificationStore = previousNotificationStore
            }

            let dock = appDelegate.windowDock(forWindowId: windowID)
            let olderPanel = DockRuntimeParityPanel(
                id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                title: "Older unread"
            )
            let newerPanel = DockRuntimeParityPanel(
                id: try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFE")),
                title: "Newer unread"
            )
            try dock.seedRuntimeParityPanel(olderPanel)
            try dock.seedRuntimeParityPanel(newerPanel)
            notificationStore.markUnread(
                forTabId: windowID,
                surfaceId: olderPanel.id
            )
            notificationStore.markUnread(
                forTabId: windowID,
                surfaceId: newerPanel.id
            )

            _ = appDelegate.jumpToLatestUnread()

            #expect(dock.focusedPanelId == newerPanel.id)
            #expect(notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: olderPanel.id
            ))
            #expect(!notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: newerPanel.id
            ))
        }
    }

    @Test("Unavailable window Dock remains unread and jump falls through to workspace")
    func unavailableWindowDockUnreadFallsThroughToWorkspace() async throws {
        try await withAppContext(fileExplorerState: nil) { appDelegate, manager, workspace, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            notificationStore.replaceNotificationsForTesting([])
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.markRead(forTabId: windowID)
                notificationStore.replaceNotificationsForTesting([])
                appDelegate.notificationStore = previousNotificationStore
            }

            let dock = appDelegate.windowDock(forWindowId: windowID)
            let initiallyFocusedPanel = DockRuntimeParityPanel(title: "Initially focused")
            let dockPanel = DockRuntimeParityPanel(title: "Unavailable Dock unread")
            try dock.seedRuntimeParityPanel(initiallyFocusedPanel)
            try dock.seedRuntimeParityPanel(dockPanel)
            dock.focusPanel(initiallyFocusedPanel.id)
            notificationStore.markUnread(
                forTabId: windowID,
                surfaceId: dockPanel.id
            )
            let workspacePanelID = try #require(workspace.focusedPanelId)
            workspace.markPanelUnread(workspacePanelID)

            _ = appDelegate.jumpToLatestUnread()

            #expect(manager.selectedTabId == workspace.id)
            #expect(workspace.manualUnreadPanelIds.isEmpty)
            #expect(notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: dockPanel.id
            ))
            #expect(dock.focusedPanelId == initiallyFocusedPanel.id)
        }
    }

    @Test("Terminal bell attention targets only the rendered window Dock")
    func terminalBellAttentionTargetsOnlyRenderedWindowDock() async throws {
        try await withAppContext { appDelegate, manager, workspace, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let previousFocusOverride = AppFocusState.overrideIsFocused
            let defaults = UserDefaults.standard
            let paneFlashHadValue = defaults.object(
                forKey: NotificationPaneFlashSettings.enabledKey
            ) != nil
            let previousPaneFlashEnabled = defaults.bool(
                forKey: NotificationPaneFlashSettings.enabledKey
            )
            notificationStore.replaceNotificationsForTesting([])
            appDelegate.notificationStore = notificationStore
            AppFocusState.overrideIsFocused = false
            defer {
                if paneFlashHadValue {
                    defaults.set(
                        previousPaneFlashEnabled,
                        forKey: NotificationPaneFlashSettings.enabledKey
                    )
                } else {
                    defaults.removeObject(
                        forKey: NotificationPaneFlashSettings.enabledKey
                    )
                }
                AppFocusState.overrideIsFocused = previousFocusOverride
                notificationStore.replaceNotificationsForTesting([])
                appDelegate.notificationStore = previousNotificationStore
            }

            let workspaceDock = try #require(workspace.dockSplit)
            let globalDock = appDelegate.windowDock(forWindowId: windowID)
            let workspacePanel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            let globalPanel = TerminalPanel(
                workspaceId: windowID,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            try workspaceDock.seedRuntimeParityPanel(workspacePanel)
            try globalDock.seedRuntimeParityPanel(globalPanel)
            let workspaceProjection = DockUnreadPanelProjection(
                source: notificationStore.sidebarUnread,
                workspaceID: workspaceDock.workspaceId,
                panelIDs: [workspacePanel.id],
                isActive: true,
                agentAttentionSource: workspaceDock.agentNeedsInputAttention
            )
            let globalProjection = DockUnreadPanelProjection(
                source: notificationStore.sidebarUnread,
                workspaceID: globalDock.workspaceId,
                panelIDs: [globalPanel.id],
                isActive: true,
                agentAttentionSource: globalDock.agentNeedsInputAttention
            )
            let selectedWorkspace = manager.addWorkspace(select: true)
            let unreadObserver = DockRuntimeParityUnreadObserver()
            let unreadObservation = notificationStore.sidebarUnread.observeChanges(
                owner: unreadObserver
            ) { owner, _ in
                owner.publicationCount += 1
            }
            defer { unreadObservation.cancel() }

            #expect(workspacePanel.surface.onVisualBell == nil)
            let globalVisualBell = try #require(globalPanel.surface.onVisualBell)
            GhosttySurfaceScrollView.resetFlashCounts()
            defaults.set(false, forKey: NotificationPaneFlashSettings.enabledKey)
            globalVisualBell()
            let publicationCountAfterFirstBell = unreadObserver.publicationCount
            defaults.set(true, forKey: NotificationPaneFlashSettings.enabledKey)
            globalVisualBell()

            #expect(workspaceProjection.unreadPanelIDs.isEmpty)
            #expect(globalProjection.unreadPanelIDs == [globalPanel.id])
            #expect(notificationStore.unreadCount == 1)
            #expect(publicationCountAfterFirstBell == 1)
            #expect(unreadObserver.publicationCount == publicationCountAfterFirstBell)
            #expect(GhosttySurfaceScrollView.flashCount(for: globalPanel.id) == 1)
            #expect(TerminalNotificationStore.dockBadgeLabel(
                unreadCount: notificationStore.unreadCount,
                isEnabled: true
            ) == "1")
            #expect(manager.selectedTabId == selectedWorkspace.id)
            #expect(TerminalController.shared.activeTabManagerForCallerNotification() === manager)

            globalDock.focusPanel(globalPanel.id)
            #expect(manager.dismissNotificationOnTerminalInteraction(
                tabId: globalDock.workspaceId,
                surfaceId: globalPanel.id
            ))
            #expect(globalProjection.unreadPanelIDs.isEmpty)
            #expect(notificationStore.unreadCount == 0)
            #expect(TerminalNotificationStore.dockBadgeLabel(
                unreadCount: notificationStore.unreadCount,
                isEnabled: true
            ) == nil)
        }
    }

    @Test("A real notification atomically replaces window Dock visual-BEL unread")
    func realNotificationAtomicallyReplacesWindowDockVisualBellUnread() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let previousFocusOverride = AppFocusState.overrideIsFocused
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
            appDelegate.notificationStore = notificationStore
            AppFocusState.overrideIsFocused = false
            defer {
                AppFocusState.overrideIsFocused = previousFocusOverride
                notificationStore.markRead(forTabId: windowID)
                notificationStore.replaceNotificationsForTesting([])
                notificationStore.resetNotificationDeliveryHandlerForTesting()
                appDelegate.notificationStore = previousNotificationStore
            }

            let dock = appDelegate.windowDock(forWindowId: windowID)
            let terminal = TerminalPanel(
                workspaceId: windowID,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            try dock.seedRuntimeParityPanel(terminal)
            let unreadProjection = DockUnreadPanelProjection(
                source: notificationStore.sidebarUnread,
                workspaceID: windowID,
                panelIDs: [terminal.id],
                isActive: true,
                agentAttentionSource: dock.agentNeedsInputAttention
            )

            let visualBell = try #require(terminal.surface.onVisualBell)
            visualBell()
            #expect(notificationStore.unreadCount == 1)
            #expect(unreadProjection.unreadPanelIDs == [terminal.id])

            let observer = DockRuntimeParityUnreadObserver()
            let observation = notificationStore.sidebarUnread.observeChanges(
                owner: observer
            ) { owner, snapshot in
                owner.publicationCount += 1
                owner.totalUnreadCounts.append(snapshot.totalUnreadCount)
            }
            defer { observation.cancel() }

            notificationStore.addNotification(
                tabId: windowID,
                surfaceId: terminal.id,
                title: "Agent needs input",
                subtitle: "",
                body: "Review the pending request",
                resolvedHooks: []
            )

            #expect(observer.publicationCount == 1)
            #expect(observer.totalUnreadCounts == [1])
            #expect(unreadProjection.unreadPanelIDs == [terminal.id])
            #expect(!notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: terminal.id
            ))
            #expect(notificationStore.hasUnreadNotification(
                forTabId: windowID,
                surfaceId: terminal.id
            ))
        }
    }

    @Test("Unread notification mutations atomically replace window Dock visual-BEL unread")
    func unreadNotificationMutationsAtomicallyReplaceWindowDockVisualBellUnread() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let panel = DockRuntimeParityPanel(title: "Atomic Mark Oldest")
            try dock.seedRuntimeParityPanel(panel)
            let notificationID = UUID()
            notificationStore.replaceNotificationsForTesting([
                TerminalNotification(
                    id: notificationID,
                    tabId: windowID,
                    surfaceId: panel.id,
                    title: "Read notification",
                    subtitle: "",
                    body: "Ready to become unread",
                    createdAt: .now,
                    isRead: true
                ),
            ])
            appDelegate.notificationStore = notificationStore
            #expect(notificationStore.markWindowDockSurfaceUnread(
                windowId: windowID,
                surfaceId: panel.id
            ))
            defer {
                notificationStore.markRead(forTabId: windowID)
                notificationStore.replaceNotificationsForTesting([])
                appDelegate.notificationStore = previousNotificationStore
            }

            let unreadProjection = DockUnreadPanelProjection(
                source: notificationStore.sidebarUnread,
                workspaceID: windowID,
                panelIDs: [panel.id],
                isActive: true,
                agentAttentionSource: dock.agentNeedsInputAttention
            )
            let observer = DockRuntimeParityUnreadObserver()
            let observation = notificationStore.sidebarUnread.observeChanges(
                owner: observer
            ) { owner, snapshot in
                owner.publicationCount += 1
                owner.totalUnreadCounts.append(snapshot.totalUnreadCount)
            }
            defer { observation.cancel() }

            #expect(
                notificationStore.markLatestWindowDockNotificationAsOldestUnread(
                    windowId: windowID,
                    surfaceId: panel.id
                ) == notificationID
            )

            #expect(observer.publicationCount == 1)
            #expect(observer.totalUnreadCounts == [1])
            #expect(unreadProjection.unreadPanelIDs == [panel.id])
            #expect(!notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: panel.id
            ))
            #expect(notificationStore.hasUnreadNotification(
                forTabId: windowID,
                surfaceId: panel.id
            ))

            notificationStore.markRead(id: notificationID)
            #expect(notificationStore.markWindowDockSurfaceUnread(
                windowId: windowID,
                surfaceId: panel.id
            ))
            observer.publicationCount = 0
            observer.totalUnreadCounts = []

            notificationStore.markUnread(id: notificationID)

            #expect(observer.publicationCount == 1)
            #expect(observer.totalUnreadCounts == [1])
            #expect(unreadProjection.unreadPanelIDs == [panel.id])
            #expect(!notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: panel.id
            ))
            #expect(notificationStore.hasUnreadNotification(
                forTabId: windowID,
                surfaceId: panel.id
            ))
        }
    }

    @Test("Terminal bell in a non-key cmux window marks its Dock pane unread")
    func terminalBellInNonKeyCmuxWindowMarksDockPaneUnread() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let previousFocusOverride = AppFocusState.overrideIsFocused
            let ownerWindow = try #require(
                appDelegate.windowForMainWindowId(windowID)
            )
            appDelegate.notificationStore = notificationStore
            AppFocusState.overrideIsFocused = true
            defer {
                notificationStore.markRead(forTabId: windowID)
                appDelegate.notificationStore = previousNotificationStore
                AppFocusState.overrideIsFocused = previousFocusOverride
            }

            let dock = appDelegate.windowDock(forWindowId: windowID)
            let terminal = TerminalPanel(
                workspaceId: windowID,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            try dock.seedRuntimeParityPanel(terminal)
            dock.setVisibleInUI(true)
            defer { dock.setVisibleInUI(false) }
            dock.focusPanel(terminal.id)
            appDelegate.keyboardFocusCoordinator(for: ownerWindow)?
                .noteRightSidebarInteraction(mode: .dock)
            ownerWindow.contentView?.addSubview(terminal.hostedView)
            // CI app hosts cannot reliably make a programmatic peer window key.
            // The routing contract only requires this terminal's owner to be non-key.
            ownerWindow.orderOut(nil)

            #expect(terminal.surface.uiWindow === ownerWindow)
            #expect(
                appDelegate.focusedDockStoreForShortcut(
                    preferredWindow: ownerWindow
                ) === dock
            )
            #expect(NSApp.keyWindow !== ownerWindow)

            let visualBell = try #require(terminal.surface.onVisualBell)
            visualBell()

            #expect(notificationStore.hasManualUnread(
                forTabId: windowID,
                surfaceId: terminal.id
            ))
            #expect(NSApp.keyWindow !== ownerWindow)
        }
    }

    @Test("Physical key input clears visual-BEL unread in a secondary window Dock")
    func physicalKeyInputClearsVisualBellUnreadInSecondaryWindowDock() async throws {
        try await withAppContext { appDelegate, primaryManager, _, _ in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let secondaryManager = TabManager(autoWelcomeIfNeeded: false)
            let secondaryWindowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: secondaryManager
            )
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.markRead(forTabId: secondaryWindowID)
                appDelegate.unregisterMainWindowContextForTesting(windowId: secondaryWindowID)
                secondaryManager.tabs.forEach { $0.teardownAllPanels() }
                appDelegate.notificationStore = previousNotificationStore
            }

            let dock = appDelegate.windowDock(forWindowId: secondaryWindowID)
            let terminal = TerminalPanel(
                workspaceId: secondaryWindowID,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            try dock.seedRuntimeParityPanel(terminal)
            dock.focusPanel(terminal.id)

            let visualBell = try #require(terminal.surface.onVisualBell)
            visualBell()
            #expect(notificationStore.hasManualUnread(
                forTabId: secondaryWindowID,
                surfaceId: terminal.id
            ))
            #expect(appDelegate.tabManager === primaryManager)
            #expect(appDelegate.dockReferenceTabManager(for: dock) === secondaryManager)

            terminal.surface.requestInputDemandSurfaceStartIfNeeded()
            await waitForLiveSurface(terminal.surface)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            ))
            terminal.hostedView.surfaceView.keyDown(with: event)

            #expect(!notificationStore.hasManualUnread(
                forTabId: secondaryWindowID,
                surfaceId: terminal.id
            ))
        }
    }

    @Test("Window Dock unread follows a surface transfer exactly once")
    func windowDockUnreadFollowsSurfaceTransferExactlyOnce() async throws {
        try await withAppContext { appDelegate, _, _, sourceWindowID in
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let destinationWindowID = UUID()
            notificationStore.replaceNotificationsForTesting([])
            appDelegate.notificationStore = notificationStore
            defer {
                notificationStore.markRead(forTabId: sourceWindowID)
                notificationStore.markRead(forTabId: destinationWindowID)
                notificationStore.replaceNotificationsForTesting([])
                appDelegate.notificationStore = previousNotificationStore
            }

            let sourceDock = appDelegate.windowDock(forWindowId: sourceWindowID)
            let destinationDock = DockSplitStore(
                workspaceId: destinationWindowID,
                scope: .global,
                baseDirectoryProvider: { nil }
            )
            let panel = DockRuntimeParityPanel(title: "Transferred unread")
            try sourceDock.seedRuntimeParityPanel(panel)
            notificationStore.markWindowDockSurfaceUnread(
                windowId: sourceWindowID,
                surfaceId: panel.id
            )

            let detached = try #require(sourceDock.detachSurface(panelId: panel.id))

            #expect(detached.manuallyUnread)
            #expect(!notificationStore.hasManualUnread(
                forTabId: sourceWindowID,
                surfaceId: panel.id
            ))
            let destinationPane = try #require(
                destinationDock.bonsplitController.allPaneIds.first
            )
            #expect(destinationDock.attachDetachedSurface(
                detached,
                inPane: destinationPane,
                focus: false
            ) == panel.id)
            #expect(notificationStore.hasManualUnread(
                forTabId: destinationWindowID,
                surfaceId: panel.id
            ))

            #expect(notificationStore.clearWindowDockSurfaceUnread(
                windowId: destinationWindowID,
                surfaceId: panel.id
            ))
            let detachedAfterClear = try #require(
                destinationDock.detachSurface(panelId: panel.id)
            )
            #expect(!detachedAfterClear.manuallyUnread)
            let sourcePane = try #require(
                sourceDock.bonsplitController.allPaneIds.first
            )
            #expect(sourceDock.attachDetachedSurface(
                detachedAfterClear,
                inPane: sourcePane,
                focus: false
            ) == panel.id)
            #expect(!notificationStore.hasManualUnread(
                forTabId: sourceWindowID,
                surfaceId: panel.id
            ))
            #expect(sourceDock.closePanel(panel.id, force: true))
            #expect(!notificationStore.hasManualUnread(
                forTabId: destinationWindowID,
                surfaceId: panel.id
            ))
        }
    }

    @Test("Explicit socket flashes route as user initiated in both Dock scopes")
    func explicitSocketFlashesRouteAsUserInitiatedInBothDockScopes() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let workspaceDock = workspace.requiredDockSplitForTesting
            let globalDock = appDelegate.windowDock(forWindowId: windowID)
            let workspacePanel = DockRuntimeParityPanel(title: "Workspace Dock")
            let globalPanel = DockRuntimeParityPanel(title: "Global Dock")
            try workspaceDock.seedRuntimeParityPanel(workspacePanel)
            try globalDock.seedRuntimeParityPanel(globalPanel)

            let workspaceFlash = TerminalController.shared.controlSurfaceTriggerFlash(
                routing: ControlRoutingSelectors(
                    hasWindowIDParam: true,
                    windowID: windowID,
                    groupID: nil,
                    workspaceID: workspace.id,
                    surfaceID: workspacePanel.id,
                    paneID: nil
                ),
                surfaceID: workspacePanel.id
            )
            guard case .flashed(_, let workspaceID, let workspaceSurfaceID) = workspaceFlash else {
                Issue.record("Workspace Dock flash did not resolve: \(workspaceFlash)")
                return
            }
            #expect(workspaceID == workspace.id)
            #expect(workspaceSurfaceID == workspacePanel.id)

            let globalFlash = TerminalController.shared.controlSurfaceTriggerFlash(
                routing: ControlRoutingSelectors(
                    hasWindowIDParam: true,
                    windowID: windowID,
                    groupID: nil,
                    workspaceID: globalDock.workspaceId,
                    surfaceID: globalPanel.id,
                    paneID: nil
                ),
                surfaceID: globalPanel.id
            )
            guard case .flashed(_, let globalWorkspaceID, let globalSurfaceID) = globalFlash else {
                Issue.record("Global Dock flash did not resolve: \(globalFlash)")
                return
            }
            #expect(globalWorkspaceID == globalDock.workspaceId)
            #expect(globalSurfaceID == globalPanel.id)
            #expect(workspacePanel.flashReasons == [.userInitiated])
            #expect(globalPanel.flashReasons == [.userInitiated])
        }
    }

    @Test(
        "Dock surfaces are discoverable and workspace Dock terminals resolve by bare ID",
        .timeLimit(.minutes(1))
    )
    func topologyAndBareIDRoutingIncludeBothDockScopes() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let workspaceDock = workspace.requiredDockSplitForTesting
            let globalDock = appDelegate.windowDock(forWindowId: windowID)
            let workspaceTerminal = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            let globalPanel = DockRuntimeParityPanel(title: "Global Dock")
            let workspacePane = try workspaceDock.seedRuntimeParityPanel(workspaceTerminal)
            let globalPane = try globalDock.seedRuntimeParityPanel(globalPanel)
            let params = ["workspace_id": workspace.id.uuidString]

            let surfaceList = try socketResult(method: "surface.list", params: params)
            let surfaces = try #require(surfaceList["surfaces"] as? [[String: Any]])
            let workspaceSurface = try #require(surfaces.first {
                $0["id"] as? String == workspaceTerminal.id.uuidString
            })
            let globalSurface = try #require(surfaces.first {
                $0["id"] as? String == globalPanel.id.uuidString
            })
            #expect(workspaceSurface["dock_scope"] as? String == "workspace")
            #expect(globalSurface["dock_scope"] as? String == "global")

            let paneList = try socketResult(method: "pane.list", params: params)
            let panes = try #require(paneList["panes"] as? [[String: Any]])
            let workspacePaneRow = try #require(panes.first {
                $0["id"] as? String == workspacePane.id.uuidString
            })
            let globalPaneRow = try #require(panes.first {
                $0["id"] as? String == globalPane.id.uuidString
            })
            #expect(workspacePaneRow["dock_scope"] as? String == "workspace")
            #expect(globalPaneRow["dock_scope"] as? String == "global")
            #expect(workspacePaneRow["pixel_frame"] == nil)
            #expect(globalPaneRow["pixel_frame"] == nil)

            for (paneID, surfaceID, scope) in [
                (workspacePane.id, workspaceTerminal.id, "workspace"),
                (globalPane.id, globalPanel.id, "global"),
            ] {
                let result = try socketResult(
                    method: "pane.surfaces",
                    params: ["pane_id": paneID.uuidString]
                )
                #expect(result["dock_scope"] as? String == scope)
                let paneSurfaces = try #require(result["surfaces"] as? [[String: Any]])
                #expect(paneSurfaces.contains { $0["id"] as? String == surfaceID.uuidString })
            }

            let tree = try socketResult(method: "system.tree", params: params)
            let windows = try #require(tree["windows"] as? [[String: Any]])
            let treeWorkspaces = windows.flatMap { $0["workspaces"] as? [[String: Any]] ?? [] }
            let treePanes = treeWorkspaces.flatMap { $0["panes"] as? [[String: Any]] ?? [] }
            #expect(treePanes.contains {
                $0["id"] as? String == workspacePane.id.uuidString &&
                    $0["dock_scope"] as? String == "workspace"
            })
            #expect(treePanes.contains {
                $0["id"] as? String == globalPane.id.uuidString &&
                    $0["dock_scope"] as? String == "global"
            })
            let treeSurfaces = treePanes.flatMap { $0["surfaces"] as? [[String: Any]] ?? [] }
            #expect(treeSurfaces.contains {
                $0["id"] as? String == workspaceTerminal.id.uuidString &&
                    $0["dock_scope"] as? String == "workspace"
            })
            #expect(treeSurfaces.contains {
                $0["id"] as? String == globalPanel.id.uuidString &&
                    $0["dock_scope"] as? String == "global"
            })

            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: nil,
                surfaceID: workspaceTerminal.id,
                paneID: nil
            )
            let send = TerminalController.shared.controlSurfaceSendText(
                routing: routing,
                surfaceID: workspaceTerminal.id,
                hasSurfaceIDParam: true,
                text: "dock input"
            )
            guard case .sent(_, _, let sentSurfaceID, _) = send else {
                Issue.record("Workspace Dock send did not resolve its terminal: \(send)")
                return
            }
            #expect(sentSurfaceID == workspaceTerminal.id)

            await waitForLiveSurface(workspaceTerminal.surface)
            try #require(workspaceTerminal.surface.hasLiveSurface)
            let readEnvelope = try await socketEnvelopeOnWorker(
                method: "surface.read_text",
                params: [
                    "surface_id": workspaceTerminal.id.uuidString,
                ]
            )
            try #require(readEnvelope["ok"] as? Bool == true, "\(readEnvelope)")
            let readResult = try #require(readEnvelope["result"] as? [String: Any])
            #expect(readResult["surface_id"] as? String == workspaceTerminal.id.uuidString)
        }
    }
}

@MainActor
@Suite("Dock notification attention", .serialized)
struct DockNotificationAttentionTests {
    @Test("Single-pane Dock attention bypasses workspace split gating")
    func singlePaneDockAttentionBypassesWorkspaceSplitGating() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = DockRuntimeParityPanel(title: "Dock")
        try dock.seedRuntimeParityPanel(panel)

        let appDelegate = try #require(AppDelegate.shared, "Expected app-host AppDelegate")
        let routed = appDelegate.routeNotificationAttentionFlash(
            workspaceID: dock.workspaceId,
            panelID: panel.id,
            reason: .notificationArrival,
            requiresSplit: true
        )

        #expect(routed)
        #expect(panel.flashReasons == [.notificationArrival])
    }

    @Test("Dock unread projection is scoped to active Dock panels")
    func dockUnreadProjectionIsScopedToActiveDockPanels() {
        let workspaceID = UUID()
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let foreignPanelID = UUID()
        let unread = SidebarUnreadModel()
        let agentAttention = SurfaceAttentionModel()
        let projection = DockUnreadPanelProjection(
            source: unread,
            workspaceID: workspaceID,
            panelIDs: [firstPanelID, secondPanelID],
            isActive: true,
            agentAttentionSource: agentAttention
        )

        unread.apply(
            totalUnreadCount: 2,
            summaries: [:],
            unreadSurfaceKeys: [
                SidebarSurfaceUnreadKey(workspaceId: workspaceID, surfaceId: firstPanelID),
                SidebarSurfaceUnreadKey(workspaceId: UUID(), surfaceId: foreignPanelID),
            ],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        #expect(projection.unreadPanelIDs == [firstPanelID])

        unread.apply(
            totalUnreadCount: 1,
            summaries: [:],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [workspaceID: secondPanelID],
            manualUnreadWorkspaceIds: []
        )
        #expect(projection.unreadPanelIDs == [secondPanelID])

        agentAttention.setAttention(true, forSurfaceId: firstPanelID)
        #expect(projection.unreadPanelIDs == [firstPanelID, secondPanelID])
        agentAttention.setAttention(false, forSurfaceId: firstPanelID)
        #expect(projection.unreadPanelIDs == [secondPanelID])

        projection.updateContext(
            panelIDs: [firstPanelID, secondPanelID],
            isActive: false
        )
        #expect(projection.unreadPanelIDs.isEmpty)

        unread.apply(
            totalUnreadCount: 1,
            summaries: [:],
            unreadSurfaceKeys: [
                SidebarSurfaceUnreadKey(workspaceId: workspaceID, surfaceId: firstPanelID),
            ],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        #expect(projection.unreadPanelIDs.isEmpty)

        projection.updateContext(
            panelIDs: [firstPanelID, secondPanelID],
            isActive: true
        )
        #expect(projection.unreadPanelIDs == [firstPanelID])
    }

    @Test("Dock panel content receives projected unread state")
    func dockPanelContentReceivesProjectedUnreadState() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = DockRuntimeParityPanel(title: "Dock")
        let paneID = try dock.seedRuntimeParityPanel(panel)
        let tabID = try #require(dock.surfaceId(forPanelId: panel.id))
        let content = DockSplitContentView(
            store: dock,
            appearance: .fromConfig(WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "test.dock.unread")),
            appearanceRevision: 0,
            windowAppearance: .rightSidebarPanelViewTestDefault,
            rightSidebarOwnsInputFocus: false,
            unreadPanelIDs: [panel.id]
        )

        let unreadPanelView = content.panelView(panel: panel, tabID: tabID, paneID: paneID)
        let readContent = DockSplitContentView(
            store: dock,
            appearance: content.appearance,
            appearanceRevision: 0,
            windowAppearance: content.windowAppearance,
            rightSidebarOwnsInputFocus: false,
            unreadPanelIDs: []
        )
        let readPanelView = readContent.panelView(panel: panel, tabID: tabID, paneID: paneID)

        #expect(unreadPanelView.panelContentView().hasUnreadNotification)
        #expect(unreadPanelView != readPanelView)
        let otherUnreadContent = DockSplitContentView(store: dock, appearance: content.appearance, appearanceRevision: 0, windowAppearance: content.windowAppearance, rightSidebarOwnsInputFocus: false, unreadPanelIDs: [UUID()])
        #expect(readPanelView == otherUnreadContent.panelView(panel: panel, tabID: tabID, paneID: paneID))
    }
}
