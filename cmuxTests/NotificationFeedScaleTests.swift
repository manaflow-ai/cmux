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
    func retainedFeedEvictsOldestRowAtDefaultCapacityBoundary() {
        let store = TerminalNotificationStore.shared
        let eventBus = CmuxEventBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let limit = TerminalNotificationStore.maximumNotificationFeedCount

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        eventBus.resetForTesting()
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            eventBus.resetForTesting()
        }

        let notifications = (0...limit).reversed().map { index in
            TerminalNotification(
                id: UUID(),
                tabId: tabId,
                surfaceId: surfaceId,
                retargetsToLiveSurfaceOwner: false,
                title: "History \(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }
        store.replaceNotificationsForTesting(notifications)

        #expect(store.notifications.count == limit)
        #expect(store.unreadNotificationCount == limit)
        #expect(store.notifications.first?.title == "History \(limit)")
        #expect(store.notifications.last?.title == "History 1")
        #expect(!store.notifications.contains { $0.title == "History 0" })
        #expect(Set(store.notifications.map(\.id)).count == limit)
    }

    @Test
    func liveAppendAtCapacityEvictsOldestRowIncrementally() {
        let store = TerminalNotificationStore.shared
        let eventBus = CmuxEventBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let limit = TerminalNotificationStore.maximumNotificationFeedCount

        let notifications = (0..<limit).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: tabId,
                surfaceId: surfaceId,
                retargetsToLiveSurfaceOwner: false,
                title: "History \(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }.sorted(by: TerminalNotificationStore.notificationSortPrecedes)

        store.replaceNotificationsForTesting(notifications)
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

        store.addNotification(
            id: UUID(),
            acceptedAt: Date(timeIntervalSince1970: TimeInterval(limit + 1)),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Live at cap",
            subtitle: "",
            body: "",
            retargetsToLiveSurfaceOwner: false
        )

        #expect(store.notifications.count == limit)
        #expect(store.notifications.first?.title == "Live at cap")
        #expect(store.notifications.last?.title == "History 1")
        #expect(!store.notifications.contains { $0.title == "History 0" })
        #expect(store.unreadNotificationCount == limit)
        #expect(store.latestNotification(forTabId: tabId)?.title == "Live at cap")
        #expect(TerminalNotificationStore.fullIndexRebuildCountForTesting == 0)
        let lifecycleNames = eventBus.retainedSnapshot().compactMap { $0["name"] as? String }
        #expect(lifecycleNames == ["notification.removed", "notification.created"])
    }

    @Test
    func cappedAppendWithOneRowPerSurfaceDropsEvictedLatestWithoutHistoryRecovery() throws {
        let store = TerminalNotificationStore.shared
        let eventBus = CmuxEventBus.shared
        let limit = TerminalNotificationStore.maximumNotificationFeedCount

        let notifications = (0..<limit).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: UUID(),
                retargetsToLiveSurfaceOwner: false,
                title: "Distinct \(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }.sorted(by: TerminalNotificationStore.notificationSortPrecedes)
        let evicted = try #require(notifications.last)

        store.replaceNotificationsForTesting(notifications)
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

        store.addNotification(
            id: UUID(),
            acceptedAt: Date(timeIntervalSince1970: TimeInterval(limit + 1)),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Distinct live at cap",
            subtitle: "",
            body: "",
            retargetsToLiveSurfaceOwner: false
        )

        #expect(store.notifications.count == limit)
        #expect(!store.notifications.contains { $0.id == evicted.id })
        #expect(store.latestNotification(forTabId: evicted.tabId) == nil)
        #expect(!store.hasUnreadNotification(forTabId: evicted.tabId, surfaceId: evicted.surfaceId))
        #expect(TerminalNotificationStore.fullIndexRebuildCountForTesting == 0)
    }

    @Test
    func retainedFeedEvictsOldestRowsByAggregateContentBytes() throws {
        let store = TerminalNotificationStore.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let body = String(repeating: "x", count: TerminalNotificationStore.maximumNotificationBodyBytes)
        let rowBytes = body.utf8.count
        let retainedByBytes = TerminalNotificationStore.maximumNotificationFeedContentBytes / rowBytes
        let totalRows = retainedByBytes + 3
        let notifications = (0..<totalRows).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: tabId,
                surfaceId: surfaceId,
                retargetsToLiveSurfaceOwner: false,
                title: "",
                subtitle: "",
                body: body,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }.sorted(by: TerminalNotificationStore.notificationSortPrecedes)

        store.replaceNotificationsForTesting(notifications)
        defer { store.replaceNotificationsForTesting([]) }

        #expect(store.notifications.count == retainedByBytes)
        #expect(store.notifications.first?.createdAt == notifications.first?.createdAt)
        #expect(store.notifications.last?.createdAt == notifications[retainedByBytes - 1].createdAt)
        let retainedBytes = store.notifications.reduce(0) {
            $0 + $1.title.utf8.count + $1.subtitle.utf8.count + $1.body.utf8.count
        }
        #expect(retainedBytes <= TerminalNotificationStore.maximumNotificationFeedContentBytes)
        let evictedIDs = Set(notifications.dropFirst(retainedByBytes).map(\.id))
        #expect(store.notifications.allSatisfy { !evictedIDs.contains($0.id) })
    }

    @Test
    func retainedFeedByteLimitEvictsChronologicalSuffix() throws {
        let store = TerminalNotificationStore.shared
        let body = String(repeating: "x", count: TerminalNotificationStore.maximumNotificationBodyBytes)
        let retainedByBytes = TerminalNotificationStore.maximumNotificationFeedContentBytes / body.utf8.count
        let retained = (0..<retainedByBytes).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: UUID(),
                retargetsToLiveSurfaceOwner: false,
                title: "",
                subtitle: "",
                body: body,
                createdAt: Date(timeIntervalSince1970: TimeInterval(retainedByBytes + 2 - index)),
                isRead: false
            )
        }
        let firstEvicted = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            retargetsToLiveSurfaceOwner: false,
            title: "first evicted",
            subtitle: "",
            body: "x",
            createdAt: Date(timeIntervalSince1970: 1),
            isRead: false
        )
        let olderSmall = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            retargetsToLiveSurfaceOwner: false,
            title: "",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )
        let notifications = (retained + [firstEvicted, olderSmall])
            .sorted(by: TerminalNotificationStore.notificationSortPrecedes)

        store.replaceNotificationsForTesting(notifications)
        defer { store.replaceNotificationsForTesting([]) }

        #expect(store.notifications.count == retainedByBytes)
        #expect(!store.notifications.contains { $0.id == firstEvicted.id })
        #expect(!store.notifications.contains { $0.id == olderSmall.id })
    }

    @Test
    func liveAppendAtByteCapacityEvictsOldestRowsIncrementally() throws {
        let store = TerminalNotificationStore.shared
        let eventBus = CmuxEventBus.shared
        let body = String(repeating: "x", count: TerminalNotificationStore.maximumNotificationBodyBytes / 2)
        let oldRowBytes = body.utf8.count
        let retainedByBytes = TerminalNotificationStore.maximumNotificationFeedContentBytes / oldRowBytes
        let liveBody = String(repeating: "y", count: TerminalNotificationStore.maximumNotificationBodyBytes)
        let expectedEvictionCount = liveBody.utf8.count / oldRowBytes
        let existing = (0..<retainedByBytes).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: UUID(),
                retargetsToLiveSurfaceOwner: false,
                title: "",
                subtitle: "",
                body: body,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }.sorted(by: TerminalNotificationStore.notificationSortPrecedes)
        let evictedIDs = Set(existing.suffix(expectedEvictionCount).map(\.id))
        let liveId = UUID()
        let liveTabId = UUID()
        let liveSurfaceId = UUID()

        store.replaceNotificationsForTesting(existing)
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

        store.addNotification(
            id: liveId,
            acceptedAt: Date(timeIntervalSince1970: TimeInterval(retainedByBytes + 1)),
            tabId: liveTabId,
            surfaceId: liveSurfaceId,
            title: "",
            subtitle: "",
            body: liveBody,
            retargetsToLiveSurfaceOwner: false
        )

        #expect(store.notifications.first?.id == liveId)
        #expect(store.notifications.count == retainedByBytes - expectedEvictionCount + 1)
        #expect(store.notifications.allSatisfy { !evictedIDs.contains($0.id) })
        #expect(store.latestNotification(forTabId: liveTabId)?.id == liveId)
        #expect(TerminalNotificationStore.fullIndexRebuildCountForTesting == 0)
        let lifecycleNames = eventBus.retainedSnapshot().compactMap { $0["name"] as? String }
        #expect(
            lifecycleNames
                == Array(repeating: "notification.removed", count: expectedEvictionCount)
                    + ["notification.created"]
        )
    }

    @Test
    func largeByteCapacityEvictionPreservesPerRowRemovalEvents() throws {
        let store = TerminalNotificationStore.shared
        let eventBus = CmuxEventBus.shared
        let oldBody = String(repeating: "x", count: 512)
        let oldRowBytes = oldBody.utf8.count
        let retainedByBytes = TerminalNotificationStore.maximumNotificationFeedContentBytes / oldRowBytes
        let liveBody = String(repeating: "y", count: TerminalNotificationStore.maximumNotificationBodyBytes)
        let expectedEvictionCount = liveBody.utf8.count / oldRowBytes
        let existing = (0..<retainedByBytes).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: UUID(),
                retargetsToLiveSurfaceOwner: false,
                title: "",
                subtitle: "",
                body: oldBody,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }.sorted(by: TerminalNotificationStore.notificationSortPrecedes)

        store.replaceNotificationsForTesting(existing)
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

        store.addNotification(
            id: UUID(),
            acceptedAt: Date(timeIntervalSince1970: TimeInterval(retainedByBytes + 1)),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "",
            subtitle: "",
            body: liveBody,
            retargetsToLiveSurfaceOwner: false
        )

        let events = eventBus.retainedSnapshot()
        #expect(TerminalNotificationStore.fullIndexRebuildCountForTesting == 0)
        #expect(
            events.compactMap { $0["name"] as? String }
                == Array(repeating: "notification.removed", count: expectedEvictionCount)
                    + ["notification.created"]
        )
        let removedPayloads = try events.dropLast().map { event in
            try #require(event["payload"] as? [String: Any])
        }
        #expect(removedPayloads.count == expectedEvictionCount)
        #expect(removedPayloads.allSatisfy { $0["notification_id"] is String })
    }

    @Test
    func incrementalReadStateUpdatesPanelAliasUnreadProjection() throws {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()
        let surfaceId = UUID()
        let panelId = UUID()
        let notification = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: false,
            title: "Panel alias",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 1),
            isRead: false
        )

        store.replaceNotificationsForTesting([notification])
        defer { store.replaceNotificationsForTesting([]) }

        #expect(store.sidebarUnread.hasUnreadNotification(forWorkspaceId: workspaceId, surfaceId: surfaceId))
        #expect(store.sidebarUnread.hasUnreadNotification(forWorkspaceId: workspaceId, surfaceId: panelId))

        store.markRead(id: notification.id)

        #expect(!store.sidebarUnread.hasUnreadNotification(forWorkspaceId: workspaceId, surfaceId: surfaceId))
        #expect(!store.sidebarUnread.hasUnreadNotification(forWorkspaceId: workspaceId, surfaceId: panelId))
    }

    @Test
    func notificationAdmissionTruncatesOversizedTextFields() throws {
        let store = TerminalNotificationStore.shared
        let eventBus = CmuxEventBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let title = String(repeating: "é", count: TerminalNotificationStore.maximumNotificationTitleBytes)
        let subtitle = String(repeating: "s", count: TerminalNotificationStore.maximumNotificationSubtitleBytes + 128)
        let body = String(repeating: "b", count: TerminalNotificationStore.maximumNotificationBodyBytes + 128)
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        eventBus.resetForTesting()
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            eventBus.resetForTesting()
        }

        store.addNotification(
            id: UUID(),
            acceptedAt: Date(timeIntervalSince1970: 1),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            retargetsToLiveSurfaceOwner: false
        )

        let notification = try #require(store.notifications.first)
        #expect(notification.title.utf8.count <= TerminalNotificationStore.maximumNotificationTitleBytes)
        #expect(notification.subtitle.utf8.count == TerminalNotificationStore.maximumNotificationSubtitleBytes)
        #expect(notification.body.utf8.count == TerminalNotificationStore.maximumNotificationBodyBytes)
        #expect(String(notification.title.last ?? "x").utf8.count == 2)
    }

    @Test
    func frozenFeedSnapshotSurvivesStorageCompaction() {
        let store = TerminalNotificationStore.shared
        let eventBus = CmuxEventBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let limit = TerminalNotificationStore.maximumNotificationFeedCount

        let notifications = (0..<limit).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: tabId,
                surfaceId: surfaceId,
                retargetsToLiveSurfaceOwner: false,
                title: "History \(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }.sorted(by: TerminalNotificationStore.notificationSortPrecedes)

        store.replaceNotificationsForTesting(notifications)
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        TerminalNotificationStore.notificationFeedCompactionOffsetForTesting = 8
        eventBus.resetForTesting()
        defer {
            store.replaceNotificationsForTesting([])
            TerminalNotificationStore.notificationFeedCompactionOffsetForTesting = nil
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            eventBus.resetForTesting()
        }

        let frozen = store.notifications
        let frozenFirst = frozen.first?.id
        let frozenLast = frozen.last?.id

        for index in 0..<8 {
            store.addNotification(
                id: UUID(),
                acceptedAt: Date(timeIntervalSince1970: TimeInterval(limit + index + 1)),
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Live \(index)",
                subtitle: "",
                body: "",
                retargetsToLiveSurfaceOwner: false
            )
        }

        #expect(frozen.count == limit)
        #expect(frozen.first?.id == frozenFirst)
        #expect(frozen.last?.id == frozenLast)
        #expect(store.notifications.count == limit)
        #expect(store.notifications.first?.title == "Live 7")
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

    @Test
    func singleRowReadStateChangesAvoidFullHistoryRebuildAndDiff() throws {
        let store = TerminalNotificationStore.shared
        let eventBus = CmuxEventBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let notifications = (0..<10_000).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: tabId,
                surfaceId: surfaceId,
                title: "History \(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }.sorted(by: TerminalNotificationStore.notificationSortPrecedes)
        let target = try #require(notifications.first)

        store.replaceNotificationsForTesting(notifications)
        eventBus.resetForTesting()
        TerminalNotificationStore.resetFullIndexRebuildCountForTesting()
        defer {
            store.replaceNotificationsForTesting([])
            eventBus.resetForTesting()
        }

        store.markRead(id: target.id)
        #expect(TerminalNotificationStore.fullIndexRebuildCountForTesting == 0)
        #expect(store.unreadNotificationCount == notifications.count - 1)
        #expect(store.notifications.first(where: { !$0.isRead && $0.tabId == tabId })?.id == notifications[1].id)
        #expect(store.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId))
        let readEvents = eventBus.retainedSnapshot().compactMap { $0["name"] as? String }
        #expect(readEvents == ["notification.read"])

        eventBus.resetForTesting()
        store.markUnread(id: target.id)
        #expect(TerminalNotificationStore.fullIndexRebuildCountForTesting == 0)
        #expect(store.unreadNotificationCount == notifications.count)
        #expect(store.notifications.first(where: { !$0.isRead && $0.tabId == tabId })?.id == target.id)
        #expect(eventBus.retainedSnapshot().isEmpty)
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
                body: "",
                retargetsToLiveSurfaceOwner: false
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
