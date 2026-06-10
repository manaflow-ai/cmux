import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Session restore and autosave fingerprint of unread indicators
extension WorkspaceManualUnreadTests {
    func testSessionRestorePreservesNotificationUnreadIndicator() throws {
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: panelId,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])

        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredTabId = try XCTUnwrap(restored.surfaceIdFromPanelId(restoredPanelId))
        XCTAssertFalse(restored.manualUnreadPanelIds.contains(restoredPanelId))
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(store.hasManualUnread(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)

        restored.markPanelRead(restoredPanelId)

        XCTAssertFalse(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertFalse(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? true)
        XCTAssertFalse(store.hasManualUnread(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)
    }

    func testSessionRestorePreservesManualAndNotificationPanelUnreadIndependently() throws {
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.markPanelUnread(panelId)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: panelId,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        XCTAssertTrue(restored.manualUnreadPanelIds.contains(restoredPanelId))
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))

        restored.markPanelRead(restoredPanelId)

        XCTAssertFalse(restored.manualUnreadPanelIds.contains(restoredPanelId))
        XCTAssertFalse(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
    }

    func testSessionRestorePreservesFocusedReadIndicator() throws {
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredTabId = try XCTUnwrap(restored.surfaceIdFromPanelId(restoredPanelId))
        XCTAssertFalse(restored.manualUnreadPanelIds.contains(restoredPanelId))
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? false)
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)

        restored.markPanelRead(restoredPanelId)

        XCTAssertFalse(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertFalse(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? true)
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)
    }

    func testSessionRestorePreservesFocusedReadIndicatorWithReadNotificationsAsVisualOnly() throws {
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: panelId,
                title: "Read",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                isRead: true
            ),
        ])
        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(panelSnapshot.hasUnreadIndicator, true)
        XCTAssertEqual(panelSnapshot.restoredUnreadContributesToWorkspace, false)
        XCTAssertEqual(panelSnapshot.notifications?.count, 1)
        XCTAssertEqual(panelSnapshot.notifications?.first?.isRead, true)

        store.replaceNotificationsForTesting([])
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredTabId = try XCTUnwrap(restored.surfaceIdFromPanelId(restoredPanelId))
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)

        var legacySnapshot = snapshot
        let legacyPanelIndex = try XCTUnwrap(legacySnapshot.panels.firstIndex { $0.id == panelId })
        legacySnapshot.panels[legacyPanelIndex].restoredUnreadContributesToWorkspace = nil

        store.replaceNotificationsForTesting([])
        let legacyRestored = Workspace()
        legacyRestored.restoreSessionSnapshot(legacySnapshot)

        let legacyRestoredPanelId = try XCTUnwrap(legacyRestored.focusedPanelId)
        let legacyRestoredTabId = try XCTUnwrap(legacyRestored.surfaceIdFromPanelId(legacyRestoredPanelId))
        XCTAssertTrue(legacyRestored.hasRestoredUnreadIndicator(panelId: legacyRestoredPanelId))
        XCTAssertTrue(legacyRestored.bonsplitController.tab(legacyRestoredTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: legacyRestored.id))
        XCTAssertEqual(store.unreadCount(forTabId: legacyRestored.id), 0)
    }

    func testSessionRestorePreservesWorkspaceManualUnreadIndicator() throws {
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
        store.markUnread(forTabId: workspace.id)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let representativePanelId = try XCTUnwrap(restored.representativePanelIdForWorkspaceManualUnread())
        let representativeTabId = try XCTUnwrap(restored.surfaceIdFromPanelId(representativePanelId))
        XCTAssertTrue(store.hasManualUnread(forTabId: restored.id))
        XCTAssertTrue(restored.bonsplitController.tab(representativeTabId)?.showsNotificationBadge ?? false)
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)
    }

    func testSessionRestorePreservesWorkspaceNotificationUnreadIndicatorWithoutManualState() throws {
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
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: nil,
                title: "Workspace unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertFalse(store.hasManualUnread(forTabId: restored.id))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)

        store.markRead(forTabId: restored.id)

        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)
    }

    func testSessionRestorePreservesManualAndNotificationWorkspaceUnreadIndependently() throws {
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
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: nil,
                title: "Workspace unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])
        store.markUnread(forTabId: workspace.id)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertTrue(store.hasManualUnread(forTabId: restored.id))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)

        store.clearManualUnread(forTabId: restored.id)

        XCTAssertFalse(store.hasManualUnread(forTabId: restored.id))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)

        store.markRead(forTabId: restored.id)

        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)
    }

    func testSessionAutosaveFingerprintChangesWhenUnreadIndicatorsChange() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        func resetUnreadState() {
            store.replaceNotificationsForTesting([])
            store.clearFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)
            store.markRead(forTabId: workspace.id)
            workspace.clearManualUnread(panelId: panelId)
            workspace.clearRestoredUnreadIndicator(panelId: panelId)
        }

        resetUnreadState()
        let cleanFingerprint = manager.sessionAutosaveFingerprint()

        let notificationId = UUID()
        let notificationCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: notificationId,
                tabId: workspace.id,
                surfaceId: panelId,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: notificationCreatedAt,
                isRead: false
            ),
        ])
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())
        let notificationWithoutPanelIdFingerprint = manager.sessionAutosaveFingerprint()

        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: notificationId,
                tabId: workspace.id,
                surfaceId: panelId,
                panelId: panelId,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: notificationCreatedAt,
                isRead: false
            ),
        ])
        XCTAssertNotEqual(notificationWithoutPanelIdFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        store.markUnread(forTabId: workspace.id)
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        workspace.markPanelUnread(panelId)
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        workspace.restorePanelUnreadIndicator(panelId)
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        workspace.restorePanelUnreadIndicator(panelId, contributesToWorkspaceUnread: false)
        let visualOnlyRestoredFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(cleanFingerprint, visualOnlyRestoredFingerprint)
        workspace.restorePanelUnreadIndicator(panelId, contributesToWorkspaceUnread: true)
        XCTAssertNotEqual(visualOnlyRestoredFingerprint, manager.sessionAutosaveFingerprint())
    }

}
