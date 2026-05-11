import XCTest
import Bonsplit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationClearAllTests: XCTestCase {
    func testQueuedClearAllRemovesAlreadyDeliveredNotification() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Delivered",
            subtitle: "Before clear",
            body: "Body"
        )
        TerminalMutationBus.shared.drainForTesting()
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))

        TerminalMutationBus.shared.enqueueClearAllNotifications()
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertTrue(store.notifications.isEmpty)
    }

    func testClosingPaneRemovesSurfaceNotificationContribution() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let notifiedPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal)
        )
        let notifiedPaneId = try XCTUnwrap(workspace.paneId(forPanelId: notifiedPanel.id))

        store.addNotification(
            tabId: workspace.id,
            surfaceId: notifiedPanel.id,
            title: "Pane done",
            subtitle: "",
            body: "Close should drop this surface contribution"
        )

        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: notifiedPanel.id))

        XCTAssertTrue(workspace.bonsplitController.closePane(notifiedPaneId))

        XCTAssertNil(workspace.panels[notifiedPanel.id])
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 0)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: notifiedPanel.id))
        XCTAssertFalse(store.notifications.contains { $0.surfaceId == notifiedPanel.id })
    }

    func testClosingPaneRemovesFocusedReadIndicatorWithoutNotificationRows() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let indicatorPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal)
        )
        let indicatorPaneId = try XCTUnwrap(workspace.paneId(forPanelId: indicatorPanel.id))

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: indicatorPanel.id)

        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 0)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: indicatorPanel.id))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: indicatorPanel.id))

        XCTAssertTrue(workspace.bonsplitController.closePane(indicatorPaneId))

        XCTAssertNil(workspace.panels[indicatorPanel.id])
        XCTAssertNil(store.focusedReadIndicatorSurfaceId(forTabId: workspace.id))
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: indicatorPanel.id))
        XCTAssertTrue(store.notifications.isEmpty)
    }

    func testClosingPaneClearsPanelOwnedAgentRuntimeState() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        appDelegate.tabManager = manager

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = originalTabManager
        }

        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let agentPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal)
        )
        let agentPaneId = try XCTUnwrap(workspace.paneId(forPanelId: agentPanel.id))
        let pidKey = "codex.agent-session-close"
        let port = 54321

        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Running")
        workspace.recordAgentPID(key: pidKey, pid: pid_t(12345), panelId: agentPanel.id)
        workspace.agentListeningPorts = [port]
        workspace.recomputeListeningPorts()

        XCTAssertEqual(workspace.agentPIDs[pidKey].map(Int.init), 12345)
        XCTAssertTrue(workspace.listeningPorts.contains(port))

        XCTAssertTrue(workspace.bonsplitController.closePane(agentPaneId))

        XCTAssertNil(workspace.panels[agentPanel.id])
        XCTAssertNil(workspace.statusEntries["codex"])
        XCTAssertNil(workspace.agentPIDs[pidKey])
        XCTAssertTrue(workspace.agentListeningPorts.isEmpty)
        XCTAssertFalse(workspace.listeningPorts.contains(port))
    }

    func testClosingPanePreservesSharedAgentStatusForSiblingPanel() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        appDelegate.tabManager = manager

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = originalTabManager
        }

        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let firstPaneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let secondPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal)
        )

        let firstPIDKey = "codex.agent-session-a"
        let secondPIDKey = "codex.agent-session-b"
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Running")
        workspace.recordAgentPID(key: firstPIDKey, pid: pid_t(12345), panelId: firstPanelId)
        workspace.recordAgentPID(key: secondPIDKey, pid: pid_t(12346), panelId: secondPanel.id)

        XCTAssertTrue(workspace.bonsplitController.closePane(firstPaneId))

        XCTAssertNil(workspace.panels[firstPanelId])
        XCTAssertNil(workspace.agentPIDs[firstPIDKey])
        XCTAssertEqual(workspace.agentPIDs[secondPIDKey].map(Int.init), 12346)
        XCTAssertEqual(workspace.statusEntries["codex"]?.value, "Running")
    }

    func testDetachingSurfaceRebindsNotificationContributionToDestinationWorkspace() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let sourceWorkspace = manager.addWorkspace(select: true)
        let destinationWorkspace = manager.addWorkspace(select: false)
        defer {
            if manager.tabs.contains(where: { $0.id == destinationWorkspace.id }) {
                manager.closeWorkspace(destinationWorkspace)
            }
            if manager.tabs.contains(where: { $0.id == sourceWorkspace.id }) {
                manager.closeWorkspace(sourceWorkspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let movingPanelId = try XCTUnwrap(sourceWorkspace.focusedPanelId)

        store.addNotification(
            tabId: sourceWorkspace.id,
            surfaceId: movingPanelId,
            title: "Detached",
            subtitle: "",
            body: "Move should rebind this surface contribution"
        )
        store.setFocusedReadIndicator(forTabId: sourceWorkspace.id, surfaceId: movingPanelId)

        XCTAssertEqual(store.unreadCount(forTabId: sourceWorkspace.id), 1)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: sourceWorkspace.id, surfaceId: movingPanelId))

        let transfer = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: movingPanelId))
        let destinationPaneId = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        XCTAssertNotNil(
            destinationWorkspace.attachDetachedSurface(transfer, inPane: destinationPaneId, focus: false)
        )

        XCTAssertEqual(store.unreadCount(forTabId: sourceWorkspace.id), 0)
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: sourceWorkspace.id, surfaceId: movingPanelId))
        XCTAssertFalse(store.notifications.contains { $0.tabId == sourceWorkspace.id && $0.surfaceId == movingPanelId })

        XCTAssertEqual(store.unreadCount(forTabId: destinationWorkspace.id), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: destinationWorkspace.id, surfaceId: movingPanelId))
        XCTAssertEqual(store.focusedReadIndicatorSurfaceId(forTabId: destinationWorkspace.id), movingPanelId)
        XCTAssertTrue(store.notifications.contains { $0.tabId == destinationWorkspace.id && $0.surfaceId == movingPanelId })
    }

    func testDetachingSurfaceDoesNotOverwriteDestinationFocusedReadIndicator() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let sourceWorkspace = manager.addWorkspace(select: true)
        let destinationWorkspace = manager.addWorkspace(select: false)
        defer {
            if manager.tabs.contains(where: { $0.id == destinationWorkspace.id }) {
                manager.closeWorkspace(destinationWorkspace)
            }
            if manager.tabs.contains(where: { $0.id == sourceWorkspace.id }) {
                manager.closeWorkspace(sourceWorkspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let movingPanelId = try XCTUnwrap(sourceWorkspace.focusedPanelId)
        let destinationIndicatorPanelId = try XCTUnwrap(destinationWorkspace.focusedPanelId)
        store.setFocusedReadIndicator(forTabId: sourceWorkspace.id, surfaceId: movingPanelId)
        store.setFocusedReadIndicator(forTabId: destinationWorkspace.id, surfaceId: destinationIndicatorPanelId)

        let transfer = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: movingPanelId))
        let destinationPaneId = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        XCTAssertNotNil(
            destinationWorkspace.attachDetachedSurface(transfer, inPane: destinationPaneId, focus: false)
        )

        XCTAssertNil(store.focusedReadIndicatorSurfaceId(forTabId: sourceWorkspace.id))
        XCTAssertEqual(
            store.focusedReadIndicatorSurfaceId(forTabId: destinationWorkspace.id),
            destinationIndicatorPanelId
        )
    }

    func testDetachingSurfaceTransfersPanelOwnedAgentRuntimeStateToDestinationWorkspace() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        appDelegate.tabManager = manager

        let sourceWorkspace = manager.addWorkspace(select: true)
        let destinationWorkspace = manager.addWorkspace(select: false)
        defer {
            if manager.tabs.contains(where: { $0.id == destinationWorkspace.id }) {
                manager.closeWorkspace(destinationWorkspace)
            }
            if manager.tabs.contains(where: { $0.id == sourceWorkspace.id }) {
                manager.closeWorkspace(sourceWorkspace)
            }
            appDelegate.tabManager = originalTabManager
        }

        let movingPanelId = try XCTUnwrap(sourceWorkspace.focusedPanelId)
        let pidKey = "codex.agent-session-detach"
        let port = 54322
        let status = SidebarStatusEntry(key: "codex", value: "Running")
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "agent-session-detach",
            workingDirectory: nil,
            launchCommand: nil
        )

        sourceWorkspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: movingPanelId)
        sourceWorkspace.setRestoredAgentAutoResumePendingForTesting(true, panelId: movingPanelId)
        sourceWorkspace.statusEntries["codex"] = status
        sourceWorkspace.recordAgentPID(key: pidKey, pid: pid_t(12346), panelId: movingPanelId)
        sourceWorkspace.agentListeningPorts = [port]
        sourceWorkspace.recomputeListeningPorts()

        let transfer = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: movingPanelId))
        let destinationPaneId = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        XCTAssertNil(sourceWorkspace.statusEntries["codex"])
        XCTAssertNil(sourceWorkspace.agentPIDs[pidKey])
        XCTAssertNil(sourceWorkspace.restoredAgentSnapshotForTesting(panelId: movingPanelId))
        XCTAssertFalse(sourceWorkspace.restoredAgentAutoResumePendingForTesting(panelId: movingPanelId))
        XCTAssertFalse(sourceWorkspace.listeningPorts.contains(port))

        XCTAssertNotNil(
            destinationWorkspace.attachDetachedSurface(transfer, inPane: destinationPaneId, focus: false)
        )

        XCTAssertEqual(destinationWorkspace.statusEntries["codex"]?.value, status.value)
        XCTAssertEqual(destinationWorkspace.agentPIDs[pidKey].map(Int.init), 12346)
        XCTAssertEqual(
            destinationWorkspace.restoredAgentSnapshotForTesting(panelId: movingPanelId)?.sessionId,
            "agent-session-detach"
        )
        XCTAssertTrue(destinationWorkspace.restoredAgentAutoResumePendingForTesting(panelId: movingPanelId))
    }

    func testDetachingRestoredSnapshotWithoutPanelPIDDoesNotTransferAgentRuntimeStatus() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        appDelegate.tabManager = manager

        let sourceWorkspace = manager.addWorkspace(select: true)
        let destinationWorkspace = manager.addWorkspace(select: false)
        defer {
            if manager.tabs.contains(where: { $0.id == destinationWorkspace.id }) {
                manager.closeWorkspace(destinationWorkspace)
            }
            if manager.tabs.contains(where: { $0.id == sourceWorkspace.id }) {
                manager.closeWorkspace(sourceWorkspace)
            }
            appDelegate.tabManager = originalTabManager
        }

        let movingPanelId = try XCTUnwrap(sourceWorkspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "restored-only",
            workingDirectory: nil,
            launchCommand: nil
        )

        sourceWorkspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: movingPanelId)
        sourceWorkspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Running")

        let transfer = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: movingPanelId))
        let destinationPaneId = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        XCTAssertNotNil(
            destinationWorkspace.attachDetachedSurface(transfer, inPane: destinationPaneId, focus: false)
        )

        XCTAssertNil(destinationWorkspace.statusEntries["codex"])
        XCTAssertTrue(destinationWorkspace.agentPIDs.isEmpty)
        XCTAssertEqual(
            destinationWorkspace.restoredAgentSnapshotForTesting(panelId: movingPanelId)?.sessionId,
            "restored-only"
        )
    }
}
