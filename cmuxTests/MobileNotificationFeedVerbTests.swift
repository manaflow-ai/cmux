import Testing
import AppKit
import CMUXMobileCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for the Mac-side mobile notification-feed RPC verbs.
///
/// Serialized because every case mutates `TerminalNotificationStore.shared`;
/// each test restores the prior list, but the snapshots must not interleave.
@MainActor
@Suite(.serialized)
struct MobileNotificationFeedVerbTests {
    @Test func listPreservesStoreOrderShapeLimitAndAuthoritativeUnreadCount() async throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let newest = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Newest",
            subtitle: "Needs input",
            body: "Choose a deployment target",
            createdAt: Date(timeIntervalSince1970: 1_800_000_003.5),
            isRead: false
        )
        let middle = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Middle",
            subtitle: "",
            body: "Finished tests",
            createdAt: Date(timeIntervalSince1970: 1_800_000_002),
            isRead: true
        )
        let oldest = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Oldest",
            subtitle: "Waiting",
            body: "Review requested",
            createdAt: Date(timeIntervalSince1970: 1_800_000_001),
            isRead: false
        )
        store.replaceNotificationsForTesting([newest, middle, oldest])

        let payload = try await successfulPayload(
            method: "notification.list",
            params: ["limit": 2]
        )
        let items = try #require(payload["notifications"] as? [[String: Any]])
        #expect(payload["unread_count"] as? Int == 2)
        #expect(items.count == 2)
        #expect(items.compactMap { $0["id"] as? String } == [newest.id.uuidString, middle.id.uuidString])

        let first = try #require(items.first)
        #expect(
            Set(first.keys) == [
                "id", "workspace_id", "surface_id", "title", "subtitle",
                "body", "created_at", "is_read",
            ]
        )
        #expect(first["workspace_id"] as? String == newest.tabId.uuidString)
        #expect(first["surface_id"] as? String == newest.surfaceId?.uuidString)
        #expect(first["title"] as? String == newest.title)
        #expect(first["subtitle"] as? String == newest.subtitle)
        #expect(first["body"] as? String == newest.body)
        #expect(first["created_at"] as? Double == newest.createdAt.timeIntervalSince1970)
        #expect(first["is_read"] as? Bool == false)
        #expect(first["workspace_name"] == nil)

        let second = try #require(items.last)
        #expect(second["surface_id"] == nil)
        #expect(second["workspace_name"] == nil)
        #expect(second["is_read"] as? Bool == true)

        let clampedLow = try await successfulPayload(
            method: "notification.list",
            params: ["limit": 0]
        )
        #expect((clampedLow["notifications"] as? [[String: Any]])?.count == 1)

        let clampedHigh = try await successfulPayload(
            method: "notification.list",
            params: ["limit": 999]
        )
        #expect((clampedHigh["notifications"] as? [[String: Any]])?.count == 3)
    }

    @Test func markUnreadCountsTransitionsAndTrimsDedupesAndIgnoresMalformedIDs() async throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let firstRead = notification(title: "First read", isRead: true)
        let secondRead = notification(title: "Second read", isRead: true)
        let alreadyUnread = notification(title: "Already unread", isRead: false)
        store.replaceNotificationsForTesting([firstRead, secondRead, alreadyUnread])

        let payload = try await successfulPayload(
            method: "notification.mark_unread",
            params: [
                "notification_id": "  \(firstRead.id.uuidString)  ",
                "notification_ids": [
                    firstRead.id.uuidString,
                    "not-a-uuid",
                    " \(secondRead.id.uuidString)\n",
                    alreadyUnread.id.uuidString,
                    UUID().uuidString,
                ],
            ]
        )

        #expect(payload["marked"] as? Int == 2)
        #expect(store.notifications.first(where: { $0.id == firstRead.id })?.isRead == false)
        #expect(store.notifications.first(where: { $0.id == secondRead.id })?.isRead == false)
        #expect(store.notifications.first(where: { $0.id == alreadyUnread.id })?.isRead == false)
    }

    @Test func markUnreadCapsTheNotificationIDArrayAt256() async throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let notifications = (0..<257).map { index in
            notification(title: "Read \(index)", isRead: true)
        }
        store.replaceNotificationsForTesting(notifications)

        let payload = try await successfulPayload(
            method: "notification.mark_unread",
            params: ["notification_ids": notifications.map { $0.id.uuidString }]
        )

        #expect(payload["marked"] as? Int == 256)
        #expect(store.notifications.prefix(256).allSatisfy { !$0.isRead })
        #expect(store.notifications[256].isRead)
    }

    @Test func markUnreadRejectsARequestWithNoUsableID() async {
        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "mark-unread-invalid",
                method: "notification.mark_unread",
                params: ["notification_ids": ["", "not-a-uuid", 42]],
                auth: nil
            )
        )

        guard case let .failure(error) = response else {
            Issue.record("Expected malformed notification.mark_unread to fail, got \(response)")
            return
        }
        #expect(error.code == "invalid_params")
    }

    @Test func removeCountsPresentIDsAndTreatsUnknownOrRepeatedIDsAsNoOps() async throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey)
        defer {
            store.replaceNotificationsForTesting(previousNotifications)
            if let previousTombstones {
                UserDefaults.standard.set(previousTombstones, forKey: tombstoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tombstoneKey)
            }
            store.reloadDismissedTombstonesForTesting()
        }

        let first = notification(title: "Remove first", isRead: false)
        let second = notification(title: "Remove second", isRead: true)
        let survivor = notification(title: "Keep", isRead: false)
        store.replaceNotificationsForTesting([first, second, survivor])

        let payload = try await successfulPayload(
            method: "notification.remove",
            params: [
                "notification_id": " \(first.id.uuidString) ",
                "notification_ids": [
                    first.id.uuidString,
                    UUID().uuidString,
                    "malformed",
                    second.id.uuidString,
                    second.id.uuidString,
                ],
            ]
        )

        #expect(payload["removed"] as? Int == 2)
        #expect(store.notifications.map(\.id) == [survivor.id])
    }

    private func notification(title: String, isRead: Bool) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: title,
            subtitle: "",
            body: "Body",
            createdAt: Date(),
            isRead: isRead
        )
    }

    private func successfulPayload(
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "feed-test",
                method: method,
                params: params,
                auth: nil
            )
        )
        guard case let .ok(rawPayload) = response else {
            Issue.record("Expected \(method) to succeed, got \(response)")
            return [:]
        }
        return try #require(rawPayload as? [String: Any])
    }
}
