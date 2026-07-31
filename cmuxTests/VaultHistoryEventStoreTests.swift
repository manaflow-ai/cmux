import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct VaultHistoryEventStoreTests {
    private func makeTempFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.jsonl")
    }

    private func event(
        id: String,
        secondsAgo: TimeInterval,
        kind: VaultHistoryEventKind = .workspaceCreated,
        title: String = "ws",
        reference: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> VaultHistoryEvent {
        VaultHistoryEvent(
            id: id,
            timestamp: reference.addingTimeInterval(-secondsAgo),
            kind: kind,
            title: title,
            subject: VaultHistorySubject(workspaceId: UUID())
        )
    }

    @Test func appendedEventsRoundTripThroughDisk() async throws {
        let fileURL = try makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = VaultHistoryEventStore(fileURL: fileURL)
        let created = VaultHistoryEvent(
            id: "e1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .workspaceRenamed,
            title: "renamed",
            previousTitle: "original",
            subject: VaultHistorySubject(workspaceId: UUID(), directory: "/tmp/project")
        )
        let closed = VaultHistoryEvent(
            id: "e2",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            kind: .windowClosed,
            title: "win",
            workspaceCount: 3,
            subject: VaultHistorySubject(windowId: UUID())
        )
        await store.append(created)
        await store.append(closed)

        // A fresh store instance must see the same events after "restart".
        let reloaded = VaultHistoryEventStore(fileURL: fileURL)
        let events = await reloaded.recentEvents()
        #expect(events.count == 2)
        #expect(events.first?.id == "e2")
        #expect(events.first?.workspaceCount == 3)
        #expect(events.last?.id == "e1")
        #expect(events.last?.previousTitle == "original")
        #expect(events.last?.subject.directory == "/tmp/project")
        #expect(events.last?.kind == .workspaceRenamed)
    }

    @Test func recentEventsReturnsNewestFirstAndHonorsLimit() async throws {
        let store = VaultHistoryEventStore(fileURL: nil)
        await store.append(event(id: "old", secondsAgo: 300))
        await store.append(event(id: "new", secondsAgo: 10))
        await store.append(event(id: "mid", secondsAgo: 100))

        let all = await store.recentEvents()
        #expect(all.map(\.id) == ["new", "mid", "old"])

        let limited = await store.recentEvents(limit: 2)
        #expect(limited.map(\.id) == ["new", "mid"])
    }

    @Test func retentionCompactsFileAndKeepsNewestEvents() async throws {
        let fileURL = try makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        // Tiny budgets: every append overflows maxFileBytes, so the file is
        // repeatedly compacted down to the newest maxStoredEvents events.
        let retention = VaultHistoryRetentionPolicy(
            maxStoredEvents: 5,
            maxFileBytes: 1024,
            maxLoadBytes: 64 * 1024
        )
        let store = VaultHistoryEventStore(fileURL: fileURL, retention: retention)
        for index in 0..<50 {
            await store.append(event(id: "e\(index)", secondsAgo: TimeInterval(1000 - index)))
        }

        let events = await store.recentEvents()
        #expect(events.count == 5)
        #expect(events.map(\.id) == ["e49", "e48", "e47", "e46", "e45"])

        let fileSize = try #require(
            try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int
        )
        #expect(fileSize <= 1024 + 512)

        // Restarting on the compacted file sees only the retained tail.
        let reloaded = VaultHistoryEventStore(fileURL: fileURL, retention: retention)
        let reloadedEvents = await reloaded.recentEvents()
        #expect(reloadedEvents.map(\.id) == ["e49", "e48", "e47", "e46", "e45"])
    }

    @Test func loadIsBoundedAndSkipsPartialLeadingLine() async throws {
        let fileURL = try makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        // Write with generous limits, reload with a small load budget: only
        // the newest events that fit inside maxLoadBytes come back, and the
        // partial leading line inside the tail window is skipped cleanly.
        let writer = VaultHistoryEventStore(fileURL: fileURL)
        for index in 0..<200 {
            await writer.append(event(id: "e\(index)", secondsAgo: TimeInterval(10_000 - index)))
        }

        let reader = VaultHistoryEventStore(
            fileURL: fileURL,
            retention: VaultHistoryRetentionPolicy(
                maxStoredEvents: 1000,
                maxFileBytes: 64 * 1024 * 1024,
                maxLoadBytes: 4096
            )
        )
        let events = await reader.recentEvents()
        #expect(!events.isEmpty)
        #expect(events.count < 200)
        // The newest event is always inside the tail window.
        #expect(events.first?.id == "e199")
        // Every decoded event is intact (a torn first line would decode to
        // nothing rather than a corrupt event).
        #expect(events.allSatisfy { $0.title == "ws" })
    }

    @Test func corruptLinesAreSkippedOnLoad() async throws {
        let fileURL = try makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let writer = VaultHistoryEventStore(fileURL: fileURL)
        await writer.append(event(id: "good", secondsAgo: 60))

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json at all\n".utf8))
        try handle.close()

        let reloaded = VaultHistoryEventStore(fileURL: fileURL)
        let events = await reloaded.recentEvents()
        #expect(events.map(\.id) == ["good"])
    }
}
