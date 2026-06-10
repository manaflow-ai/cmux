import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Unread indicator visibility and representative panel tracking
extension WorkspaceManualUnreadTests {
    func testShouldShowUnreadIndicatorWhenNotificationIsUnread() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: true,
                hasPanelUnreadIndicator: false
            )
        )
    }

    func testShouldShowUnreadIndicatorWhenManualUnreadIsSet() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                hasPanelUnreadIndicator: true
            )
        )
    }

    func testShouldShowUnreadIndicatorWhenWorkspaceManualUnreadTargetsRepresentativePanel() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                hasPanelUnreadIndicator: false,
                isWorkspaceManuallyUnread: true,
                isWorkspaceManualUnreadRepresentative: true
            )
        )
    }

    func testShouldHideWorkspaceManualUnreadIndicatorOnNonRepresentativePanel() {
        XCTAssertFalse(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                hasPanelUnreadIndicator: false,
                isWorkspaceManuallyUnread: true,
                isWorkspaceManualUnreadRepresentative: false
            )
        )
    }

    func testShouldHideUnreadIndicatorWhenNeitherNotificationNorManualUnreadExists() {
        XCTAssertFalse(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                hasPanelUnreadIndicator: false
            )
        )
    }

    func testWorkspaceManualUnreadRepresentativeTracksFocusedPanel() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId,
              let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal, focus: false) else {
            XCTFail("Expected workspace with a split panel")
            return
        }

        XCTAssertEqual(workspace.representativePanelIdForWorkspaceManualUnread(), initialPanelId)

        workspace.focusPanel(splitPanel.id)

        XCTAssertEqual(workspace.representativePanelIdForWorkspaceManualUnread(), splitPanel.id)
    }

    func testWorkspaceManualUnreadBadgeMovesWhenFocusChanges() {
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
        guard let initialPanelId = workspace.focusedPanelId,
              let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal, focus: false),
              let initialTabId = workspace.surfaceIdFromPanelId(initialPanelId),
              let splitTabId = workspace.surfaceIdFromPanelId(splitPanel.id) else {
            XCTFail("Expected workspace with a split panel")
            return
        }

        store.markUnread(forTabId: workspace.id)
        workspace.focusPanel(initialPanelId)

        XCTAssertTrue(workspace.bonsplitController.tab(initialTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(workspace.bonsplitController.tab(splitTabId)?.showsNotificationBadge ?? true)

        workspace.focusPanel(splitPanel.id)

        XCTAssertFalse(workspace.bonsplitController.tab(initialTabId)?.showsNotificationBadge ?? true)
        XCTAssertTrue(workspace.bonsplitController.tab(splitTabId)?.showsNotificationBadge ?? false)
    }
}
