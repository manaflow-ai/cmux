import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalNotificationSocketActionTests {
    private let socketTestSupport = TerminalNotificationSocketTestCase()

    @Test
    func notificationDismissRemovesSingleNotification() async throws {
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

        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["dismissed"] as? Int == 1)
        #expect(!fixture.store.notifications.contains(where: { $0.id == target.id }))
        #expect(fixture.store.notifications.contains(where: { $0.id == sibling.id }))
    }

    @Test
    func notificationDismissAllReadRemovesOnlyReadNotifications() async throws {
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

        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["dismissed"] as? Int == 2)
        #expect(result["all_read"] as? Bool == true)
        #expect(!fixture.store.notifications.contains(where: { $0.id == firstRead.id }))
        #expect(!fixture.store.notifications.contains(where: { $0.id == secondRead.id }))
        #expect(fixture.store.notifications.contains(where: { $0.id == unread.id }))
    }

    @Test
    func notificationMarkReadSupportsIdTabSurfaceAndAllSelectors() async throws {
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
        #expect(response["ok"] as? Bool == true)
        #expect(fixture.notification(idTarget.id)?.isRead == true)
        #expect(fixture.notification(surfaceTarget.id)?.isRead == false)

        response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: [
                "tab_id": fixture.workspace.id.uuidString,
                "surface_id": fixture.surfaceId.uuidString,
            ],
            to: fixture.socketPath
        )
        #expect(response["ok"] as? Bool == true)
        #expect(fixture.notification(surfaceTarget.id)?.isRead == true)
        #expect(fixture.notification(surfaceSibling.id)?.isRead == false)

        response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: ["all": true],
            to: fixture.socketPath
        )
        #expect(response["ok"] as? Bool == true)
        #expect(fixture.store.notifications.allSatisfy(\.isRead))

        response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: [
                "id": idTarget.id.uuidString,
                "surface_id": fixture.surfaceId.uuidString,
            ],
            to: fixture.socketPath
        )
        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
    }

    @Test
    func notificationMarkReadRejectsUnknownId() async throws {
        let fixture = try makeSocketFixture(name: "notif-read-missing")
        defer { fixture.cleanup() }

        let missingId = UUID()
        let response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: ["id": missingId.uuidString],
            to: fixture.socketPath
        )

        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? String == "not_found")
        #expect(error["message"] as? String == "Notification not found")
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["id"] as? String == missingId.uuidString)
    }

    @Test
    func notificationOpenFocusesDestinationAndMarksRead() async throws {
        let fixture = try makeSocketFixture(name: "notif-open", includeWindow: true)
        defer { fixture.cleanup() }

        let targetWorkspace = fixture.manager.addWorkspace(title: "Open Target", select: false)
        let targetSurfaceId = try #require(targetWorkspace.focusedPanelId)
        let notification = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Open")
        fixture.store.replaceNotificationsForTesting([notification])
        fixture.manager.selectTab(fixture.workspace)

        let response = try await sendV2RequestAsync(
            method: "notification.open",
            params: ["id": notification.id.uuidString],
            to: fixture.socketPath
        )

        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["opened"] as? Bool == true)
        #expect(result["workspace_id"] as? String == targetWorkspace.id.uuidString)
        #expect(result["surface_id"] as? String == targetSurfaceId.uuidString)
        #expect(result["is_read"] as? Bool == true)
        #expect(fixture.manager.selectedTabId == targetWorkspace.id)
        #expect(fixture.manager.focusedSurfaceId(for: targetWorkspace.id) == targetSurfaceId)
        #expect(fixture.notification(notification.id)?.isRead == true)
    }

    @Test
    func notificationJumpToUnreadOpensLatestUnreadAndNoOpsWhenNoneRemain() async throws {
        let fixture = try makeSocketFixture(name: "notif-jump", includeWindow: true)
        defer { fixture.cleanup() }

        let targetWorkspace = fixture.manager.addWorkspace(title: "Unread Target", select: false)
        let targetSurfaceId = try #require(targetWorkspace.focusedPanelId)
        let older = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Older")
        let latest = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Latest")
        fixture.store.replaceNotificationsForTesting([latest, older])
        fixture.manager.selectTab(fixture.workspace)

        var response = try await sendV2RequestAsync(
            method: "notification.jump_to_unread",
            params: [:],
            to: fixture.socketPath
        )

        #expect(response["ok"] as? Bool == true)
        var result = try #require(response["result"] as? [String: Any])
        #expect(result["opened"] as? Bool == true)
        #expect(result["workspace_id"] as? String == targetWorkspace.id.uuidString)
        #expect(result["surface_id"] as? String == targetSurfaceId.uuidString)
        #expect(result["is_read"] as? Bool == true)
        #expect(fixture.manager.selectedTabId == targetWorkspace.id)
        #expect(fixture.manager.focusedSurfaceId(for: targetWorkspace.id) == targetSurfaceId)
        #expect(fixture.notification(latest.id)?.isRead == true)

        fixture.store.markAllRead()
        let selectedBeforeNoop = fixture.manager.selectedTabId
        let focusedBeforeNoop = fixture.manager.focusedSurfaceId(for: targetWorkspace.id)

        response = try await sendV2RequestAsync(
            method: "notification.jump_to_unread",
            params: [:],
            to: fixture.socketPath
        )

        #expect(response["ok"] as? Bool == true)
        result = try #require(response["result"] as? [String: Any])
        #expect(result["opened"] as? Bool == false)
        #expect(fixture.manager.selectedTabId == selectedBeforeNoop)
        #expect(fixture.manager.focusedSurfaceId(for: targetWorkspace.id) == focusedBeforeNoop)
    }

    @Test
    func notificationJumpToUnreadPayloadMatchesOpenedFallbackNotification() async throws {
        let fixture = try makeSocketFixture(name: "notif-jump-skip", includeWindow: true)
        defer { fixture.cleanup() }

        let targetWorkspace = fixture.manager.addWorkspace(title: "Unread Fallback", select: false)
        let targetSurfaceId = try #require(targetWorkspace.focusedPanelId)
        let unopenable = makeNotification(tabId: UUID(), surfaceId: nil, title: "Closed Workspace")
        let openable = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Openable")
        fixture.store.replaceNotificationsForTesting([unopenable, openable])
        fixture.manager.selectTab(fixture.workspace)

        let response = try await sendV2RequestAsync(
            method: "notification.jump_to_unread",
            params: [:],
            to: fixture.socketPath
        )

        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["opened"] as? Bool == true)
        #expect(result["id"] as? String == openable.id.uuidString)
        #expect(result["workspace_id"] as? String == targetWorkspace.id.uuidString)
        #expect(result["surface_id"] as? String == targetSurfaceId.uuidString)
        #expect(fixture.manager.selectedTabId == targetWorkspace.id)
        #expect(fixture.notification(openable.id)?.isRead == true)
    }

}

private extension TerminalNotificationSocketActionTests {
    func makeSocketFixture(
        name: String,
        includeWindow: Bool = false
    ) throws -> TerminalNotificationSocketTestCase.SocketFixture {
        try socketTestSupport.makeSocketFixture(name: name, includeWindow: includeWindow)
    }

    func makeNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        isRead: Bool = false
    ) -> TerminalNotification {
        socketTestSupport.makeNotification(tabId: tabId, surfaceId: surfaceId, title: title, isRead: isRead)
    }

    func sendV2RequestAsync(
        method: String,
        params: [String: Any] = [:],
        to socketPath: String
    ) async throws -> [String: Any] {
        try await socketTestSupport.sendV2RequestAsync(method: method, params: params, to: socketPath)
    }
}
