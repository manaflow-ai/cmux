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
    func acceptedIdentityAndTimestampDriveRecordOrderAndReplayIsIdempotent() {
        let store = TerminalNotificationStore.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let earlierId = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
        let laterId = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
        }

        store.addNotification(
            id: earlierId,
            acceptedAt: Date(timeIntervalSince1970: 10),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Earlier",
            subtitle: "",
            body: "same payload",
            retargetsToLiveSurfaceOwner: false
        )
        store.addNotification(
            id: laterId,
            acceptedAt: Date(timeIntervalSince1970: 20),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Later",
            subtitle: "",
            body: "same payload",
            retargetsToLiveSurfaceOwner: false
        )
        store.addNotification(
            id: earlierId,
            acceptedAt: Date(timeIntervalSince1970: 30),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Replay must not replace",
            subtitle: "",
            body: "same payload",
            retargetsToLiveSurfaceOwner: false
        )

        #expect(store.notifications.map(\.id) == [laterId, earlierId])
        #expect(store.notifications.first(where: { $0.id == earlierId })?.title == "Earlier")
        #expect(store.notifications.first(where: { $0.id == earlierId })?.createdAt == Date(timeIntervalSince1970: 10))
    }

    @Test
    func lateOlderRecordDoesNotReplaceNewerExternalDelivery() {
        let store = TerminalNotificationStore.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let olderId = UUID()
        let newerId = UUID()
        var deliveredIds: [UUID] = []
        var suppressedIds: [UUID] = []
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredIds.append(notification.id)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, notification in
            suppressedIds.append(notification.id)
        }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }
        store.addNotification(
            id: newerId,
            acceptedAt: Date(timeIntervalSince1970: 20),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Newer",
            subtitle: "",
            body: "",
            retargetsToLiveSurfaceOwner: false
        )
        store.addNotification(
            id: olderId,
            acceptedAt: Date(timeIntervalSince1970: 10),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Older",
            subtitle: "",
            body: "",
            retargetsToLiveSurfaceOwner: false
        )

        #expect(store.notifications.map(\.id) == [newerId, olderId])
        #expect(deliveredIds == [newerId])
        #expect(suppressedIds == [olderId])
        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: surfaceId) == newerId)
    }

    @Test
    func longHistorySupersedesOnlyImmediateExternalBannerOwner() {
        let tabId = UUID()
        let surfaceId = UUID()
        let history = (0..<70).map { offset in
            notification(
                id: UUID(),
                tabId: tabId,
                surfaceId: surfaceId,
                title: "History \(offset)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }.sorted(by: TerminalNotificationStore.notificationSortPrecedes)
        let latestExisting = history[0]
        let incoming = notification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Incoming",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        let transition = TerminalNotificationStore.externalBannerTransition(
            incoming: incoming,
            latestExisting: latestExisting
        )

        #expect(transition.supersededId == latestExisting.id.uuidString)
        #expect(!transition.suppressIncoming)
    }

    @Test
    func boundedQueueBackpressuresWithoutDroppingAcceptedNotifications() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }
        let surfaceId = try #require(workspace.focusedPanelId)
        let notificationCount = TerminalMutationBus.maximumPendingMutationCount + 1
        var backpressureCount = 0

        for offset in 0..<notificationCount {
            TerminalMutationBus.shared.enqueueNotification(
                tabId: workspace.id,
                surfaceId: surfaceId,
                title: "Queued \(offset)",
                subtitle: "",
                body: "",
                saturationHandler: {
                    backpressureCount += 1
                    TerminalMutationBus.shared.drainForBackpressure()
                }
            )
        }
        TerminalMutationBus.shared.drainForTesting()

        #expect(backpressureCount == 1)
        #expect(store.notifications.count == notificationCount)
        #expect(Set(store.notifications.map(\.title)).count == notificationCount)
    }

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

        defer { store.replaceNotificationsForTesting([]) }

        let restored = [
            notification(
                id: earlierId,
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Earlier",
                createdAt: timestamp.addingTimeInterval(-1)
            ),
            notification(
                id: earlierId,
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Replay must not replace first occurrence",
                createdAt: timestamp.addingTimeInterval(100)
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
        ]

        store.replaceNotificationsForTesting([live])
        store.restoreSessionNotifications(restored, forTabId: tabId)
        let forward = store.notifications

        store.replaceNotificationsForTesting([live])
        store.restoreSessionNotifications(Array(restored.reversed()), forTabId: tabId)
        let reversed = store.notifications

        #expect(forward.map(\.id) == [equalEarlierId, replayedId, equalLaterId, earlierId])
        #expect(forward.first(where: { $0.id == replayedId })?.title == "Live")
        #expect(forward.first(where: { $0.id == earlierId })?.title == "Earlier")
        #expect(Set(forward.map(\.id)).count == forward.count)
        #expect(reversed == forward)
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
    func restoreClearsStaleFocusedReadIndicatorEvenForReplayOnlySnapshot() {
        let store = TerminalNotificationStore.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let existing = notification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Existing",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        store.replaceNotificationsForTesting([existing])
        store.setFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        defer { store.replaceNotificationsForTesting([]) }

        store.restoreSessionNotifications([existing], forTabId: tabId)

        #expect(store.focusedReadIndicatorSurfaceId(forTabId: tabId) == nil)
        #expect(store.notifications.map(\.id) == [existing.id])
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
    func oldestUnreadNavigationDefersWithoutReorderingFeed() {
        let store = TerminalNotificationStore.shared
        let newestTabId = UUID()
        let nextTabId = UUID()
        let newest = notification(
            id: UUID(),
            tabId: newestTabId,
            surfaceId: nil,
            title: "Newest",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let next = notification(
            id: UUID(),
            tabId: nextTabId,
            surfaceId: nil,
            title: "Next",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        store.replaceNotificationsForTesting([newest, next])
        defer { store.replaceNotificationsForTesting([]) }

        #expect(store.markLatestNotificationAsOldestUnread(forTabId: newestTabId, surfaceId: nil) == newest.id)
        #expect(store.notifications.map(\.id) == [newest.id, next.id])
        #expect(store.notificationsForUnreadNavigation.map(\.id) == [next.id, newest.id])

        store.markRead(id: newest.id)
        store.markUnread(id: newest.id)
        #expect(store.notificationsForUnreadNavigation.map(\.id) == [newest.id, next.id])
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

    @Test
    func provisionalCooldownDoesNotPublishCommittedAdmissionDate() throws {
        var reservations = NotificationCooldownReservations()
        var dates: [String: Date] = [:]
        let key = "agent-finished"
        let reservation = try #require(reservations.reserve(
            key: key,
            interval: 60,
            acceptedAt: Date(timeIntervalSince1970: 100),
            dates: &dates
        ))

        #expect(dates[key] == nil)

        reservations.restore(reservation, dates: &dates)
    }

    @Test
    func reversedCooldownCompletionKeepsNewestReservationMonotonic() throws {
        var reservations = NotificationCooldownReservations()
        var dates: [String: Date] = [:]
        let key = "agent-finished"
        let earlierDate = Date(timeIntervalSince1970: 10)
        let laterDate = Date(timeIntervalSince1970: 20)

        let earlier = try #require(reservations.reserve(
            key: key,
            interval: 5,
            acceptedAt: earlierDate,
            dates: &dates
        ))
        let later = try #require(reservations.reserve(
            key: key,
            interval: 5,
            acceptedAt: laterDate,
            dates: &dates
        ))

        reservations.commit(later, at: laterDate, dates: &dates)
        #expect(dates[key] == laterDate)

        reservations.commit(earlier, at: earlierDate, dates: &dates)
        #expect(dates[key] == laterDate)
    }

    @Test
    func reversedCooldownFailuresRemoveEveryProvisionalReservation() throws {
        var reservations = NotificationCooldownReservations()
        var dates: [String: Date] = [:]
        let key = "agent-finished"
        let earlier = try #require(reservations.reserve(
            key: key,
            interval: 5,
            acceptedAt: Date(timeIntervalSince1970: 10),
            dates: &dates
        ))
        let later = try #require(reservations.reserve(
            key: key,
            interval: 5,
            acceptedAt: Date(timeIntervalSince1970: 20),
            dates: &dates
        ))

        reservations.restore(later, dates: &dates)
        #expect(dates[key] == nil)

        reservations.restore(earlier, dates: &dates)
        #expect(dates[key] == nil)
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
@MainActor
extension TerminalMutationBus {
    func enqueueNotificationForTesting(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) {
        enqueueNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            saturationHandler: { self.drainForBackpressure() }
        )
    }
}
