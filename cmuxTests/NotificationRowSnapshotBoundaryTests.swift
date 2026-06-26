import Foundation
import SwiftUI
import XCTest

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
final class NotificationRowSnapshotBoundaryTests: XCTestCase {

    // MARK: - Titlebar popover row

    func testPopoverRowEqualityIgnoresClosureIdentity() {
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

        XCTAssertEqual(
            left,
            right,
            "Popover rows with identical snapshots must compare equal even when the parent rebuilds closures; otherwise .equatable() cannot suppress body re-eval and the LazyVStack thrashes (issue #5794)."
        )
    }

    func testPopoverRowEqualityDetectsReadStateChange() {
        let unread = Self.makeNotification(isRead: false)
        let read = Self.makeNotification(id: unread.id, isRead: true)

        let left = NotificationPopoverRow(
            notification: unread, tabTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})
        let right = NotificationPopoverRow(
            notification: read, tabTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})

        XCTAssertNotEqual(
            left,
            right,
            "Toggling read state must change equality so the row repaints its unread indicator."
        )
    }

    func testPopoverRowEqualityDetectsTabTitleChange() {
        let notification = Self.makeNotification()
        let left = NotificationPopoverRow(
            notification: notification, tabTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})
        let right = NotificationPopoverRow(
            notification: notification, tabTitle: "feature", onOpen: {}, onClear: {}, onToggleRead: {})

        XCTAssertNotEqual(
            left,
            right,
            "A changed tab title must change equality so the row repaints its subtitle."
        )
    }

    // MARK: - Notifications page row

    func testPageRowEqualityIgnoresClosureAndBindingIdentity() {
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

        XCTAssertEqual(
            left,
            right,
            "Page rows with identical snapshots must compare equal even when the parent rebuilds closures (issue #5794)."
        )
    }

    func testPageRowEqualityDetectsFocusChange() {
        let notification = Self.makeNotification()
        let focus = FocusState<UUID?>()
        let unfocused = NotificationRow(
            notification: notification, tabTitle: "main", isFocused: false,
            onOpen: {}, onClear: {}, focusedNotificationId: focus.projectedValue)
        let focused = NotificationRow(
            notification: notification, tabTitle: "main", isFocused: true,
            onOpen: {}, onClear: {}, focusedNotificationId: focus.projectedValue)

        XCTAssertNotEqual(
            unfocused,
            focused,
            "Focus must participate in equality; otherwise .equatable() would leave the default-action keyboard shortcut on a stale row."
        )
    }

    func testPageRowEqualityDetectsNotificationChange() {
        let base = Self.makeNotification(isRead: false)
        let bumped = Self.makeNotification(id: base.id, isRead: true)
        let focus = FocusState<UUID?>()
        let left = NotificationRow(
            notification: base, tabTitle: "main", isFocused: false,
            onOpen: {}, onClear: {}, focusedNotificationId: focus.projectedValue)
        let right = NotificationRow(
            notification: bumped, tabTitle: "main", isFocused: false,
            onOpen: {}, onClear: {}, focusedNotificationId: focus.projectedValue)

        XCTAssertNotEqual(left, right, "A changed notification payload must change equality so the row repaints.")
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
