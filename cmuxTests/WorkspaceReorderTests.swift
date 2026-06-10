import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class WorkspaceReorderTests: XCTestCase {
    @MainActor
    func testReorderWorkspacePostsMovedWorkspaceId() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        _ = manager.addWorkspace()
        var observedMovedIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: .workspaceOrderDidChange,
            object: manager,
            queue: nil
        ) { notification in
            observedMovedIds = notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, toIndex: 0))

        XCTAssertEqual(observedMovedIds, [second.id])
    }

    @MainActor
    func testMoveTabsToTopPostsMovedWorkspaceIds() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        var observedMovedIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: .workspaceOrderDidChange,
            object: manager,
            queue: nil
        ) { notification in
            observedMovedIds = notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.moveTabsToTop([third.id, second.id])

        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(observedMovedIds, [second.id, third.id])
    }

    @MainActor
    func testMoveTabsToTopSkipsNotificationWhenOrderDoesNotChange() {
        let manager = TabManager()
        let first = manager.tabs[0]
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .workspaceOrderDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.moveTabsToTop([first.id])

        XCTAssertEqual(manager.tabs.map(\.id), [first.id])
        XCTAssertEqual(notificationCount, 0)
    }

    @MainActor
    func testMoveTabToTopPostsMovedWorkspaceIdWhenOrderChanges() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        var observedMovedIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: .workspaceOrderDidChange,
            object: manager,
            queue: nil
        ) { notification in
            observedMovedIds = notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.moveTabToTop(second.id)

        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id])
        XCTAssertEqual(observedMovedIds, [second.id])
    }

    @MainActor
    func testMoveTabToTopPublishesWorkspaceReorderedEvent() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        CmuxEventBus.shared.resetForTesting()

        manager.moveTabToTop(second.id)

        let event = try XCTUnwrap(CmuxEventBus.shared.retainedSnapshot().last)
        XCTAssertEqual(event["name"] as? String, "workspace.reordered")
        XCTAssertEqual(event["source"] as? String, "workspace.lifecycle")
        XCTAssertEqual(event["workspace_id"] as? String, second.id.uuidString)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(
            payload["workspace_ids"] as? [String],
            [second.id.uuidString, first.id.uuidString]
        )
        XCTAssertEqual(payload["moved_workspace_ids"] as? [String], [second.id.uuidString])
        XCTAssertEqual(payload["pinned_workspace_ids"] as? [String], [])
    }

    @MainActor
    func testSetPinnedPublishesWorkspaceReorderedEventWithPinnedState() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        CmuxEventBus.shared.resetForTesting()

        manager.setPinned(second, pinned: true)

        let event = try XCTUnwrap(CmuxEventBus.shared.retainedSnapshot().last)
        XCTAssertEqual(event["name"] as? String, "workspace.reordered")
        XCTAssertEqual(event["source"] as? String, "workspace.lifecycle")
        XCTAssertEqual(event["workspace_id"] as? String, second.id.uuidString)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(
            payload["workspace_ids"] as? [String],
            [second.id.uuidString, first.id.uuidString]
        )
        XCTAssertEqual(payload["moved_workspace_ids"] as? [String], [second.id.uuidString])
        XCTAssertEqual(payload["pinned_workspace_ids"] as? [String], [second.id.uuidString])
    }

    @MainActor
    func testMoveTabToTopSkipsNotificationWhenUnpinnedAlreadyFirstBelowPinnedWorkspaces() {
        let manager = TabManager()
        let pinned = manager.tabs[0]
        manager.setPinned(pinned, pinned: true)
        let firstUnpinned = manager.addWorkspace()
        _ = manager.addWorkspace()
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .workspaceOrderDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.moveTabToTop(firstUnpinned.id)

        XCTAssertEqual(manager.tabs.map(\.id).prefix(2), [pinned.id, firstUnpinned.id])
        XCTAssertEqual(notificationCount, 0)
    }

    @MainActor
    func testReorderWorkspaceMovesWorkspaceToRequestedIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(manager.selectedTabId, second.id)
    }

    @MainActor
    func testReorderWorkspaceClampsOutOfRangeTargetIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: first.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
    }

    @MainActor
    func testReorderWorkspaceReturnsFalseForUnknownWorkspace() {
        let manager = TabManager()
        XCTAssertFalse(manager.reorderWorkspace(tabId: UUID(), toIndex: 0))
    }

    @MainActor
    func testReorderWorkspaceKeepsUnpinnedWorkspaceBelowPinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: unpinned.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [firstPinned.id, secondPinned.id, unpinned.id])
    }

    @MainActor
    func testReorderWorkspaceKeepsPinnedWorkspaceInsidePinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: firstPinned.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [secondPinned.id, firstPinned.id, unpinned.id])
    }

    @MainActor
    func testBatchReorderAppliesFinalLeadingOrderAtomically() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        let fourth = manager.addWorkspace()
        var observedMovedIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: .workspaceOrderDidChange,
            object: manager,
            queue: nil
        ) { notification in
            observedMovedIds = notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let result = manager.reorderWorkspaces(orderedWorkspaceIds: [third.id, first.id])
        let plan = try result.get()

        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id, fourth.id])
        XCTAssertEqual(
            plan,
            [
                WorkspaceReorderPlanItem(workspaceId: third.id, fromIndex: 2, toIndex: 0),
                WorkspaceReorderPlanItem(workspaceId: first.id, fromIndex: 0, toIndex: 1)
            ]
        )
        XCTAssertEqual(observedMovedIds, [third.id, first.id])
    }

    @MainActor
    func testBatchReorderRejectsUnknownWorkspaceWithoutPartialMutation() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        let originalOrder = manager.tabs.map(\.id)
        let unknown = UUID()

        let result = manager.reorderWorkspaces(orderedWorkspaceIds: [third.id, unknown, first.id])

        XCTAssertEqual(result, .failure(.workspaceNotFound(unknown)))
        XCTAssertEqual(manager.tabs.map(\.id), originalOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id])
    }

    @MainActor
    func testBatchReorderDryRunReturnsPlanWithoutMutation() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        let originalOrder = manager.tabs.map(\.id)

        let result = manager.reorderWorkspaces(orderedWorkspaceIds: [third.id, first.id], dryRun: true)
        let plan = try result.get()

        XCTAssertEqual(manager.tabs.map(\.id), originalOrder)
        XCTAssertEqual(
            plan,
            [
                WorkspaceReorderPlanItem(workspaceId: third.id, fromIndex: 2, toIndex: 0),
                WorkspaceReorderPlanItem(workspaceId: first.id, fromIndex: 0, toIndex: 1)
            ]
        )
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id])
    }

    @MainActor
    func testBatchReorderPreservesPinnedWorkspaceSegment() throws {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let firstUnpinned = manager.addWorkspace()
        let secondUnpinned = manager.addWorkspace()

        let result = manager.reorderWorkspaces(orderedWorkspaceIds: [secondUnpinned.id, secondPinned.id])
        let plan = try result.get()

        XCTAssertEqual(
            manager.tabs.map(\.id),
            [secondPinned.id, firstPinned.id, secondUnpinned.id, firstUnpinned.id]
        )
        XCTAssertEqual(
            plan,
            [
                WorkspaceReorderPlanItem(workspaceId: secondUnpinned.id, fromIndex: 3, toIndex: 2),
                WorkspaceReorderPlanItem(workspaceId: secondPinned.id, fromIndex: 1, toIndex: 0)
            ]
        )
    }

    @MainActor
    func testDetachedWorkspaceInsertionOverrideClampsAfterPinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let source = manager.addWorkspace()
        manager.selectWorkspace(source)

        guard let panelId = source.focusedPanelId,
              let detached = source.detachSurface(panelId: panelId),
              let inserted = manager.addWorkspace(
                fromDetachedSurface: detached,
                insertionIndexOverride: 0
              ) else {
            XCTFail("Expected detached workspace insertion to succeed")
            return
        }

        XCTAssertEqual(manager.tabs.map(\.id), [firstPinned.id, secondPinned.id, inserted.id, source.id])
        XCTAssertFalse(inserted.isPinned)
    }
}

@MainActor
final class WorkspaceNotificationReorderTests: XCTestCase {
    func testNotificationAutoReorderDoesNotMovePinnedWorkspace() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let notificationStore = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let defaults = UserDefaults.standard
        let originalAutoReorderSetting = defaults.object(forKey: WorkspaceAutoReorderSettings.key)
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = notificationStore
        defaults.set(true, forKey: WorkspaceAutoReorderSettings.key)
        AppFocusState.overrideIsFocused = false

        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalAutoReorderSetting {
                defaults.set(originalAutoReorderSetting, forKey: WorkspaceAutoReorderSettings.key)
            } else {
                defaults.removeObject(forKey: WorkspaceAutoReorderSettings.key)
            }
        }

        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()
        let expectedOrder = [firstPinned.id, secondPinned.id, unpinned.id]

        notificationStore.addNotification(
            tabId: secondPinned.id,
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "Pinned workspaces should stay put"
        )

        XCTAssertEqual(manager.tabs.map(\.id), expectedOrder)
    }
}


