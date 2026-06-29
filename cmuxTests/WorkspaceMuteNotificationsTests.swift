import XCTest
import AppKit
import Combine
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceMuteNotificationsTests: XCTestCase {
    override func tearDown() {
        let store = TerminalNotificationStore.shared
        store.resetNotificationDeliveryHandlerForTesting()
        store.resetSuppressedNotificationFeedbackHandlerForTesting()
        store.replaceNotificationsForTesting([])
        super.tearDown()
    }

    /// Muting a workspace must clamp every alerting effect at the single delivery
    /// seam: no desktop banner / suppressed-feedback handler runs, no unread is
    /// created (so the Dock badge stays dark), and no pane flash is requested —
    /// yet the notification is still recorded (as already read) so it remains in
    /// history. Unmuting restores normal delivery and unread.
    func testMutedWorkspaceSuppressesDeliveryAndUnreadButStillRecords() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        // Force "app not focused" so external delivery is NOT suppressed by focus:
        // this isolates the mute behavior from the focus-based suppression path.
        AppFocusState.overrideIsFocused = false

        var deliveryCount = 0
        var suppressedCount = 0
        store.configureNotificationDeliveryHandlerForTesting { _, _ in deliveryCount += 1 }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in suppressedCount += 1 }

        defer {
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected a selected workspace")
            return
        }

        // Muted: notification is recorded as read, nothing alerts.
        workspace.notificationsMuted = true
        store.addNotification(
            tabId: workspace.id,
            surfaceId: nil,
            title: "Paperclip",
            subtitle: "",
            body: "success"
        )

        XCTAssertEqual(deliveryCount, 0, "Muted workspace must not deliver a desktop notification")
        XCTAssertEqual(suppressedCount, 0, "Muted workspace must not even run suppressed feedback")
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 0, "Muted notification must not create unread")
        XCTAssertFalse(store.hasUnreadNotificationRequiringPaneFlash(forTabId: workspace.id, surfaceId: nil))
        let recorded = store.notifications(forTabId: workspace.id, surfaceId: nil)
        XCTAssertEqual(recorded.count, 1, "Muted notification should still be recorded in history")
        XCTAssertEqual(recorded.first?.isRead, true, "Recorded muted notification should be read")

        // Unmuted: delivery and unread resume.
        workspace.notificationsMuted = false
        store.addNotification(
            tabId: workspace.id,
            surfaceId: nil,
            title: "Paperclip",
            subtitle: "",
            body: "success"
        )

        XCTAssertEqual(deliveryCount, 1, "Unmuted workspace must deliver the desktop notification")
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1, "Unmuted notification must create unread")
        XCTAssertTrue(store.hasUnreadNotificationRequiringPaneFlash(forTabId: workspace.id, surfaceId: nil))
    }

    /// The muted flag round-trips through the session manifest so a muted
    /// workspace stays muted across an app restart.
    func testNotificationsMutedPersistsAcrossSessionSnapshotRoundTrip() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        let source = Workspace()
        source.notificationsMuted = true

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.notificationsMuted, true)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertTrue(restored.notificationsMuted)
    }

    /// An unmuted workspace must serialize as not muted and restore as not muted,
    /// and legacy manifests without the field must decode as not muted.
    func testNotificationsUnmutedRoundTripsAndLegacyDefaultsToFalse() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        let source = Workspace()
        XCTAssertFalse(source.notificationsMuted)

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertFalse(restored.notificationsMuted)

        // Legacy manifest: field absent (nil) restores as not muted.
        snapshot.notificationsMuted = nil
        let legacyRestored = Workspace()
        legacyRestored.restoreSessionSnapshot(snapshot)
        XCTAssertFalse(legacyRestored.notificationsMuted)
    }

    /// Agent permission/plan/question banners are delivered through
    /// `FeedCoordinator`, not `TerminalNotificationStore.applyNotification`, so
    /// they must honor the same per-workspace mute. `muteClampedEffects` is the
    /// shared seam that gates that path.
    func testFeedNotificationEffectsAreClampedForMutedWorkspace() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        appDelegate.tabManager = manager
        defer { appDelegate.tabManager = originalTabManager }

        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected a selected workspace")
            return
        }

        func event(for workspaceId: String?) -> WorkstreamEvent {
            WorkstreamEvent(
                sessionId: "claude-mute-test",
                hookEventName: .permissionRequest,
                source: "claude",
                workspaceId: workspaceId,
                requestId: "mute-test-request"
            )
        }

        let alerting = TerminalNotificationPolicyEffects()
        XCTAssertTrue(alerting.desktop && alerting.sound && alerting.command, "precondition: default effects alert")

        // Muted workspace → all alerting effects cleared.
        workspace.notificationsMuted = true
        let mutedEffects = FeedCoordinator.muteClampedEffects(alerting, for: event(for: workspace.id.uuidString))
        XCTAssertFalse(mutedEffects.desktop)
        XCTAssertFalse(mutedEffects.sound)
        XCTAssertFalse(mutedEffects.command)

        // Unmuted workspace → effects pass through unchanged.
        workspace.notificationsMuted = false
        let unmutedEffects = FeedCoordinator.muteClampedEffects(alerting, for: event(for: workspace.id.uuidString))
        XCTAssertTrue(unmutedEffects.desktop)
        XCTAssertTrue(unmutedEffects.sound)
        XCTAssertTrue(unmutedEffects.command)

        // No resolvable workspace id → effects unchanged even while muted.
        workspace.notificationsMuted = true
        let unresolvedEffects = FeedCoordinator.muteClampedEffects(alerting, for: event(for: nil))
        XCTAssertTrue(unresolvedEffects.desktop)
    }

    /// The mute mutation must go through TabManager and fire `objectWillChange`,
    /// otherwise the sidebar (which observes TabManager, not each Workspace) never
    /// re-renders and the Mute/Unmute label + glyph stay stale until an unrelated
    /// refresh (the focused-workspace bug).
    func testTabManagerSetNotificationsMutedTogglesWorkspaceAndNotifiesSidebar() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected a selected workspace")
            return
        }
        XCTAssertFalse(workspace.notificationsMuted)

        var willChangeCount = 0
        let cancellable = manager.objectWillChange.sink { _ in willChangeCount += 1 }
        defer { cancellable.cancel() }

        manager.setNotificationsMuted(true, forWorkspaceIds: [workspace.id])
        XCTAssertTrue(workspace.notificationsMuted, "mute should set the flag")
        XCTAssertGreaterThan(willChangeCount, 0, "a mute change must fire objectWillChange so the sidebar re-renders")

        manager.setNotificationsMuted(false, forWorkspaceIds: [workspace.id])
        XCTAssertFalse(workspace.notificationsMuted, "unmute should clear the flag")
    }
}
