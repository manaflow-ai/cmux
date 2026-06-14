import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationSocketActionTests: TerminalNotificationSocketTestCase {
    func testNotificationDismissRemovesSingleNotification() async throws {
        let fixture = try makeSocketFixture(name: "notif-dismiss")
        defer { fixture.cleanup() }

        let target = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Dismiss")
        let sibling = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Keep")
        fixture.store.replaceNotificationsForTesting([target, sibling])

        let response = try await sendV2RequestAsync(
            method: "notification.dismiss",
            params: ["id": target.id.uuidString],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["dismissed"] as? Int, 1)
        XCTAssertFalse(fixture.store.notifications.contains(where: { $0.id == target.id }))
        XCTAssertTrue(fixture.store.notifications.contains(where: { $0.id == sibling.id }))
    }

    func testNotificationDismissAllReadRemovesOnlyReadNotifications() async throws {
        let fixture = try makeSocketFixture(name: "notif-dismiss-read")
        defer { fixture.cleanup() }

        let firstRead = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Read 1", isRead: true)
        let secondRead = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Read 2", isRead: true)
        let unread = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Unread")
        fixture.store.replaceNotificationsForTesting([firstRead, secondRead, unread])

        let response = try await sendV2RequestAsync(
            method: "notification.dismiss",
            params: ["all_read": true],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["dismissed"] as? Int, 2)
        XCTAssertEqual(result["all_read"] as? Bool, true)
        XCTAssertFalse(fixture.store.notifications.contains(where: { $0.id == firstRead.id }))
        XCTAssertFalse(fixture.store.notifications.contains(where: { $0.id == secondRead.id }))
        XCTAssertTrue(fixture.store.notifications.contains(where: { $0.id == unread.id }))
    }

    func testNotificationMarkReadSupportsIdTabSurfaceAndAllSelectors() async throws {
        let fixture = try makeSocketFixture(name: "notif-read")
        defer { fixture.cleanup() }

        let idTarget = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "By ID")
        let surfaceTarget = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "By Surface")
        let otherSurface = UUID()
        let surfaceSibling = makeNotification(tabId: fixture.workspace.id, surfaceId: otherSurface, title: "Other Surface")
        let allTarget = makeNotification(tabId: UUID(), surfaceId: nil, title: "All")
        fixture.store.replaceNotificationsForTesting([idTarget, surfaceTarget, surfaceSibling, allTarget])

        var response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: ["id": idTarget.id.uuidString],
            to: fixture.socketPath
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertEqual(fixture.notification(idTarget.id)?.isRead, true)
        XCTAssertEqual(fixture.notification(surfaceTarget.id)?.isRead, false)

        response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: [
                "tab_id": fixture.workspace.id.uuidString,
                "surface_id": fixture.surfaceId.uuidString,
            ],
            to: fixture.socketPath
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertEqual(fixture.notification(surfaceTarget.id)?.isRead, true)
        XCTAssertEqual(fixture.notification(surfaceSibling.id)?.isRead, false)

        response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: ["all": true],
            to: fixture.socketPath
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertTrue(fixture.store.notifications.allSatisfy(\.isRead))

        response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: [
                "id": idTarget.id.uuidString,
                "surface_id": fixture.surfaceId.uuidString,
            ],
            to: fixture.socketPath
        )
        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
    }

    func testNotificationMarkReadRejectsUnknownId() async throws {
        let fixture = try makeSocketFixture(name: "notif-read-missing")
        defer { fixture.cleanup() }

        let missingId = UUID()
        let response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: ["id": missingId.uuidString],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "not_found")
        XCTAssertEqual(error["message"] as? String, "Notification not found")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["id"] as? String, missingId.uuidString)
    }

    func testNotificationOpenFocusesDestinationAndMarksRead() async throws {
        let fixture = try makeSocketFixture(name: "notif-open", includeWindow: true)
        defer { fixture.cleanup() }

        let targetWorkspace = fixture.manager.addWorkspace(title: "Open Target", select: false)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)
        let notification = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Open")
        fixture.store.replaceNotificationsForTesting([notification])
        fixture.manager.selectTab(fixture.workspace)

        let response = try await sendV2RequestAsync(
            method: "notification.open",
            params: ["id": notification.id.uuidString],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["opened"] as? Bool, true)
        XCTAssertEqual(result["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, targetSurfaceId.uuidString)
        XCTAssertEqual(result["is_read"] as? Bool, true)
        XCTAssertEqual(fixture.manager.selectedTabId, targetWorkspace.id)
        XCTAssertEqual(fixture.manager.focusedSurfaceId(for: targetWorkspace.id), targetSurfaceId)
        XCTAssertEqual(fixture.notification(notification.id)?.isRead, true)
    }

    func testNotificationJumpToUnreadOpensLatestUnreadAndNoOpsWhenNoneRemain() async throws {
        let fixture = try makeSocketFixture(name: "notif-jump", includeWindow: true)
        defer { fixture.cleanup() }

        let targetWorkspace = fixture.manager.addWorkspace(title: "Unread Target", select: false)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)
        let older = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Older")
        let latest = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Latest")
        fixture.store.replaceNotificationsForTesting([latest, older])
        fixture.manager.selectTab(fixture.workspace)

        var response = try await sendV2RequestAsync(
            method: "notification.jump_to_unread",
            params: [:],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        var result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["opened"] as? Bool, true)
        XCTAssertEqual(result["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, targetSurfaceId.uuidString)
        XCTAssertEqual(result["is_read"] as? Bool, true)
        XCTAssertEqual(fixture.manager.selectedTabId, targetWorkspace.id)
        XCTAssertEqual(fixture.manager.focusedSurfaceId(for: targetWorkspace.id), targetSurfaceId)
        XCTAssertEqual(fixture.notification(latest.id)?.isRead, true)

        fixture.store.markAllRead()
        let selectedBeforeNoop = fixture.manager.selectedTabId
        let focusedBeforeNoop = fixture.manager.focusedSurfaceId(for: targetWorkspace.id)

        response = try await sendV2RequestAsync(
            method: "notification.jump_to_unread",
            params: [:],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["opened"] as? Bool, false)
        XCTAssertEqual(fixture.manager.selectedTabId, selectedBeforeNoop)
        XCTAssertEqual(fixture.manager.focusedSurfaceId(for: targetWorkspace.id), focusedBeforeNoop)
    }

    func testNotificationJumpToUnreadPayloadMatchesOpenedFallbackNotification() async throws {
        let fixture = try makeSocketFixture(name: "notif-jump-skip", includeWindow: true)
        defer { fixture.cleanup() }

        let targetWorkspace = fixture.manager.addWorkspace(title: "Unread Fallback", select: false)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)
        let unopenable = makeNotification(tabId: UUID(), surfaceId: nil, title: "Closed Workspace")
        let openable = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Openable")
        fixture.store.replaceNotificationsForTesting([unopenable, openable])
        fixture.manager.selectTab(fixture.workspace)

        let response = try await sendV2RequestAsync(
            method: "notification.jump_to_unread",
            params: [:],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["opened"] as? Bool, true)
        XCTAssertEqual(result["id"] as? String, openable.id.uuidString)
        XCTAssertEqual(result["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, targetSurfaceId.uuidString)
        XCTAssertEqual(fixture.manager.selectedTabId, targetWorkspace.id)
        XCTAssertEqual(fixture.notification(openable.id)?.isRead, true)
    }

}
