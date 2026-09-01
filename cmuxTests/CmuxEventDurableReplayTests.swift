import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxEventDurableReplayTests {
    @Test
    func reconnectAcrossRestartReplaysEventsBeyondMemoryWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-durable-replay-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstBus = CmuxEventBus(
            retainedEventLimit: 1,
            eventLogURL: logURL
        )
        firstBus.publish(name: "first", category: "test", source: "first-process")
        let cursor = firstBus.latestSequence
        firstBus.publish(name: "second", category: "test", source: "first-process")
        firstBus.flushEventLogForTesting()

        let firstEvents = firstBus.retainedSnapshot()
        let firstBootID = try #require(firstEvents.last?["boot_id"] as? String)

        let secondBus = CmuxEventBus(
            retainedEventLimit: 1,
            eventLogURL: logURL
        )
        secondBus.publish(name: "third", category: "test", source: "second-process")
        secondBus.flushEventLogForTesting()

        let snapshot = secondBus.subscribe(afterSequence: cursor, names: [], categories: [])
        defer { secondBus.unsubscribe(snapshot.subscription) }

        let replaySequences = snapshot.replay.compactMap { CmuxEventBus.int64($0["seq"]) }
        #expect(replaySequences == [2, 3])
        #expect(snapshot.replay.compactMap { $0["name"] as? String } == ["second", "third"])
        #expect(snapshot.replay.first?["boot_id"] as? String == firstBootID)
        #expect(snapshot.replay.last?["boot_id"] as? String != firstBootID)
        #expect(secondBus.latestSequence == 3)

        let resume = try #require(snapshot.ack["resume"] as? [String: Any])
        #expect(resume["gap"] as? Bool == false)
        #expect(CmuxEventBus.int64(resume["latest_seq"]) == 3)
    }

    @Test
    func missingDurableSequenceIsReportedAlongsideReplayTail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-durable-gap-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstBus = CmuxEventBus(eventLogURL: logURL)
        firstBus.publish(name: "one", category: "test", source: "first-process")
        firstBus.publish(name: "two", category: "test", source: "first-process")
        firstBus.publish(name: "three", category: "test", source: "first-process")
        firstBus.flushEventLogForTesting()

        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        try lines[0...0].joined(separator: "\n")
            .appending("\n")
            .appending(String(lines[2]))
            .appending("\n")
            .write(to: logURL, atomically: true, encoding: .utf8)

        let secondBus = CmuxEventBus(eventLogURL: logURL)
        let snapshot = secondBus.subscribe(afterSequence: 1, names: [], categories: [])
        defer { secondBus.unsubscribe(snapshot.subscription) }

        #expect(snapshot.replay.compactMap { $0["name"] as? String } == ["three"])
        let resume = try #require(snapshot.ack["resume"] as? [String: Any])
        #expect(resume["gap"] as? Bool == true)
        #expect(resume["gap_reason"] as? String == "durable event log has a sequence gap")
    }

    @Test
    func subscriptionUsesCachedPersistedSnapshotInsteadOfReadingTheLogAgain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-replay-cache-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let bus = CmuxEventBus(retainedEventLimit: 1, eventLogURL: logURL)
        bus.publish(name: "first", category: "test", source: "writer")
        bus.publish(name: "second", category: "test", source: "writer")
        bus.flushEventLogForTesting()

        // A subscription must use the cached snapshot. If it falls back to a
        // synchronous disk read, removing the file makes the replay disappear
        // and puts the socket worker back on the expensive path.
        try FileManager.default.removeItem(at: logURL)

        let snapshot = bus.subscribe(afterSequence: 0, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        #expect(snapshot.replay.compactMap { $0["name"] as? String } == ["first", "second"])
    }
}
