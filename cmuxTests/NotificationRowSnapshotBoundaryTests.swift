import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5794.
///
/// The notification surfaces (`NotificationsPage` and the titlebar
/// `NotificationPopoverRow` list) render
/// `ScrollView { LazyVStack { ForEach { ... } } }` over the notification
/// store. Before this fix the row views were not `Equatable` and the call
/// sites did not apply `.equatable()`, so every `TerminalNotificationStore`
/// publish (a new notification, a read/unread toggle, a clear) re-evaluated
/// the body of *every* row and re-laid out the whole lazy stack. With many
/// notifications accumulated and agents publishing continuously, that is the
/// same `AttributeGraph` relayout thrash documented for the sidebar/sessions
/// lists in `repo/CLAUDE.md` (issues #2586 / #5752).
///
/// The invariant that keeps the lazy layout cache stable: each row view must
/// be `Equatable`, and `==` must depend only on the value snapshot the row
/// renders — never on the closures/bindings the parent rebuilds every render.
/// If `==` returned false for two rows carrying the same payload, `.equatable()`
/// could not suppress body re-evaluation and the thrash returns.
@MainActor
@Suite("Notification row snapshot boundary", .serialized)
struct NotificationRowSnapshotBoundaryTests {

    // MARK: - Titlebar popover row

    @Test func popoverRowEqualityIgnoresClosureIdentity() {
        let notification = Self.makeNotification()
        let left = NotificationPopoverRow(
            notification: notification,
            tabTitle: "main",
            onOpen: {},
            onClear: {},
            onToggleRead: {}
        )
        // Distinct closures simulate the parent rebuilding the action bundle on
        // every store publish. Closure identity must be excluded from `==`.
        let right = NotificationPopoverRow(
            notification: notification,
            tabTitle: "main",
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
            notification: unread, tabTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})
        let right = NotificationPopoverRow(
            notification: read, tabTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})

        #expect(
            left != right,
            "Toggling read state must change equality so the row repaints its unread indicator."
        )
    }

    @Test func popoverRowEqualityDetectsTabTitleChange() {
        let notification = Self.makeNotification()
        let left = NotificationPopoverRow(
            notification: notification, tabTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})
        let right = NotificationPopoverRow(
            notification: notification, tabTitle: "feature", onOpen: {}, onClear: {}, onToggleRead: {})

        #expect(
            left != right,
            "A changed tab title must change equality so the row repaints its subtitle."
        )
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
            scrollPosition: TerminalNotificationScrollPosition(row: 42, totalRows: 100)
        )
        store.replaceNotificationsForTesting([notification])

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panelId })
        #expect(panelSnapshot.notifications?.first?.scrollPosition?.row == 42)
        #expect(panelSnapshot.notifications?.first?.scrollPosition?.totalRows == 100)

        store.replaceNotificationsForTesting([])
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredNotification = try #require(store.latestNotification(forTabId: restored.id))
        #expect(restoredNotification.scrollPosition?.row == 42)
        #expect(restoredNotification.scrollPosition?.totalRows == 100)
    }

    // MARK: - Fixtures

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
