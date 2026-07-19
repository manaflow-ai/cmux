import CmuxTerminal
import CmuxTerminalCore
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for notification list snapshots and activation.
/// Notification rows must compare immutable rendered values, never rebuilt
/// closure or binding identity, so lazy layout caches remain stable (#5794).
@MainActor
@Suite("Notification row snapshot boundary", .serialized)
struct NotificationRowSnapshotBoundaryTests {

    // MARK: - Titlebar popover row

    @Test func popoverRowEqualityIgnoresClosureIdentity() {
        let notification = Self.makeNotification()
        let left = NotificationPopoverRow(
            notification: notification,
            workspaceTitle: "main",
            onOpen: {},
            onClear: {},
            onToggleRead: {}
        )
        // Distinct closures simulate the parent rebuilding the action bundle on
        // every store publish. Closure identity must be excluded from `==`.
        let right = NotificationPopoverRow(
            notification: notification,
            workspaceTitle: "main",
            onOpen: { _ = 1 },
            onClear: { _ = 2 },
            onToggleRead: { _ = 3 }
        )

        #expect(
            left == right,
            "Popover rows with identical snapshots must compare equal even when the parent rebuilds closures; otherwise .equatable() cannot suppress body re-eval and the LazyVStack thrashes (issue #5794)."
        )
    }

    @Test func popoverRowEqualityDetectsReadStateChange() {
        let unread = Self.makeNotification(isRead: false)
        let read = Self.makeNotification(id: unread.id, isRead: true)

        let left = NotificationPopoverRow(
            notification: unread, workspaceTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})
        let right = NotificationPopoverRow(
            notification: read, workspaceTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})

        #expect(
            left != right,
            "Toggling read state must change equality so the row repaints its unread indicator."
        )
    }

    @Test func popoverRowEqualityDetectsWorkspaceTitleChange() {
        let notification = Self.makeNotification()
        let left = NotificationPopoverRow(
            notification: notification, workspaceTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})
        let right = NotificationPopoverRow(
            notification: notification, workspaceTitle: "feature", onOpen: {}, onClear: {}, onToggleRead: {})

        #expect(
            left != right,
            "A changed workspace title must change equality so the row repaints its headline."
        )
    }

    @Test func workspaceTitleIndexUsesRenamedGroupName() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let childId = try #require(manager.tabs.first?.id)
        let groupId = try #require(
            manager.createWorkspaceGroup(name: "Original Group", childWorkspaceIds: [childId])
        )
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let anchor = try #require(manager.tabs.first { $0.id == group.anchorWorkspaceId })
        let staleAnchorTitle = anchor.title

        let appDelegate = AppDelegate()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        manager.renameWorkspaceGroup(groupId: groupId, name: "Renamed Group")

        #expect(anchor.title == staleAnchorTitle)
        #expect(appDelegate.tabTitlesByTabId()[anchor.id] == "Renamed Group")
    }

    // MARK: - Notifications page row

    @Test func pageRowEqualityIgnoresClosureAndBindingIdentity() {
        let notification = Self.makeNotification()
        let focus = FocusState<UUID?>()
        let left = NotificationRow(
            notification: notification,
            tabTitle: "main",
            isFocused: false,
            onOpen: {},
            onClear: {},
            focusedNotificationId: focus.projectedValue
        )
        let right = NotificationRow(
            notification: notification,
            tabTitle: "main",
            isFocused: false,
            onOpen: { _ = 1 },
            onClear: { _ = 2 },
            focusedNotificationId: focus.projectedValue
        )

        #expect(
            left == right,
            "Page rows with identical snapshots must compare equal even when the parent rebuilds closures (issue #5794)."
        )
    }

    @Test func pageRowEqualityDetectsFocusChange() {
        let notification = Self.makeNotification()
        let focus = FocusState<UUID?>()
        let unfocused = NotificationRow(
            notification: notification, tabTitle: "main", isFocused: false,
            onOpen: {}, onClear: {}, focusedNotificationId: focus.projectedValue)
        let focused = NotificationRow(
            notification: notification, tabTitle: "main", isFocused: true,
            onOpen: {}, onClear: {}, focusedNotificationId: focus.projectedValue)

        #expect(
            unfocused != focused,
            "Focus must participate in equality; otherwise .equatable() would leave the default-action keyboard shortcut on a stale row."
        )
    }

    @Test func pageRowEqualityDetectsNotificationChange() {
        let base = Self.makeNotification(isRead: false)
        let bumped = Self.makeNotification(id: base.id, isRead: true)
        let focus = FocusState<UUID?>()
        let left = NotificationRow(
            notification: base, tabTitle: "main", isFocused: false,
            onOpen: {}, onClear: {}, focusedNotificationId: focus.projectedValue)
        let right = NotificationRow(
            notification: bumped, tabTitle: "main", isFocused: false,
            onOpen: {}, onClear: {}, focusedNotificationId: focus.projectedValue)

        #expect(left != right, "A changed notification payload must change equality so the row repaints.")
    }

    @Test func workspaceNotificationMenuProjectionFiltersAndSortsNewestFirst() {
        let tabA = UUID()
        let tabB = UUID()
        let unrelatedTab = UUID()
        let older = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: nil,
            title: "Older",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 100),
            isRead: true
        )
        let latest = TerminalNotification(
            id: UUID(),
            tabId: tabB,
            surfaceId: nil,
            title: "Latest",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 300),
            isRead: false
        )
        let middle = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: nil,
            title: "Middle",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 200),
            isRead: false
        )
        let unrelated = TerminalNotification(
            id: UUID(),
            tabId: unrelatedTab,
            surfaceId: nil,
            title: "Unrelated",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 400),
            isRead: false
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([older, unrelated, latest, middle])
        defer { store.replaceNotificationsForTesting([]) }

        #expect(store.notifications(forTabIds: [tabA, tabB]).map(\.id) == [latest.id, middle.id, older.id])
    }

    @Test func workspaceNotificationMenuProjectionCapsNewestItems() {
        let tab = UUID()
        let notifications = (0 ..< 60).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: tab,
                surfaceId: nil,
                title: "\(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting(notifications)
        defer { store.replaceNotificationsForTesting([]) }

        let menuItems = store.notifications(forTabIds: [tab])

        #expect(menuItems.count == 50)
        #expect(menuItems.first?.title == "59")
        #expect(menuItems.last?.title == "10")
    }

    @Test func sessionSnapshotPreservesNotificationScrollPosition() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalNotificationStore = appDelegate.notificationStore
        appDelegate.notificationStore = store
        store.replaceNotificationsForTesting([])
        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let liveSurfaceId = UUID()
        let notification = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: liveSurfaceId,
            panelId: panelId,
            title: "Agent finished",
            subtitle: "codex",
            body: "Tests passed",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRead: false,
            paneFlash: true,
            scrollPosition: TerminalNotificationScrollPosition(
                row: 42,
                totalRows: 100,
                rowSpaceRevision: 99
            )
        )
        store.replaceNotificationsForTesting([notification])

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panelId })
        #expect(panelSnapshot.notifications?.first?.scrollPosition?.row == 42)
        #expect(panelSnapshot.notifications?.first?.scrollPosition?.totalRows == 100)
        #expect(panelSnapshot.notifications?.first?.scrollPosition?.rowSpaceRevision == nil)

        store.replaceNotificationsForTesting([])
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredNotification = try #require(store.latestNotification(forTabId: restored.id))
        #expect(restoredNotification.scrollPosition?.row == 42)
        #expect(restoredNotification.scrollPosition?.totalRows == 100)
        #expect(restoredNotification.scrollPosition?.rowSpaceRevision == nil)
    }

    @Test func openingNotificationCapturedAtBottomRestoresLiveViewport() {
        let surfaceView = NotificationScrollRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = notificationScrollbar(total: 400, offset: 356, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let didRestore = hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 0, totalRows: 400)
        )
        #expect(didRestore)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:356"])
    }

    @Test func openingNotificationWithoutScrollbackKeepsLiveViewportActive() {
        let surfaceView = NotificationScrollRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = notificationScrollbar(total: 44, offset: 0, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let didRestore = hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 0, totalRows: 44)
        )
        #expect(didRestore)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:0"])
    }

    @Test func openingNotificationBeforeViewportLayoutRestoresOnScrollbarUpdate() {
        let surfaceView = NotificationScrollRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = notificationScrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let didRestoreImmediately = hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 0, totalRows: 400)
        )
        #expect(!didRestoreImmediately)
        #expect(surfaceView.performedBindingActions.isEmpty)
        let readyScrollbar = notificationScrollbar(total: 400, offset: 356, len: 44)
        postScrollbar(readyScrollbar, to: surfaceView)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:356"])
        postScrollbar(readyScrollbar, to: surfaceView)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:356"])
    }

    @Test func openingNotificationRetriesAfterBindingActionIsRejected() {
        let surfaceView = NotificationScrollRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = notificationScrollbar(total: 400, offset: 356, len: 44)
        surfaceView.bindingActionResults = [false, true]
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let didRestoreImmediately = hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 0, totalRows: 400)
        )
        #expect(!didRestoreImmediately)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:356"])
        let readyScrollbar = notificationScrollbar(total: 400, offset: 356, len: 44)
        postScrollbar(readyScrollbar, to: surfaceView)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:356", "scroll_to_row:356"])
        postScrollbar(readyScrollbar, to: surfaceView)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:356", "scroll_to_row:356"])
    }

    @Test func openingNotificationBoundsRejectedBindingActionRetries() {
        let surfaceView = NotificationScrollRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = notificationScrollbar(total: 400, offset: 356, len: 44)
        surfaceView.bindingActionResults = [false, false, false]
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let position = TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        #expect(!hostedView.restoreNotificationScrollPosition(position))
        #expect(!hostedView.userScrolledAwayFromBottom)
        #expect(!hostedView.allowExplicitScrollbarSync)

        let readyScrollbar = notificationScrollbar(total: 400, offset: 356, len: 44)
        for _ in 0 ..< 3 {
            postScrollbar(readyScrollbar, to: surfaceView)
        }

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256", "scroll_to_row:256"])
        #expect(!hostedView.userScrolledAwayFromBottom)
        #expect(!hostedView.allowExplicitScrollbarSync)
    }

    @Test(arguments: [Notification.Name.ghosttyDidReceiveWheelScroll, NSScrollView.didLiveScrollNotification])
    func userScrollCancelsRejectedNotificationRestore(inputName: Notification.Name) throws {
        let surfaceView = NotificationScrollRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = notificationScrollbar(total: 400, offset: 356, len: 44)
        surfaceView.bindingActionResults = [false, true]
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let position = TerminalNotificationScrollPosition(row: 0, totalRows: 400)

        #expect(!hostedView.restoreNotificationScrollPosition(position))
        let scrollView = try #require(
            hostedView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView
        )
        let inputObject: Any = inputName == .ghosttyDidReceiveWheelScroll ? surfaceView : scrollView
        NotificationCenter.default.post(name: inputName, object: inputObject)
        postScrollbar(notificationScrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:356"])
    }

    @Test func keyboardInputCancelsPendingNotificationRestore() throws {
        let terminal = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        defer { terminal.releaseSurfaceForTesting() }
        let hostedView = terminal.hostedView
        hostedView.notificationScrollRestoreState = NotificationScrollRestoreState(
            replay: .replaying(expectedEndBoundary: "test-replay-boundary"),
            request: .waitingForReplay(
                position: .init(row: 0, totalRows: 400),
                attemptsRemaining: 2
            )
        )
        #expect(hostedView.hasPendingNotificationScrollRestore)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 1, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 116
        ))
        hostedView.surfaceView.keyDown(with: event)
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func menuPasteCancelsPendingNotificationRestore() {
        let terminal = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        defer { terminal.releaseSurfaceForTesting() }
        let hostedView = terminal.hostedView
        hostedView.notificationScrollRestoreState = NotificationScrollRestoreState(
            replay: .replaying(expectedEndBoundary: "test-replay-boundary"),
            request: .waitingForReplay(
                position: .init(row: 0, totalRows: 400),
                attemptsRemaining: 2
            )
        )
        #expect(hostedView.hasPendingNotificationScrollRestore)

        hostedView.surfaceView.paste(nil)

        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func newerAnchorlessActivationCancelsPendingRestore() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        panel.hostedView.notificationScrollRestoreState = NotificationScrollRestoreState(
            replay: .replaying(expectedEndBoundary: "test-replay-boundary"),
            request: .waitingForReplay(
                position: .init(row: 12, totalRows: 400),
                attemptsRemaining: 2
            )
        )
        #expect(panel.hostedView.hasPendingNotificationScrollRestore)

        (AppDelegate.shared ?? AppDelegate()).restoreNotificationScrollPosition(
            nil, tabId: workspace.id, surfaceId: nil,
            panelId: panelId, workspace: workspace
        )

        #expect(!panel.hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func openingLegacyNotificationPreservesBottomRelativeViewport() {
        let surfaceView = NotificationScrollRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = notificationScrollbar(total: 400, offset: 356, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        let didRestore = hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 12, totalRows: nil)
        )

        #expect(didRestore)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:344"])
    }

    // MARK: - Fixtures

    private func notificationScrollbar(total: UInt64, offset: UInt64, len: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(c: ghostty_action_scrollbar_s(total: total, offset: offset, len: len))
    }

    private func postScrollbar(_ scrollbar: GhosttyScrollbar, to surfaceView: GhosttyNSView) {
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar, object: surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
        )
    }

    private static func makeNotification(
        id: UUID = UUID(),
        isRead: Bool = false
    ) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: UUID(),
            surfaceId: nil,
            title: "Agent finished",
            subtitle: "",
            body: "Build succeeded",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRead: isRead
        )
    }
}
