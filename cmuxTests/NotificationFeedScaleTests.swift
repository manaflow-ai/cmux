import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct NotificationFeedScaleTests {
    @Test
    func liveInsertionsAvoidFullHistoryRebuildsAndPublishOnlyCreatedEvents() {
        verifyLiveInsertions(restoredCount: 2_000, liveCount: 500)
    }

    @Test
    func liveInsertionsRemainIncrementalWithTenThousandRestoredNotifications() {
        verifyLiveInsertions(restoredCount: 10_000, liveCount: 500)
    }

    @Test
    func inconsistentIncrementalIndexesRebuildInsteadOfTrapping() {
        let tabId = UUID()
        let existing = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: UUID(),
            title: "Existing",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 1),
            isRead: false
        )
        let incoming = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: UUID(),
            title: "Incoming",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 2),
            isRead: false
        )
        let notifications = [incoming, existing]
        var indexes = TerminalNotificationStore.buildIndexes(for: [existing])
        indexes.ids.insert(incoming.id)
        TerminalNotificationStore.resetFullIndexRebuildCountForTesting()

        TerminalNotificationStore.insertNotification(
            incoming,
            into: &indexes,
            notifications: notifications
        )

        #expect(TerminalNotificationStore.fullIndexRebuildCountForTesting == 1)
        #expect(indexes.ids == Set(notifications.map(\.id)))
        #expect(indexes.unreadCount == notifications.count)
        #expect(indexes.latestByTabId[tabId]?.id == incoming.id)
    }

    private func verifyLiveInsertions(restoredCount: Int, liveCount: Int) {
        let store = TerminalNotificationStore.shared
        let eventBus = CmuxEventBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let restored = (0..<restoredCount).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Restored \(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }.sorted(by: TerminalNotificationStore.notificationSortPrecedes)

        store.replaceNotificationsForTesting(restored)
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        eventBus.resetForTesting()
        TerminalNotificationStore.resetFullIndexRebuildCountForTesting()
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            eventBus.resetForTesting()
        }

        for index in 0..<liveCount {
            store.addNotification(
                id: UUID(),
                acceptedAt: Date(timeIntervalSince1970: TimeInterval(restoredCount + index)),
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Live \(index)",
                subtitle: "",
                body: ""
            )
        }

        #expect(store.notifications.count == restoredCount + liveCount)
        #expect(Set(store.notifications.map(\.id)).count == restoredCount + liveCount)
        #expect(zip(store.notifications, store.notifications.dropFirst()).allSatisfy {
            TerminalNotificationStore.notificationSortPrecedes($0.0, $0.1)
        })
        #expect(store.notificationMenuSnapshot.unreadCount == restoredCount + liveCount)
        #expect(TerminalNotificationStore.fullIndexRebuildCountForTesting == 0)

        let lifecycleNames = eventBus.retainedSnapshot().compactMap { $0["name"] as? String }
        #expect(lifecycleNames.filter { $0 == "notification.created" }.count == liveCount)
        #expect(!lifecycleNames.contains("notification.removed"))
    }
}
