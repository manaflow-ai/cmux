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
            body: "Needs approval",
            retargetsToLiveSurfaceOwner: false
        )
        store.addNotification(
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: "Second",
            subtitle: "Agent",
            body: "Finished",
            retargetsToLiveSurfaceOwner: false
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
                supersededIDs: []
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
                supersededIDs: []
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
            supersededIDs: []
        )
        _ = try await waitForPersistedSnapshot(at: fileURL, revision: 1)

        let reloaded = NotificationFeedHistoryStore(fileURL: fileURL)
        try await waitUntil {
            reloaded.revision == 1 && reloaded.notifications.map(\.id) == [first.id]
        }
        #expect(reloaded.revision == 1)
        #expect(reloaded.notifications.map(\.id) == [first.id])

        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default
        )
        let newest = NotificationFeedHistorySnapshot(
            revision: 3,
            notifications: reloaded.notifications
        )
        let stale = NotificationFeedHistorySnapshot(revision: 2, notifications: [])
        await persistence.persist(newest)
        await persistence.persist(stale)
        let verifier = NotificationFeedHistoryPersistence(fileURL: fileURL, fileManager: .default)
        let finalOutcome = await verifier.load()
        guard case .loaded(let finalSnapshot) = finalOutcome else {
            Issue.record("Expected a supported persisted notification feed")
            return
        }
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
            supersededIDs: []
        )
        #expect(history.markRead(ids: [UUID()]) == 0)
        #expect(history.markRead(ids: [entry.id]) == 1)
        #expect(history.markRead(ids: [entry.id]) == 0)
        history.markUnread(ids: [entry.id])
        #expect(history.notifications.first?.isRead == false)
        history.markUnread(ids: [entry.id])

        #expect(history.revision == 3)
        #expect(revisions == [1, 2, 3])
    }

    @Test func listBootstrapsCurrentEntriesAndReadStateRPCsMutateHistoryAndActiveState() async throws {
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
        #expect(store.notificationFeedHistory.notifications.allSatisfy { $0.isRead })
        #expect(store.notifications.allSatisfy { $0.isRead })

        store.remove(id: older.id)
        #expect(store.notifications.contains(where: { $0.id == older.id }) == false)

        let markUnreadResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "feed-mark-unread",
                method: "notification.feed.mark_unread",
                params: ["notification_ids": [older.id.uuidString]],
                auth: nil
            )
        )
        let markUnreadPayload = try responsePayload(markUnreadResponse)
        #expect(markUnreadPayload["marked"] as? Int == 1)
        #expect(markUnreadPayload["revision"] as? Int == 4)
        #expect(store.notificationFeedHistory.notifications.first(where: { $0.id == older.id })?.isRead == false)
        #expect(store.notifications.contains(where: { $0.id == older.id }) == false)
    }

    @Test func unsupportedFutureSnapshotIsPreservedWhenHistoryMutates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-future-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let existing = notification(
            workspaceID: UUID(),
            title: "Future row",
            date: Date(timeIntervalSince1970: 4_500),
            isRead: false
        )
        let futureSnapshot = NotificationFeedHistorySnapshot(
            revision: 12,
            notifications: [NotificationFeedHistoryRecord(notification: existing)],
            version: NotificationFeedHistorySnapshot.currentVersion + 1
        )
        let originalData = try write(futureSnapshot, to: fileURL)

        let history = NotificationFeedHistoryStore(fileURL: fileURL)
        history.record(
            notification(
                workspaceID: UUID(),
                title: "Local row",
                date: Date(timeIntervalSince1970: 4_600),
                isRead: false
            ),
            supersededIDs: []
        )
        let verifier = NotificationFeedHistoryPersistence(fileURL: fileURL, fileManager: .default)
        let outcome = await verifier.load()
        #expect(outcome == .unsupportedVersion(futureSnapshot.version))

        await history.loadingTask?.value
        let finalData = try Data(contentsOf: fileURL)
        #expect(finalData == originalData)
    }

    @Test func nonemptyPersistedHistoryReconcilesMissingActiveNotificationsIdempotently() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-reconcile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let workspaceID = UUID()
        let persisted = notification(
            workspaceID: workspaceID,
            title: "Persisted row",
            date: Date(timeIntervalSince1970: 5_000),
            isRead: true
        )
        let active = notification(
            workspaceID: workspaceID,
            title: "Restored active row",
            date: Date(timeIntervalSince1970: 5_100),
            isRead: false
        )
        _ = try write(
            NotificationFeedHistorySnapshot(
                revision: 8,
                notifications: [NotificationFeedHistoryRecord(notification: persisted)]
            ),
            to: fileURL
        )

        let history = NotificationFeedHistoryStore(fileURL: fileURL)
        try await waitUntil {
            history.revision == 8 && history.notifications.map(\.id) == [persisted.id]
        }
        history.reconcileActiveNotifications([active])
        let reconciledRevision = history.revision
        history.reconcileActiveNotifications([active])

        #expect(history.notifications.map(\.id) == [active.id, persisted.id])
        #expect(reconciledRevision == 9)
        #expect(history.revision == reconciledRevision)
    }

    @Test func mutationsBeforeAsyncLoadReplayOverPersistedHistoryInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-load-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let workspaceID = UUID()
        let persisted = notification(
            workspaceID: workspaceID,
            title: "Persisted middle",
            date: Date(timeIntervalSince1970: 6_000),
            isRead: false
        )
        _ = try write(
            NotificationFeedHistorySnapshot(
                revision: 7,
                notifications: [NotificationFeedHistoryRecord(notification: persisted)]
            ),
            to: fileURL
        )

        let history = NotificationFeedHistoryStore(fileURL: fileURL)
        let newest = notification(
            workspaceID: workspaceID,
            title: "Newest local",
            date: Date(timeIntervalSince1970: 6_100),
            isRead: false
        )
        let oldest = notification(
            workspaceID: workspaceID,
            title: "Oldest local",
            date: Date(timeIntervalSince1970: 5_900),
            isRead: false
        )

        #expect(history.markRead(ids: [persisted.id]) == 0)
        history.record(newest, supersededIDs: [])
        history.record(oldest, supersededIDs: [])
        try await waitUntil {
            history.revision == 10 &&
                history.notifications.map(\.id) == [newest.id, persisted.id, oldest.id] &&
                history.notifications.first(where: { $0.id == persisted.id })?.isRead == true
        }
        _ = try await waitForPersistedSnapshot(at: fileURL, revision: 10)

        #expect(history.revision == 10)
        #expect(history.notifications.map(\.id) == [newest.id, persisted.id, oldest.id])
        #expect(history.notifications.first(where: { $0.id == persisted.id })?.isRead == true)

        let reloaded = NotificationFeedHistoryStore(fileURL: fileURL)
        try await waitUntil {
            reloaded.revision == 10 &&
                reloaded.notifications.map(\.id) == [newest.id, persisted.id, oldest.id]
        }
        #expect(reloaded.revision == 10)
        #expect(reloaded.notifications.map(\.id) == [newest.id, persisted.id, oldest.id])
        #expect(reloaded.notifications.first(where: { $0.id == persisted.id })?.isRead == true)
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
            supersededIDs: []
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

    @discardableResult
    private func write(
        _ snapshot: NotificationFeedHistorySnapshot,
        to fileURL: URL
    ) throws -> Data {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        return data
    }

    private func waitForPersistedSnapshot(
        at fileURL: URL,
        revision: Int
    ) async throws -> NotificationFeedHistorySnapshot {
        var persisted: NotificationFeedHistorySnapshot?
        try await waitUntil {
            guard let data = try? Data(contentsOf: fileURL),
                  let snapshot = try? JSONDecoder().decode(NotificationFeedHistorySnapshot.self, from: data),
                  snapshot.revision >= revision else {
                return false
            }
            persisted = snapshot
            return true
        }
        return try #require(persisted)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw NotificationFeedHistoryTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum NotificationFeedHistoryTestError: Error {
    case missingPayload
    case timeout
}
