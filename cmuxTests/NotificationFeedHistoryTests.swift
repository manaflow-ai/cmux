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

    @Test func totalRetentionCapsUnreadHistoryAtNewestRecords() {
        let history = NotificationFeedHistoryStore(
            fileURL: nil,
            readRetentionLimit: 10,
            totalRetentionLimit: 3
        )
        let workspaceID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<5 {
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

        #expect(history.notifications.count == 3)
        #expect(history.notifications.map(\.title) == ["Unread 4", "Unread 3", "Unread 2"])
        #expect(history.notifications.allSatisfy { !$0.isRead })
    }

    @Test func liveHistoryIngressNormalizesOversizedTextBeforeSnapshot() throws {
        let history = NotificationFeedHistoryStore(
            fileURL: nil,
            readRetentionLimit: 10,
            totalRetentionLimit: 2
        )
        history.record(
            notification(
                workspaceID: UUID(),
                title: String(repeating: "t", count: NotificationFeedHistoryRecord.historyTitleByteLimit * 4),
                body: String(repeating: "b", count: NotificationFeedHistoryRecord.historyBodyByteLimit * 4),
                date: Date(timeIntervalSince1970: 1_260),
                isRead: false
            ),
            supersededIDs: []
        )

        let record = try #require(history.notifications.first)
        #expect(record.title.utf8.count == NotificationFeedHistoryRecord.historyTitleByteLimit)
        #expect(record.body.utf8.count == NotificationFeedHistoryRecord.historyBodyByteLimit)
        #expect(history.snapshot.notifications.first?.body == record.body)
    }

    @Test func oversizedActiveReconcileDoesNotChurnRevisionAfterRetentionTrim() {
        var revisions: [Int] = []
        let history = NotificationFeedHistoryStore(
            fileURL: nil,
            readRetentionLimit: 10,
            totalRetentionLimit: 3
        ) { revision in
            revisions.append(revision)
        }
        let workspaceID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_200)
        let active = (0..<5).map { offset in
            notification(
                workspaceID: workspaceID,
                title: "Active \(offset)",
                date: baseDate.addingTimeInterval(Double(offset)),
                isRead: false
            )
        }

        history.reconcileActiveNotifications(active)
        let retainedTitles = history.notifications.map(\.title)
        let retainedRevision = history.revision
        history.reconcileActiveNotifications(active)

        #expect(retainedTitles == ["Active 4", "Active 3", "Active 2"])
        #expect(history.notifications.map(\.title) == retainedTitles)
        #expect(history.revision == retainedRevision)
        #expect(revisions == [1])
    }

    @Test func activeReconcileCapsBeforeMaterializingHistoryRecords() {
        let history = NotificationFeedHistoryStore(
            fileURL: nil,
            readRetentionLimit: 10,
            totalRetentionLimit: 2
        )
        let workspaceID = UUID()
        let dropped = notification(
            workspaceID: workspaceID,
            title: "Dropped oversized active",
            body: String(repeating: "x", count: NotificationFeedHistoryRecord.historyBodyByteLimit * 8),
            date: Date(timeIntervalSince1970: 1_250),
            isRead: false
        )
        let retainedOlder = notification(
            workspaceID: workspaceID,
            title: "Retained older",
            date: Date(timeIntervalSince1970: 1_251),
            isRead: false
        )
        let retainedNewer = notification(
            workspaceID: workspaceID,
            title: "Retained newer",
            date: Date(timeIntervalSince1970: 1_252),
            isRead: false
        )

        history.reconcileActiveNotifications([dropped, retainedOlder, retainedNewer])

        #expect(history.notifications.map(\.title) == ["Retained newer", "Retained older"])
        #expect(history.notifications.allSatisfy {
            $0.body.utf8.count <= NotificationFeedHistoryRecord.historyBodyByteLimit
        })
    }

    @Test func loadingOversizedHistoryPersistsCompactedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-compaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let workspaceID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_500)
        let records = (0..<5).map { offset in
            NotificationFeedHistoryRecord(notification: notification(
                workspaceID: workspaceID,
                title: "Persisted unread \(offset)",
                date: baseDate.addingTimeInterval(Double(offset)),
                isRead: false
            ))
        }
        _ = try write(
            NotificationFeedHistorySnapshot(
                revision: 4,
                notifications: records
            ),
            to: fileURL
        )

        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3
        )
        let outcome = await persistence.load()
        guard case .loaded(let loaded) = outcome else {
            Issue.record("Expected compacted persisted notification feed")
            return
        }

        let loadedTitles = loaded.notifications.map(\.title)
        #expect(loaded.revision == 4)
        #expect(loadedTitles == ["Persisted unread 4", "Persisted unread 3", "Persisted unread 2"])

        let persisted = try JSONDecoder().decode(
            NotificationFeedHistorySnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(persisted.revision == 4)
        #expect(persisted.notifications.map(\.title) == loadedTitles)
    }

    @Test func loadedLegacyHistoryNormalizesOversizedTextBeforeSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-legacy-text-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let legacyRecord = NotificationFeedHistoryRecord(notification: notification(
            workspaceID: UUID(),
            title: String(repeating: "l", count: NotificationFeedHistoryRecord.historyTitleByteLimit * 4),
            body: String(repeating: "g", count: NotificationFeedHistoryRecord.historyBodyByteLimit * 4),
            date: Date(timeIntervalSince1970: 1_560),
            isRead: false
        ))
        try write(
            NotificationFeedHistorySnapshot(
                revision: 11,
                notifications: [legacyRecord]
            ),
            to: fileURL
        )
        let history = NotificationFeedHistoryStore(fileURL: fileURL)

        try await waitUntil {
            history.notifications.first?.body.utf8.count == NotificationFeedHistoryRecord.historyBodyByteLimit
        }
        let record = try #require(history.notifications.first)
        #expect(record.title.utf8.count == NotificationFeedHistoryRecord.historyTitleByteLimit)
        #expect(record.body.utf8.count == NotificationFeedHistoryRecord.historyBodyByteLimit)
        #expect(history.snapshot.notifications.first?.title == record.title)
    }

    @Test func oversizedHistoryFileIsQuarantinedWithMonotonicRevisionAndWritesRecover() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-size-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let staleBackupURL = directory.appendingPathComponent(
            "history.json.oversized-stale.quarantine",
            isDirectory: false
        )
        let workspaceID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_600)
        let records = (0..<5).reversed().map { offset in
            NotificationFeedHistoryRecord(notification: notification(
                workspaceID: workspaceID,
                title: "Recovered \(offset)",
                body: String(repeating: "x", count: 128),
                date: baseDate.addingTimeInterval(Double(offset)),
                isRead: false
            ))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale backup".utf8).write(to: staleBackupURL)
        let data = try write(
            NotificationFeedHistorySnapshot(
                revision: 6,
                notifications: records
            ),
            to: fileURL,
            sortedKeys: true
        )
        let compactEncoder = JSONEncoder()
        compactEncoder.outputFormatting = [.sortedKeys]
        let compactData = try compactEncoder.encode(NotificationFeedHistorySnapshot(
            revision: 6,
            notifications: Array(records.prefix(3))
        ))

        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: UInt64(compactData.count)
        )
        #expect(data.count > compactData.count)

        let outcome = await persistence.load()
        guard case .loaded(let loaded) = outcome else {
            Issue.record("Expected oversized current-version notification feed to preserve revision")
            return
        }
        #expect(loaded.revision == 6)
        let loadedTitles = loaded.notifications.map(\.title)
        #expect(loadedTitles == ["Recovered 4", "Recovered 3", "Recovered 2"])
        let replacement = try JSONDecoder().decode(
            NotificationFeedHistorySnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(replacement.revision == 6)
        #expect(replacement.notifications.map(\.title) == loadedTitles)
        let replacementQuarantines = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("history.json.oversized")
        }
        #expect(replacementQuarantines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staleBackupURL.path))
        await persistence.persist(NotificationFeedHistorySnapshot(
            revision: 7,
            notifications: loaded.notifications
        ))
        let remainingQuarantines = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("history.json.oversized")
        }
        #expect(remainingQuarantines.isEmpty)
        let recovered = try JSONDecoder().decode(
            NotificationFeedHistorySnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(recovered.revision == 7)
        #expect(recovered.notifications.map(\.title) == loadedTitles)

        try FileManager.default.removeItem(at: fileURL)
        let verifier = NotificationFeedHistoryPersistence(fileURL: fileURL, fileManager: .default)
        #expect(await verifier.load() == .missing)
    }

    @Test func oversizedFutureSnapshotIsPreservedReadOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-oversized-future-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let workspaceID = UUID()
        let futureSnapshot = NotificationFeedHistorySnapshot(
            revision: 14,
            notifications: [
                NotificationFeedHistoryRecord(notification: notification(
                    workspaceID: workspaceID,
                    title: "Future large",
                    body: String(repeating: "f", count: 1_024),
                    date: Date(timeIntervalSince1970: 1_650),
                    isRead: false
                ))
            ],
            version: NotificationFeedHistorySnapshot.currentVersion + 1
        )
        let originalData = try write(futureSnapshot, to: fileURL, sortedKeys: true)
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: UInt64(originalData.count - 1)
        )

        #expect(await persistence.load() == .unsupportedVersion(futureSnapshot.version))
        await persistence.persist(NotificationFeedHistorySnapshot(revision: 15, notifications: []))

        let finalData = try Data(contentsOf: fileURL)
        #expect(finalData == originalData)
        let quarantinedURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("history.json.oversized-")
        }
        #expect(quarantinedURLs.isEmpty)
    }

    @Test func oversizedFutureSnapshotIgnoresNestedMetadataInPrefix() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-nested-metadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let id = UUID().uuidString
        let workspaceID = UUID().uuidString
        let body = String(repeating: "x", count: 70_000)
        let rawJSON = """
        {"notifications":[{"revision":6,"version":1,"body":"\(body)","createdAt":0,"id":"\(id)","isRead":false,"retargetsToLiveSurfaceOwner":false,"subtitle":"Agent","tabId":"\(workspaceID)","title":"Nested metadata"}],"revision":14,"version":\(NotificationFeedHistorySnapshot.currentVersion + 1)}
        """
        let data = Data(rawJSON.utf8)
        try data.write(to: fileURL, options: .atomic)
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: UInt64(data.count - 1)
        )

        #expect(await persistence.load() == .unsupportedVersion(NotificationFeedHistorySnapshot.currentVersion + 1))
        #expect(try Data(contentsOf: fileURL) == data)
        let quarantinedURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("history.json.oversized")
        }
        #expect(quarantinedURLs.isEmpty)
    }

    @Test func oversizedFutureSnapshotIgnoresNestedMetadataInTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-tail-metadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let id = UUID().uuidString
        let workspaceID = UUID().uuidString
        let body = String(repeating: "x", count: 70_000)
        let rawJSON = """
        {"notifications":[{"body":"\(body)","createdAt":0,"id":"\(id)","isRead":false,"retargetsToLiveSurfaceOwner":false,"subtitle":"Agent","tabId":"\(workspaceID)","title":"Tail metadata"}],"revision":18,"summary":{"version":1},"version":\(NotificationFeedHistorySnapshot.currentVersion + 1)}
        """
        let data = Data(rawJSON.utf8)
        try data.write(to: fileURL, options: .atomic)
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: UInt64(data.count - 1)
        )

        #expect(await persistence.load() == .unsupportedVersion(NotificationFeedHistorySnapshot.currentVersion + 1))
        #expect(try Data(contentsOf: fileURL) == data)
        let quarantinedURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("history.json.oversized")
        }
        #expect(quarantinedURLs.isEmpty)
    }

    @Test func oversizedCurrentSnapshotReadsMetadataFromTailAndWritesRecover() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-current-tail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let id = UUID().uuidString
        let workspaceID = UUID().uuidString
        let body = String(repeating: "x", count: 70_000)
        let rawJSON = """
        {"notifications":[{"body":"\(body)","createdAt":0,"id":"\(id)","isRead":false,"retargetsToLiveSurfaceOwner":false,"subtitle":"Agent","tabId":"\(workspaceID)","title":"Current tail"}],"revision":21,"version":\(NotificationFeedHistorySnapshot.currentVersion)}
        """
        let data = Data(rawJSON.utf8)
        try data.write(to: fileURL, options: .atomic)
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: UInt64(data.count - 1)
        )

        let outcome = await persistence.load()
        guard case .loaded(let loaded) = outcome else {
            Issue.record("Expected oversized current-version history to recover from tail metadata")
            return
        }
        #expect(loaded.revision == 21)
        let loadedRecord = try #require(loaded.notifications.first)
        #expect(loadedRecord.title == "Current tail")
        #expect(loadedRecord.body.utf8.count == NotificationFeedHistoryRecord.historyBodyByteLimit)
        let migrationQuarantines = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("history.json.oversized")
        }
        #expect(migrationQuarantines.isEmpty)
        await persistence.persist(NotificationFeedHistorySnapshot(
            revision: 22,
            notifications: loaded.notifications
        ))
        let recovered = try JSONDecoder().decode(
            NotificationFeedHistorySnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(recovered.revision == 22)
        #expect(recovered.notifications.map(\.title) == ["Current tail"])
    }

    @Test func oversizedCurrentSnapshotMigrationScanBudgetRecoversWritableSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-scan-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let id = UUID().uuidString
        let workspaceID = UUID().uuidString
        let body = String(repeating: "x", count: 70_000)
        let rawJSON = """
        {"notifications":[{"body":"\(body)","createdAt":0,"id":"\(id)","isRead":false,"retargetsToLiveSurfaceOwner":false,"subtitle":"Agent","tabId":"\(workspaceID)","title":"Budget"}],"revision":22,"version":\(NotificationFeedHistorySnapshot.currentVersion)}
        """
        let data = Data(rawJSON.utf8)
        try data.write(to: fileURL, options: .atomic)
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: UInt64(data.count - 1),
            oversizedSnapshotMigrationScanByteLimit: 128
        )

        #expect(await persistence.load() == .loaded(NotificationFeedHistorySnapshot(
            revision: 22,
            notifications: []
        )))
        let recovered = try JSONDecoder().decode(
            NotificationFeedHistorySnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(recovered.revision == 22)
        #expect(recovered.notifications.isEmpty)
        let migrationQuarantines = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("history.json.oversized")
        }
        let backupURL = try #require(migrationQuarantines.first)
        #expect(migrationQuarantines.count == 1)
        #expect(try Data(contentsOf: backupURL) == data)

        let persisted = NotificationFeedHistoryRecord(notification: notification(
            workspaceID: UUID(),
            title: "Recovered",
            date: Date(timeIntervalSince1970: 1),
            isRead: false
        ))
        await persistence.persist(NotificationFeedHistorySnapshot(
            revision: 23,
            notifications: [persisted]
        ))
        let verifier = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3
        )
        let verified = await verifier.load()
        guard case .loaded(let verifiedSnapshot) = verified else {
            Issue.record("Expected recovered persisted snapshot, got \(verified)")
            return
        }
        #expect(verifiedSnapshot.revision == 23)
        #expect(verifiedSnapshot.notifications.map(\.title) == ["Recovered"])
    }

    @Test func oversizedCurrentSnapshotMigrationScanBudgetPreservesRecoveredPrefix() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-scan-prefix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let firstWorkspaceID = UUID().uuidString
        let secondWorkspaceID = UUID().uuidString
        let largeBody = String(repeating: "x", count: 140_000)
        let rawJSON = """
        {"notifications":[{"body":"Prefix body","createdAt":3,"id":"\(firstID)","isRead":false,"retargetsToLiveSurfaceOwner":false,"subtitle":"Agent","tabId":"\(firstWorkspaceID)","title":"Prefix"},{"body":"\(largeBody)","createdAt":2,"id":"\(secondID)","isRead":false,"retargetsToLiveSurfaceOwner":false,"subtitle":"Agent","tabId":"\(secondWorkspaceID)","title":"Tail"}],"revision":33,"version":\(NotificationFeedHistorySnapshot.currentVersion)}
        """
        let data = Data(rawJSON.utf8)
        try data.write(to: fileURL, options: .atomic)
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: UInt64(data.count - 1),
            oversizedSnapshotMigrationScanByteLimit: 70_000
        )

        let outcome = await persistence.load()
        guard case .loaded(let snapshot) = outcome else {
            Issue.record("Expected recovered prefix snapshot, got \(outcome)")
            return
        }
        #expect(snapshot.revision == 33)
        #expect(snapshot.notifications.map(\.title) == ["Prefix"])
        let recovered = try JSONDecoder().decode(
            NotificationFeedHistorySnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(recovered.notifications.map(\.title) == ["Prefix"])
        let migrationQuarantines = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("history.json.oversized")
        }
        let backupURL = try #require(migrationQuarantines.first)
        #expect(migrationQuarantines.count == 1)
        #expect(try Data(contentsOf: backupURL) == data)
    }

    @Test func oversizedCurrentSnapshotScannerCapsEscapedTopLevelKeyBytes() throws {
        var scanner = NotificationFeedHistoryOversizedCurrentSnapshotRecordScanner(
            maxRecordBytes: 1_024
        )
        let keepScanning: (Data) throws -> Bool = { _ in true }

        #expect(try scanner.consume(Data("{\"".utf8), onRecord: keepScanning))
        #expect(try scanner.consume(
            Data(String(repeating: "\\\"", count: 512).utf8),
            onRecord: keepScanning
        ))
        #expect(scanner.topLevelKeyBufferByteCountForTesting == 0)
    }

    @Test func oversizedHistoryMetadataIntegerOverflowFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let data = Data(
            #"{"notifications":[],"revision":999999999999999999999999999999999999,"version":1}"#.utf8
        )
        try data.write(to: fileURL, options: .atomic)
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: UInt64(data.count - 1)
        )

        #expect(await persistence.load() == .corrupt)
        #expect(try Data(contentsOf: fileURL) == data)
    }

    @Test func missingCanonicalHistoryRestoresNewestQuarantineBackup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-orphaned-quarantine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let backupURL = directory.appendingPathComponent(
            "history.json.oversized-latest.quarantine",
            isDirectory: false
        )
        let workspaceID = UUID()
        let record = NotificationFeedHistoryRecord(notification: notification(
            workspaceID: workspaceID,
            title: "Restored backup",
            date: Date(timeIntervalSince1970: 1_660),
            isRead: false
        ))
        try write(
            NotificationFeedHistorySnapshot(
                revision: 16,
                notifications: [record]
            ),
            to: backupURL,
            sortedKeys: true
        )
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3
        )

        let outcome = await persistence.load()
        guard case .loaded(let loaded) = outcome else {
            Issue.record("Expected missing canonical history to restore backup")
            return
        }
        #expect(loaded.revision == 16)
        #expect(loaded.notifications.map(\.title) == ["Restored backup"])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test func persistFitsSnapshotToLoadBudgetBeforeWriting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-feed-persist-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let workspaceID = UUID()
        let largeRecord = NotificationFeedHistoryRecord(notification: notification(
            workspaceID: workspaceID,
            title: String(repeating: "t", count: 10_000),
            body: String(repeating: "b", count: 10_000),
            date: Date(timeIntervalSince1970: 1_700),
            isRead: false
        ))
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: 512
        )

        await persistence.persist(NotificationFeedHistorySnapshot(
            revision: 1,
            notifications: [largeRecord]
        ))

        let verifier = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: .default,
            readRetentionLimit: 10,
            totalRetentionLimit: 3,
            maxSnapshotBytes: 512
        )
        let outcome = await verifier.load()
        guard case .loaded(let loaded) = outcome else {
            Issue.record("Expected persisted notification feed to stay loadable")
            return
        }
        #expect(loaded.revision == 1)
        #expect(loaded.notifications.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = try #require(attributes[.size] as? NSNumber)
        #expect(size.uint64Value <= 512)
    }

    @Test func feedListResponseStaysWithinMobileFrameLimit() async throws {
        let store = TerminalNotificationStore.shared
        let workspaceID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_800)
        let body = String(repeating: "x", count: 8_192)
        let notifications = (0..<NotificationFeedHistoryStore.totalRetentionLimit).map { offset in
            notification(
                workspaceID: workspaceID,
                title: "Frame budget \(offset)",
                body: body,
                date: baseDate.addingTimeInterval(Double(offset)),
                isRead: false
            )
        }
        store.replaceNotificationsForTesting(notifications)
        defer { store.replaceNotificationsForTesting([]) }

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "feed-list",
                method: "notification.feed.list",
                params: [:],
                auth: nil
            )
        )
        let encoded = MobileHostRPCEnvelope.encodeResponse(id: "feed-list", result: response)
        #expect(encoded.count <= MobileSyncFrameCodec.defaultMaximumFrameByteCount)
        let payload = try responsePayload(response)
        let rows = try #require(payload["notifications"] as? [[String: Any]])
        #expect(rows.count == notifications.count)
        #expect(rows.first?["title"] as? String == "Frame budget \(notifications.count - 1)")
        #expect((rows.first?["body"] as? String)?.utf8.count == NotificationFeedHistoryRecord.historyBodyByteLimit)
    }

    @Test func feedListBoundsOversizedLeadingRowWithoutDroppingFeed() async throws {
        let store = TerminalNotificationStore.shared
        let workspaceID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_900)
        let older = notification(
            workspaceID: workspaceID,
            title: "Older valid",
            body: "small",
            date: baseDate,
            isRead: false
        )
        let newest = notification(
            workspaceID: workspaceID,
            title: "Huge newest",
            body: String(
                repeating: "x",
                count: MobileSyncFrameCodec.defaultMaximumFrameByteCount + 1_024
            ),
            date: baseDate.addingTimeInterval(1),
            isRead: false
        )
        store.replaceNotificationsForTesting([older, newest])
        defer { store.replaceNotificationsForTesting([]) }

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "feed-huge-row",
                method: "notification.feed.list",
                params: [:],
                auth: nil
            )
        )
        let encoded = MobileHostRPCEnvelope.encodeResponse(id: "feed-huge-row", result: response)
        #expect(encoded.count <= MobileSyncFrameCodec.defaultMaximumFrameByteCount)
        let payload = try responsePayload(response)
        let rows = try #require(payload["notifications"] as? [[String: Any]])
        #expect(rows.map { $0["title"] as? String } == ["Huge newest", "Older valid"])
        let returnedBody = try #require(rows.first?["body"] as? String)
        #expect(returnedBody.utf8.count <= 4_096)
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
        body: String = "Body",
        date: Date,
        isRead: Bool
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: title,
            subtitle: "Agent",
            body: body,
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
        to fileURL: URL,
        sortedKeys: Bool = false
    ) throws -> Data {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        if sortedKeys {
            encoder.outputFormatting = [.sortedKeys]
        }
        let data = try encoder.encode(snapshot)
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
