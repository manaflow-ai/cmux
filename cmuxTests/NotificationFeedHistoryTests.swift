import CMUXMobileCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct NotificationFeedHistoryTests {
    @Test func repeatedSurfaceNotificationsRemainChronologicalAndSupersededEntryBecomesRead() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        defer {
            store.resetNotificationDeliveryHandlerForTesting()
            store.replaceNotificationsForTesting([])
        }

        let workspaceID = UUID()
        let surfaceID = UUID()
        store.addNotification(
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: "First",
            subtitle: "Agent",
            body: "Needs approval"
        )
        store.addNotification(
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: "Second",
            subtitle: "Agent",
            body: "Finished"
        )

        #expect(store.notifications.count == 1)
        #expect(store.notifications.first?.title == "Second")
        let history = store.notificationFeedHistory.notifications
        #expect(history.count == 2)
        #expect(history.map(\.title) == ["Second", "First"])
        #expect(history.map(\.isRead) == [false, true])
    }

    @Test func retentionKeepsEveryUnreadRecordAndOnlyNewestReadRecords() {
        let history = NotificationFeedHistoryStore(
            fileURL: nil,
            readRetentionLimit: 3
        )
        let workspaceID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<5 {
            history.record(
                notification(
                    workspaceID: workspaceID,
                    title: "Read \(offset)",
                    date: baseDate.addingTimeInterval(Double(offset)),
                    isRead: true
                ),
                supersededIDs: [],
                activeNotificationsForBootstrap: []
            )
        }
        for offset in 5..<7 {
            history.record(
                notification(
                    workspaceID: workspaceID,
                    title: "Unread \(offset)",
                    date: baseDate.addingTimeInterval(Double(offset)),
                    isRead: false
                ),
                supersededIDs: [],
                activeNotificationsForBootstrap: []
            )
        }

        #expect(history.notifications.filter { !$0.isRead }.count == 2)
        #expect(history.notifications.filter(\.isRead).map(\.title) == ["Read 4", "Read 3", "Read 2"])
        #expect(history.notifications.count == 5)
    }

    @Test func persistenceReloadsAndRejectsAnOlderRevisionWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-history-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let workspaceID = UUID()
        let first = notification(
            workspaceID: workspaceID,
            title: "Persisted",
            date: Date(timeIntervalSince1970: 2_000),
            isRead: false
        )
        let history = NotificationFeedHistoryStore(fileURL: fileURL)
        history.record(
            first,
            supersededIDs: [],
            activeNotificationsForBootstrap: []
        )
        await history.waitForPersistenceForTesting()

        let reloaded = NotificationFeedHistoryStore(fileURL: fileURL)
        #expect(reloaded.revision == 1)
        #expect(reloaded.notifications.map(\.id) == [first.id])

        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            initialRevision: reloaded.revision
        )
        let newest = NotificationFeedHistorySnapshot(
            revision: 3,
            notifications: reloaded.notifications
        )
        let stale = NotificationFeedHistorySnapshot(revision: 2, notifications: [])
        await persistence.persist(newest)
        await persistence.persist(stale)
        let finalSnapshot = try #require(
            NotificationFeedHistoryPersistence.loadSnapshot(
                fileURL: fileURL,
                fileManager: .default
            )
        )
        #expect(finalSnapshot.revision == 3)
        #expect(finalSnapshot.notifications.map(\.id) == [first.id])
    }

    @Test func revisionsAndChangeEventsAdvanceOnlyForRealMutations() {
        var revisions: [Int] = []
        let history = NotificationFeedHistoryStore(fileURL: nil) { revision in
            revisions.append(revision)
        }
        let entry = notification(
            workspaceID: UUID(),
            title: "Needs input",
            date: Date(timeIntervalSince1970: 3_000),
            isRead: false
        )

        history.record(
            entry,
            supersededIDs: [],
            activeNotificationsForBootstrap: []
        )
        #expect(history.markRead(ids: [UUID()]) == 0)
        #expect(history.markRead(ids: [entry.id]) == 1)
        #expect(history.markRead(ids: [entry.id]) == 0)

        #expect(history.revision == 2)
        #expect(revisions == [1, 2])
    }

    @Test func listBootstrapsCurrentEntriesAndReadRPCsMutateHistoryAndActiveState() async throws {
        let store = TerminalNotificationStore.shared
        let workspaceID = UUID()
        let surfaceID = UUID()
        let older = notification(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            title: "Permission needed",
            date: Date(timeIntervalSince1970: 4_000),
            isRead: false
        )
        let newer = notification(
            workspaceID: workspaceID,
            surfaceID: UUID(),
            title: "Task finished",
            date: Date(timeIntervalSince1970: 4_100),
            isRead: false
        )
        store.replaceNotificationsForTesting([older, newer])
        defer { store.replaceNotificationsForTesting([]) }

        let listResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "feed-list",
                method: "notification.feed.list",
                params: [:],
                auth: nil
            )
        )
        let listPayload = try responsePayload(listResponse)
        #expect(listPayload["revision"] as? Int == 1)
        let rows = try #require(listPayload["notifications"] as? [[String: Any]])
        #expect(rows.map { $0["title"] as? String } == ["Task finished", "Permission needed"])
        #expect(rows.last?["surface_id"] as? String == surfaceID.uuidString)
        #expect(rows.last?["created_at"] as? Double == older.createdAt.timeIntervalSince1970)

        let markResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "feed-mark",
                method: "notification.feed.mark_read",
                params: ["notification_ids": [older.id.uuidString]],
                auth: nil
            )
        )
        let markPayload = try responsePayload(markResponse)
        #expect(markPayload["marked"] as? Int == 1)
        #expect(markPayload["revision"] as? Int == 2)
        #expect(store.notifications.first(where: { $0.id == older.id })?.isRead == true)

        let markAllResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "feed-mark-all",
                method: "notification.feed.mark_all_read",
                params: [:],
                auth: nil
            )
        )
        let markAllPayload = try responsePayload(markAllResponse)
        #expect(markAllPayload["marked"] as? Int == 1)
        #expect(markAllPayload["revision"] as? Int == 3)
        #expect(store.notificationFeedHistory.notifications.allSatisfy(\.isRead))
        #expect(store.notifications.allSatisfy(\.isRead))
    }

    @Test func rebindUpdatesRetargetableHistoricalDestinations() {
        let history = NotificationFeedHistoryStore(fileURL: nil)
        let sourceWorkspaceID = UUID()
        let destinationWorkspaceID = UUID()
        let surfaceID = UUID()
        let entry = notification(
            workspaceID: sourceWorkspaceID,
            surfaceID: surfaceID,
            title: "Moved task",
            date: Date(timeIntervalSince1970: 5_000),
            isRead: false
        )
        history.record(
            entry,
            supersededIDs: [],
            activeNotificationsForBootstrap: []
        )

        history.rebindSurface(
            fromTabId: sourceWorkspaceID,
            toTabId: destinationWorkspaceID,
            surfaceId: surfaceID
        )

        #expect(history.notifications.first?.tabId == destinationWorkspaceID)
        #expect(history.revision == 2)
    }

    private func notification(
        workspaceID: UUID,
        surfaceID: UUID? = nil,
        title: String,
        date: Date,
        isRead: Bool
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: title,
            subtitle: "Agent",
            body: "Body",
            createdAt: date,
            isRead: isRead
        )
    }

    private func responsePayload(_ response: MobileHostRPCResult) throws -> [String: Any] {
        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any] else {
            Issue.record("Expected mobile-host success payload")
            throw NotificationFeedHistoryTestError.missingPayload
        }
        return payload
    }
}

private enum NotificationFeedHistoryTestError: Error {
    case missingPayload
}
