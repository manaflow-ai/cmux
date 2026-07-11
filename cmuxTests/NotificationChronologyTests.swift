import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct NotificationChronologyTests {
    @Test
    func restoreMergesLiveAndRestoredNotificationsExactlyOnceInStableOrder() {
        let store = TerminalNotificationStore.shared
        let tabId = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
        let surfaceId = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
        let replayedId = UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
        let earlierId = UUID(uuidString: "40000000-0000-0000-0000-000000000000")!
        let equalLaterId = UUID(uuidString: "50000000-0000-0000-0000-000000000000")!
        let equalEarlierId = UUID(uuidString: "01000000-0000-0000-0000-000000000000")!
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let live = notification(
            id: replayedId,
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Live",
            createdAt: timestamp
        )

        store.replaceNotificationsForTesting([live])
        defer { store.replaceNotificationsForTesting([]) }

        store.restoreSessionNotifications([
            notification(
                id: earlierId,
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Earlier",
                createdAt: timestamp.addingTimeInterval(-1)
            ),
            notification(
                id: equalLaterId,
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Equal later UUID",
                createdAt: timestamp
            ),
            notification(
                id: equalEarlierId,
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Equal earlier UUID",
                createdAt: timestamp
            ),
            notification(
                id: replayedId,
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Stale replay",
                createdAt: timestamp.addingTimeInterval(10)
            ),
        ], forTabId: tabId)

        #expect(store.notifications.map(\.id) == [equalEarlierId, replayedId, equalLaterId, earlierId])
        #expect(store.notifications.first(where: { $0.id == replayedId })?.title == "Live")
        #expect(Set(store.notifications.map(\.id)).count == store.notifications.count)
    }

    @Test
    func repeatedMultiWorkspaceRestoreIsBatchOrderIndependent() {
        let store = TerminalNotificationStore.shared
        let tabA = UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!
        let tabB = UUID(uuidString: "B0000000-0000-0000-0000-000000000000")!
        let a1 = notification(
            id: UUID(uuidString: "A1000000-0000-0000-0000-000000000000")!,
            tabId: tabA,
            surfaceId: nil,
            title: "A1",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let a2 = notification(
            id: UUID(uuidString: "A2000000-0000-0000-0000-000000000000")!,
            tabId: tabA,
            surfaceId: nil,
            title: "A2",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let b1 = notification(
            id: UUID(uuidString: "B1000000-0000-0000-0000-000000000000")!,
            tabId: tabB,
            surfaceId: nil,
            title: "B1",
            createdAt: Date(timeIntervalSince1970: 20)
        )

        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }
        store.restoreSessionNotifications([a1, a2], forTabId: tabA)
        store.restoreSessionNotifications([b1], forTabId: tabB)
        store.restoreSessionNotifications([a2, a1], forTabId: tabA)
        let forwardOrder = store.notifications.map(\.id)

        store.replaceNotificationsForTesting([])
        store.restoreSessionNotifications([b1], forTabId: tabB)
        store.restoreSessionNotifications([a2, a1], forTabId: tabA)
        let reverseOrder = store.notifications.map(\.id)

        #expect(forwardOrder == [a2.id, b1.id, a1.id])
        #expect(reverseOrder == forwardOrder)
    }

    @Test
    func readMutationsAndEveryProjectionPreserveChronologicalOrder() {
        let store = TerminalNotificationStore.shared
        let tabId = UUID()
        let newest = notification(id: UUID(), tabId: tabId, surfaceId: nil, title: "Newest", createdAt: Date(timeIntervalSince1970: 3))
        let middle = notification(id: UUID(), tabId: tabId, surfaceId: nil, title: "Middle", createdAt: Date(timeIntervalSince1970: 2))
        let oldest = notification(id: UUID(), tabId: tabId, surfaceId: nil, title: "Oldest", createdAt: Date(timeIntervalSince1970: 1))

        store.replaceNotificationsForTesting([newest, middle, oldest])
        defer { store.replaceNotificationsForTesting([]) }

        store.markRead(id: newest.id)
        store.markUnread(id: newest.id)
        _ = store.markLatestNotificationAsOldestUnread(forTabId: tabId, surfaceId: nil)

        let expected = [newest.id, middle.id, oldest.id]
        #expect(store.notifications.map(\.id) == expected)
        #expect(store.notifications(forTabIds: [tabId]).map(\.id) == expected)
        #expect(store.notificationMenuSnapshot.recentNotifications.map(\.id) == expected)
        #expect(store.latestNotification(forTabId: tabId)?.id == newest.id)
    }

    @Test
    func sessionSnapshotRoundTripPreservesIdentityAndTimestamp() throws {
        let source = notification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Persisted",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.125)
        )
        let encoded = try JSONEncoder().encode(SessionNotificationSnapshot(notification: source))
        let decoded = try JSONDecoder().decode(SessionNotificationSnapshot.self, from: encoded)
        let restored = decoded.terminalNotification(tabId: source.tabId, surfaceId: source.surfaceId, panelId: source.panelId)

        #expect(restored.id == source.id)
        #expect(restored.createdAt == source.createdAt)
    }

    private func notification(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        createdAt: Date
    ) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: "",
            body: "same payload",
            createdAt: createdAt,
            isRead: false
        )
    }
}
