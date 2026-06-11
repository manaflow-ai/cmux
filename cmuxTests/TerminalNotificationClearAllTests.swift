import XCTest
import Bonsplit
import CMUXWorkstream
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
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        workspace.recordAgentPID(
            key: "claude_code.session-clear-command",
            pid: pid_t(12345),
            panelId: firstPanelId,
            refreshPorts: false
        )

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: firstPanelId,
            title: "Claude Code",
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
        XCTAssertEqual(workspace.statusEntries["claude_code"]?.value, "Idle")
        XCTAssertEqual(workspace.statusEntries["claude_code"]?.icon, "pause.circle.fill")
    }

    func testMarkingClaudeNeedsInputNotificationReadDemotesSidebarStatusToIdle() throws {
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

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        workspace.recordAgentPID(
            key: "claude_code.session-needs-input",
            pid: pid_t(12345),
            panelId: panelId,
            refreshPorts: false
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude needs your input"
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))

        store.markRead(forTabId: workspace.id, surfaceId: panelId)

        let status = try XCTUnwrap(workspace.statusEntries["claude_code"])
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(status.value, "Idle")
        XCTAssertEqual(status.icon, "pause.circle.fill")
        XCTAssertEqual(status.color, "#8E8E93")
        XCTAssertEqual(status.priority, 0)
    }

    func testAcknowledgingClaudeNeedsInputDemotesAgentLifecycleForHibernation() throws {
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

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        // Mirror the Claude hook ordering: per-panel lifecycle + sidebar status
        // both flip to needs-input before the notification is sent.
        workspace.recordAgentPID(
            key: "claude_code.session-needs-input",
            pid: pid_t(12345),
            panelId: panelId,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude needs your input"
        )

        XCTAssertEqual(
            workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil),
            .needsInput
        )

        store.markRead(forTabId: workspace.id, surfaceId: panelId)

        // The sidebar status demotes to Idle AND the per-panel lifecycle must
        // leave needsInput, otherwise agentHibernationLifecycleState keeps
        // returning .needsInput and hibernation stays blocked.
        XCTAssertEqual(workspace.statusEntries["claude_code"]?.value, "Idle")
        XCTAssertNotEqual(
            workspace.agentLifecycleStatesByPanelId[panelId]?["claude_code"],
            .needsInput
        )
        XCTAssertNotEqual(
            workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil),
            .needsInput
        )
    }

    func testAcknowledgingOnePanelDemotesItsLifecycleButKeepsBadgeForSiblingPanel() throws {
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
        // Two Claude panels in one workspace, both stuck on needs-input.
        for (panelId, suffix) in [(firstPanelId, "a"), (secondPanel.id, "b")] {
            workspace.recordAgentPID(
                key: "claude_code.session-\(suffix)",
                pid: pid_t(suffix == "a" ? 111 : 222),
                panelId: panelId,
                refreshPorts: false
            )
            workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
        }
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: firstPanelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "First panel needs input"
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: secondPanel.id,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Second panel needs input"
        )

        store.markRead(forTabId: workspace.id, surfaceId: firstPanelId)

        // Badge stays lit because the sibling panel still needs input...
        XCTAssertEqual(workspace.statusEntries["claude_code"]?.value, "Needs input")
        XCTAssertEqual(workspace.statusEntries["claude_code"]?.icon, "bell.fill")
        // ...but the acknowledged panel's lifecycle is demoted so it can hibernate.
        XCTAssertNotEqual(
            workspace.agentLifecycleStatesByPanelId[firstPanelId]?["claude_code"],
            .needsInput
        )
        XCTAssertEqual(
            workspace.agentLifecycleStatesByPanelId[secondPanel.id]?["claude_code"],
            .needsInput
        )
    }

    func testAcknowledgingStoreNotificationKeepsLifecycleWhileFeedPromptPendingOnSamePanel() throws {
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
        FeedCoordinatorTestHooks.attentionSurfaceObserver = nil

        let workspace = manager.addWorkspace(select: true)
        var feedTarget: FeedCoordinator.AttentionTarget? = nil
        defer {
            if let feedTarget {
                FeedCoordinator.shared.concludeBlockingDecisionAttention(feedTarget)
            }
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            FeedCoordinatorTestHooks.attentionSurfaceObserver = nil
        }

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.recordAgentPID(
            key: "claude_code.session-feed-vs-store",
            pid: pid_t(54321),
            panelId: panelId,
            refreshPorts: false
        )

        // A live feed-routed blocking decision on this panel (sets lifecycle
        // needsInput + sidebar status + pendingAttentionStates, no store notif).
        let event = WorkstreamEvent(
            sessionId: "claude-feed-vs-store",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: "feed-vs-store-request"
        )
        feedTarget = try XCTUnwrap(
            FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                event: event,
                resolved: (workspaceId: workspace.id, surfaceId: panelId)
            )
        )
        // A separate store notification arrives on the same panel/key.
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Needs input",
            structuredAgentStatusKey: "claude_code"
        )

        store.markRead(forTabId: workspace.id, surfaceId: panelId)

        // The store notification is acknowledged, but the feed prompt is still
        // outstanding on this panel, so neither the badge nor the per-panel
        // lifecycle may clear — the agent is still waiting for input.
        XCTAssertEqual(workspace.statusEntries["claude_code"]?.value, "Needs input")
        XCTAssertEqual(
            workspace.agentLifecycleStatesByPanelId[panelId]?["claude_code"],
            .needsInput
        )
    }

    func testRemovingClaudeNeedsInputNotificationDemotesSidebarStatusToIdle() throws {
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

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        workspace.recordAgentPID(
            key: "claude_code.session-remove",
            pid: pid_t(12345),
            panelId: panelId,
            refreshPorts: false
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude needs your input"
        )
        let notification = try XCTUnwrap(store.notifications.first)

        store.remove(id: notification.id)

        let status = try XCTUnwrap(workspace.statusEntries["claude_code"])
        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertEqual(status.value, "Idle")
        XCTAssertEqual(status.icon, "pause.circle.fill")
        XCTAssertEqual(status.color, "#8E8E93")
        XCTAssertEqual(status.priority, 0)
    }

    func testMarkingClaudeNotificationReadUsesPanelIdBeforeSurfaceId() throws {
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

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let nonPanelSurfaceId = UUID()
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        workspace.recordAgentPID(
            key: "claude_code.session-panel-precedence",
            pid: pid_t(12345),
            panelId: panelId,
            refreshPorts: false
        )
        let notification = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: nonPanelSurfaceId,
            panelId: panelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude needs your input",
            createdAt: Date(),
            isRead: false
        )
        store.replaceNotificationsForTesting([notification])

        store.markRead(id: notification.id)

        let status = try XCTUnwrap(workspace.statusEntries["claude_code"])
        XCTAssertEqual(status.value, "Idle")
        XCTAssertEqual(status.icon, "pause.circle.fill")
        XCTAssertEqual(status.color, "#8E8E93")
        XCTAssertEqual(status.priority, 0)
    }

    func testRemovingOneOfMultipleUnreadClaudeNotificationsKeepsNeedsInputStatus() throws {
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

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        workspace.recordAgentPID(
            key: "claude_code.session-multiple-unread",
            pid: pid_t(12345),
            panelId: panelId,
            refreshPorts: false
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "First unread prompt"
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Second unread prompt"
        )
        let firstNotification = try XCTUnwrap(
            store.notifications.first { $0.body == "First unread prompt" }
        )
        let secondNotification = try XCTUnwrap(
            store.notifications.first { $0.body == "Second unread prompt" }
        )

        store.remove(id: firstNotification.id)

        let status = try XCTUnwrap(workspace.statusEntries["claude_code"])
        XCTAssertEqual(store.notifications.count, 1)
        XCTAssertEqual(store.notifications.first?.id, secondNotification.id)
        XCTAssertFalse(store.notifications.first?.isRead ?? true)
        XCTAssertEqual(status.value, "Needs input")
        XCTAssertEqual(status.icon, "bell.fill")
        XCTAssertEqual(status.color, "#4C8DFF")
        XCTAssertEqual(status.priority, 100)
    }

    func testMarkingNonAgentNotificationReadDoesNotDemoteClaudeNeedsInputOnSamePanel() throws {
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

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        workspace.recordAgentPID(
            key: "claude_code.session-needs-input",
            pid: pid_t(12345),
            panelId: panelId,
            refreshPorts: false
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Build",
            subtitle: "Done",
            body: "A non-agent notification on the same panel"
        )

        store.markRead(forTabId: workspace.id, surfaceId: panelId)

        let status = try XCTUnwrap(workspace.statusEntries["claude_code"])
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(status.value, "Needs input")
        XCTAssertEqual(status.icon, "bell.fill")
        XCTAssertEqual(status.color, "#4C8DFF")
        XCTAssertEqual(status.priority, 100)
    }

    func testMarkingOlderClaudeNotificationReadDoesNotDemoteNewerNeedsInputStatus() throws {
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

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.recordAgentPID(
            key: "claude_code.session-needs-input",
            pid: pid_t(12345),
            panelId: panelId,
            refreshPorts: false
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Older prompt notification"
        )
        let notification = try XCTUnwrap(store.notifications.first)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100,
            timestamp: notification.createdAt.addingTimeInterval(1)
        )

        store.markRead(id: notification.id)

        let status = try XCTUnwrap(workspace.statusEntries["claude_code"])
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(status.value, "Needs input")
        XCTAssertEqual(status.icon, "bell.fill")
        XCTAssertEqual(status.color, "#4C8DFF")
        XCTAssertEqual(status.priority, 100)
    }

    func testMarkingSiblingPanelReadDoesNotDemoteClaudeNeedsInputForOtherPanel() throws {
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
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        workspace.recordAgentPID(
            key: "claude_code.session-needs-input",
            pid: pid_t(12345),
            panelId: secondPanel.id,
            refreshPorts: false
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: firstPanelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude notification on a sibling panel"
        )

        store.markRead(forTabId: workspace.id, surfaceId: firstPanelId)

        let status = try XCTUnwrap(workspace.statusEntries["claude_code"])
        XCTAssertEqual(status.value, "Needs input")
        XCTAssertEqual(status.icon, "bell.fill")
        XCTAssertEqual(status.color, "#4C8DFF")
        XCTAssertEqual(status.priority, 100)
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

    /// Regression for #2576: a Claude "Needs input" raised by a feed-routed
    /// blocking decision (PATH B — `FeedCoordinator.surfaceBlockingDecisionAttention`)
    /// sets the sidebar status + needsInput lifecycle WITHOUT creating a store
    /// notification. Focusing/interacting with the panel must still clear it,
    /// mirroring the notification-store acknowledgement path. Before the fix,
    /// `dismissNotification` bailed out early (no store notification to mark
    /// read) and the badge stayed stuck on "Needs input".
    func testFocusingWorkspaceClearsFeedRoutedNeedsInputAttention() throws {
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
        AppFocusState.overrideIsFocused = true
        FeedCoordinatorTestHooks.attentionSurfaceObserver = nil

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
            FeedCoordinatorTestHooks.attentionSurfaceObserver = nil
        }

        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        // Seed feed-routed needs-input exactly as a Claude PermissionRequest does.
        let event = WorkstreamEvent(
            sessionId: "claude-focus-clear-test",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: "focus-clear-request"
        )
        let target = try XCTUnwrap(
            FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                event: event,
                resolved: (workspaceId: workspace.id, surfaceId: panelId)
            )
        )

        XCTAssertEqual(workspace.statusEntries["claude_code"]?.value, "Needs input")
        XCTAssertEqual(workspace.statusEntries["claude_code"]?.icon, "bell.fill")
        XCTAssertEqual(
            workspace.agentLifecycleStatesByPanelId[panelId]?["claude_code"],
            .needsInput
        )

        // Clicking/interacting with the panel acknowledges the attention. This
        // returns false and leaves the badge stuck before the fix.
        let didDismiss = manager.dismissNotificationOnTerminalInteraction(
            tabId: workspace.id,
            surfaceId: panelId
        )

        XCTAssertTrue(didDismiss)
        XCTAssertNil(workspace.statusEntries["claude_code"])
        XCTAssertNotEqual(
            workspace.agentLifecycleStatesByPanelId[panelId]?["claude_code"],
            .needsInput
        )

        // Concluding the already-acknowledged decision must be a safe no-op.
        FeedCoordinator.shared.concludeBlockingDecisionAttention(target)
        XCTAssertNil(workspace.statusEntries["claude_code"])
    }
}
