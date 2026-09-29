import CMUXAgentLaunch
import Foundation
import Testing
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Contract coverage for notification lifetime boundaries shared by terminal,
/// settings-test, Feed, and native macOS delivery.
@MainActor
@Suite("Notification lifetime contract", .serialized)
struct NotificationLifetimeContractTests {
    @Test("Native cmux requests have no app-controlled expiry trigger")
    func nativeRequestHasNoTrigger() {
        let content = UNMutableNotificationContent()
        content.title = "Persistent"

        let request = makeCmuxNotificationRequest(
            identifier: "notification-lifetime-test",
            content: content
        )

        #expect(request.trigger == nil)
    }

    @Test("Old unread history remains until explicit acknowledgement")
    func oldUnreadHistoryRemainsUntilRead() throws {
        let history = NotificationFeedHistoryStore(
            fileURL: nil,
            readRetentionLimit: 10,
            totalRetentionLimit: 10
        )
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Old notification",
            subtitle: "",
            body: "Still needs attention",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        history.record(notification, supersededIDs: [])
        let retained = try #require(history.notifications.first)
        #expect(retained.id == notification.id)
        #expect(!retained.isRead)

        #expect(history.markRead(ids: [notification.id]) == 1)
        #expect(history.notifications.first?.isRead == true)
    }

    @Test("Feed watchdog status changes do not delete the Feed item")
    func feedWatchdogKeepsHistoryItem() throws {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "old-feed-session",
            hookEventName: .permissionRequest,
            source: "claude",
            requestId: "old-feed-request",
            receivedAt: Date(timeIntervalSince1970: 0)
        ))

        let item = try #require(store.items.first)
        #expect(store.pending.count == 1)

        // This is an explicit hook watchdog action, not a display timer. The
        // row remains in the persisted Feed history for later review.
        store.markExpired(item.id)

        #expect(store.items.count == 1)
        #expect(store.pending.isEmpty)
        if case .expired = store.items[0].status {
            // Expected: the safety watchdog changes status, not visibility.
        } else {
            Issue.record("expected the explicit watchdog to mark the item expired")
        }
    }
}
