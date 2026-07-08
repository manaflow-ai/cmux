import XCTest
import Bonsplit
import Darwin
import CmuxSidebar

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

    func testClearNotificationsCommandWithPanelPreservesSiblingSurfaceNotifications() throws {
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

        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal)
        )

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: firstPanelId,
            title: "Grok",
            subtitle: "Waiting",
            body: "First"
        )
        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: secondPanel.id,
            title: "Grok",
            subtitle: "Waiting",
            body: "Second"
        )
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: firstPanelId))
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: secondPanel.id))

        let response = TerminalController.shared.handleSocketLine(
            "clear_notifications --tab=\(workspace.id.uuidString) --panel=\(firstPanelId.uuidString)"
        )
        XCTAssertEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: firstPanelId))
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: secondPanel.id))
        XCTAssertEqual(store.notifications.count, 1)
        XCTAssertEqual(store.notifications.first?.surfaceId, secondPanel.id)
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

    func testStructuredAgentHookRuntimeSuppressesRawTerminalNotificationsForOwnedPanelOnly() throws {
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
        let secondPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal)
        )

        workspace.recordAgentPID(key: "codex.codex-session-123", pid: pid_t(12345), panelId: firstPanelId)

        XCTAssertTrue(workspace.suppressesRawTerminalNotification(panelId: firstPanelId))
        XCTAssertFalse(workspace.suppressesRawTerminalNotification(panelId: secondPanel.id))
        XCTAssertFalse(workspace.suppressesRawTerminalNotification(panelId: nil))

        workspace.recordAgentPID(key: "custom-tool.session", pid: pid_t(12346), panelId: secondPanel.id)

        XCTAssertFalse(workspace.suppressesRawTerminalNotification(panelId: secondPanel.id))

        let managedSubagentPanel = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: secondPanel.id,
                orientation: .horizontal,
                startupEnvironment: ["CMUX_AGENT_MANAGED_SUBAGENT": "1"]
            )
        )

        XCTAssertTrue(workspace.suppressesRawTerminalNotification(panelId: managedSubagentPanel.id))
        XCTAssertFalse(workspace.suppressesRawTerminalNotification(panelId: secondPanel.id))
    }

    func testSidebarStatusFallsBackToPanelOwnedStructuredAgentRuntimeWithoutStatusEntry() throws {
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

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let pidKey = "codex.codex-session-fallback"
        workspace.recordAgentPID(key: pidKey, pid: getpid(), panelId: panelId, refreshPorts: false)

        var fallbackEntry = try XCTUnwrap(
            workspace.sidebarStatusEntriesInDisplayOrder().first { $0.key == "codex" }
        )
        XCTAssertEqual(
            fallbackEntry.value,
            String(localized: "agent.generic.status.running", defaultValue: "Running")
        )
        XCTAssertEqual(fallbackEntry.icon, "play.fill")
        XCTAssertEqual(fallbackEntry.color, "#34C759")
        XCTAssertNil(workspace.statusEntries["codex"])

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .needsInput)

        fallbackEntry = try XCTUnwrap(
            workspace.sidebarStatusEntriesInDisplayOrder().first { $0.key == "codex" }
        )
        XCTAssertEqual(
            fallbackEntry.value,
            String.localizedStringWithFormat(
                String(localized: "agent.generic.notification.status.needsInput", defaultValue: "%@ needs input"),
                "Codex"
            )
        )
        XCTAssertEqual(fallbackEntry.icon, "exclamationmark.circle.fill")
        XCTAssertEqual(fallbackEntry.color, "#FF9F0A")
        XCTAssertNil(workspace.statusEntries["codex"])
    }

    func testSidebarStatusOnlyShowsStructuredAgentStatusBackedByLivePanelRuntime() throws {
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

        let livePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let stalePanelId = UUID()

        workspace.statusEntries["grok"] = SidebarStatusEntry(key: "grok", value: "Idle")
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Running")
        workspace.statusEntries["amp"] = SidebarStatusEntry(key: "amp", value: "Idle")
        workspace.statusEntries["build"] = SidebarStatusEntry(key: "build", value: "Compiling")

        workspace.recordAgentPID(key: "grok.grok-session-live", pid: pid_t(12345), panelId: livePanelId)
        workspace.recordAgentPID(key: "codex.codex-session-stale", pid: pid_t(12346), panelId: stalePanelId)

        let displayedKeys = Set(workspace.sidebarStatusEntriesInDisplayOrder().map(\.key))

        XCTAssertTrue(displayedKeys.contains("grok"))
        XCTAssertTrue(displayedKeys.contains("build"))
        XCTAssertFalse(displayedKeys.contains("codex"))
        XCTAssertFalse(displayedKeys.contains("amp"))
    }

    func testSidebarStatusShowsStructuredAgentRuntimeWithoutPanelBinding() throws {
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

        workspace.statusEntries["grok"] = SidebarStatusEntry(key: "grok", value: "Running")
        workspace.recordAgentPID(key: "grok.grok-session-unbound", pid: pid_t(12345), panelId: nil)

        let displayedKeys = Set(workspace.sidebarStatusEntriesInDisplayOrder().map(\.key))

        XCTAssertTrue(displayedKeys.contains("grok"))
    }

    func testNewStructuredAgentRuntimeOnPanelClearsPreviousAgentStatusForThatPanel() throws {
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

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let oldPIDKey = "claude_code.old-session"
        let newPIDKey = "grok.new-session"

        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input"
        )
        XCTAssertFalse(workspace.recordAgentPID(key: oldPIDKey, pid: pid_t(12345), panelId: panelId))
        XCTAssertTrue(workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "claude_code" })

        XCTAssertTrue(workspace.recordAgentPID(key: newPIDKey, pid: pid_t(12346), panelId: panelId))
        workspace.statusEntries["grok"] = SidebarStatusEntry(key: "grok", value: "Running")

        let displayedKeys = Set(workspace.sidebarStatusEntriesInDisplayOrder().map(\.key))
        XCTAssertFalse(displayedKeys.contains("claude_code"))
        XCTAssertTrue(displayedKeys.contains("grok"))
        XCTAssertNil(workspace.agentPIDs[oldPIDKey])
        XCTAssertNil(workspace.statusEntries["claude_code"])
        XCTAssertEqual(workspace.agentPIDs[newPIDKey].map(Int.init), 12346)
    }

    func testSidebarStatusShowsOnlyNewestStructuredAgentStatusPerPanel() throws {
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
        let secondPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal)
        )

        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Idle",
            timestamp: Date(timeIntervalSince1970: 10)
        )
        workspace.statusEntries["grok"] = SidebarStatusEntry(
            key: "grok",
            value: "Idle",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        workspace.statusEntries["amp"] = SidebarStatusEntry(
            key: "amp",
            value: "Running",
            timestamp: Date(timeIntervalSince1970: 15)
        )
        workspace.statusEntries["build"] = SidebarStatusEntry(
            key: "build",
            value: "Compiling",
            timestamp: Date(timeIntervalSince1970: 5)
        )

        let codexKey = "codex.codex-session-old"
        workspace.recordAgentPID(key: codexKey, pid: pid_t(12345), panelId: firstPanelId)
        workspace.recordAgentPID(key: "grok.grok-session-new", pid: pid_t(12346), panelId: firstPanelId)
        workspace.recordAgentPID(key: "amp.amp-session-split", pid: pid_t(12347), panelId: secondPanel.id)

        let displayedKeys = Set(workspace.sidebarStatusEntriesInDisplayOrder().map(\.key))

        XCTAssertTrue(displayedKeys.contains("grok"))
        XCTAssertTrue(displayedKeys.contains("amp"))
        XCTAssertTrue(displayedKeys.contains("build"))
        XCTAssertFalse(displayedKeys.contains("codex"))
        XCTAssertNil(workspace.statusEntries["codex"])
        XCTAssertNil(workspace.agentPIDs[codexKey])
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
