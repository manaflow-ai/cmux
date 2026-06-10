import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Mark panel read and workspace read flows
extension WorkspaceManualUnreadTests {
    func testMarkPanelReadClearsPanelDerivedWorkspaceUnread() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.markPanelUnread(panelId)
        workspace.markPanelRead(panelId)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertTrue(store.canMarkWorkspaceUnread(forTabIds: [workspace.id]))
    }

    func testMarkPanelReadKeepsExplicitWorkspaceUnread() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.markPanelUnread(panelId)
        store.markUnread(forTabId: workspace.id)

        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertTrue(store.hasManualUnread(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)

        workspace.markPanelRead(panelId)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertTrue(store.hasManualUnread(forTabId: workspace.id))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
    }

    func testMarkWorkspaceReadClearsPanelDerivedWorkspaceUnreadDurably() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.markPanelUnread(panelId)
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))

        store.markRead(forTabId: workspace.id)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))

        workspace.pruneSurfaceMetadata(validSurfaceIds: Set(workspace.panels.keys))

        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
    }

    func testWorkspaceSurfaceMarkReadClearsPanelDerivedWorkspaceUnreadDurably() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.markPanelUnread(panelId)
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))

        store.markRead(forTabId: workspace.id, surfaceId: nil)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))

        workspace.pruneSurfaceMetadata(validSurfaceIds: Set(workspace.panels.keys))

        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
    }

    func testWorkspaceReadFlowsClearRepresentativeBadgeWhenPanelAndWorkspaceAreUnread() throws {
        try assertWorkspaceReadFlowClearsRepresentativeBadge { store, workspaceId in
            store.markRead(forTabId: workspaceId)
        }
        try assertWorkspaceReadFlowClearsRepresentativeBadge { store, _ in
            store.markAllRead()
        }
        try assertWorkspaceReadFlowClearsRepresentativeBadge { store, _ in
            store.clearAll(discardQueuedNotifications: false)
        }
    }

    func testWorkspaceReadFlowsClearNotificationBackedPanelBadges() throws {
        try assertWorkspaceReadFlowClearsNotificationBackedPanelBadge { store, workspaceId in
            store.markRead(forTabId: workspaceId)
        }
        try assertWorkspaceReadFlowClearsNotificationBackedPanelBadge { store, _ in
            store.markAllRead()
        }
    }

    private func assertWorkspaceReadFlowClearsRepresentativeBadge(
        _ action: (TerminalNotificationStore, UUID) -> Void,
        line: UInt = #line
    ) throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace, line: line)
        let panelId = try XCTUnwrap(workspace.focusedPanelId, line: line)
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panelId), line: line)

        workspace.markPanelUnread(panelId)
        store.markUnread(forTabId: workspace.id)

        XCTAssertTrue(workspace.bonsplitController.tab(tabId)?.showsNotificationBadge ?? false, line: line)

        action(store, workspace.id)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId), line: line)
        XCTAssertFalse(store.hasManualUnread(forTabId: workspace.id), line: line)
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id), line: line)
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id), line: line)
        XCTAssertFalse(workspace.bonsplitController.tab(tabId)?.showsNotificationBadge ?? true, line: line)
    }

    private func assertWorkspaceReadFlowClearsNotificationBackedPanelBadge(
        _ action: (TerminalNotificationStore, UUID) -> Void,
        line: UInt = #line
    ) throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace, line: line)
        let manualPanelId = try XCTUnwrap(workspace.focusedPanelId, line: line)
        let notificationPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: manualPanelId, orientation: .horizontal, focus: false),
            line: line
        )
        let manualTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(manualPanelId), line: line)
        let notificationTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(notificationPanel.id), line: line)

        workspace.markPanelUnread(manualPanelId)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: notificationPanel.id,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])
        workspace.bonsplitController.updateTab(notificationTabId, showsNotificationBadge: true)

        XCTAssertTrue(workspace.bonsplitController.tab(manualTabId)?.showsNotificationBadge ?? false, line: line)
        XCTAssertTrue(workspace.bonsplitController.tab(notificationTabId)?.showsNotificationBadge ?? false, line: line)

        action(store, workspace.id)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(manualPanelId), line: line)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: notificationPanel.id), line: line)
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id), line: line)
        XCTAssertFalse(workspace.bonsplitController.tab(manualTabId)?.showsNotificationBadge ?? true, line: line)
        XCTAssertFalse(workspace.bonsplitController.tab(notificationTabId)?.showsNotificationBadge ?? true, line: line)
    }

    func testMarkingOneUnreadPanelReadKeepsWorkspaceUnreadWhileAnotherPanelIsUnread() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanel = try XCTUnwrap(workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false))

        workspace.markPanelUnread(firstPanelId)
        workspace.markPanelUnread(secondPanel.id)

        workspace.markPanelRead(firstPanelId)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(firstPanelId))
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(secondPanel.id))
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
    }

}
