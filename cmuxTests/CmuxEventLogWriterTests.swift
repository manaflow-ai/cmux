import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Durable event-log batch writes", .serialized)
struct CmuxEventLogWriterTests {
    private let logLimit = 16 * 1024 * 1024

    @Test(arguments: [0, 1, 32, 256, 1_024])
    func burstUsesOneWriteAndPreservesJSONL(count: Int) throws {
        let lines = (0..<count).map { jsonLine(index: $0) }
        let (writer, url, spy) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        flush(lines, with: writer)

        #expect(spy.writeSizes.count == (count == 0 ? 0 : 1))
        #expect(!spy.wroteOnMainThread)
        if count > 0 {
            let stored = try Data(contentsOf: url)
            #expect(stored == jsonl(lines))
            try expectJSONRecords(stored, count: count)
        } else {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(writer.backlogSnapshotForTesting().pending == 0)
        #expect(writer.backlogSnapshotForTesting().dropped == 0)
    }

    @Test(arguments: [0, 1])
    func batchAtOrBelowSixteenMiBLimitDoesNotRotate(spareBytes: Int) throws {
        let lines = (0..<32).map { jsonLine(index: $0) }
        let (writer, url, spy) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seed = try seedLog(url, bytes: logLimit - jsonl(lines).count - spareBytes)

        flush(lines, with: writer)

        #expect(spy.writeSizes == [jsonl(lines).count])
        #expect(try Data(contentsOf: url) == seed + jsonl(lines))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
    }

    @Test
    func batchCrossingSixteenMiBLimitWritesOncePerFile() throws {
        let lines = (0..<32).map { jsonLine(index: $0) }
        let prefix = jsonl(Array(lines.prefix(13)))
        let suffix = jsonl(Array(lines.dropFirst(13)))
        let (writer, url, spy) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seed = try seedLog(url, bytes: logLimit - prefix.count)

        flush(lines, with: writer)

        #expect(spy.writeSizes == [prefix.count, suffix.count])
        #expect(try Data(contentsOf: url.appendingPathExtension("1")) == seed + prefix)
        #expect(try Data(contentsOf: url) == suffix)
        try expectJSONRecords(suffix, count: 19)
    }

    @Test
    func multipleRotationsRetainTheSameLastTwoFiles() throws {
        let lines = (0..<8).map { "{\"seq\":\($0)}" }
        let (writer, url, spy) = makeWriter(maxBytes: 30)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        flush(lines, with: writer)

        #expect(spy.writeSizes == [30, 30, 20])
        #expect(try Data(contentsOf: url.appendingPathExtension("1")) == jsonl(Array(lines[3..<6])))
        #expect(try Data(contentsOf: url) == jsonl(Array(lines[6..<8])))
    }

    @Test
    func utf8BytesAndNewlinesDetermineTheBoundary() throws {
        let lines = [#"{"text":"🌍"}"#, #"{"text":"é"}"#, #"{"seq":2}"#]
        let prefix = jsonl(Array(lines.prefix(2)))
        let (writer, url, spy) = makeWriter(maxBytes: UInt64(prefix.count))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        flush(lines, with: writer)

        #expect(spy.writeSizes == [prefix.count, jsonl([lines[2]]).count])
        #expect(try Data(contentsOf: url.appendingPathExtension("1")) == prefix)
        #expect(try Data(contentsOf: url) == jsonl([lines[2]]))
    }

    @Test
    func oversizedRecordKeepsExistingWholeRecordAndCleanupPolicy() throws {
        let oversized = jsonLine(index: 1)
        let seed = #"{"seq":0}"#
        let tail = #"{"seq":2}"#
        let (writer, url, spy) = makeWriter(maxBytes: 32)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        flush([seed, oversized], with: writer)
        #expect(try Data(contentsOf: url) == jsonl([oversized]))
        #expect(try Data(contentsOf: url.appendingPathExtension("1")) == jsonl([seed]))

        // The pre-existing policy discards an oversized active log on the next rotation.
        flush([tail], with: writer)
        #expect(spy.writeSizes == [jsonl([seed]).count, jsonl([oversized]).count, jsonl([tail]).count])
        #expect(try Data(contentsOf: url) == jsonl([tail]))
        #expect(try Data(contentsOf: url.appendingPathExtension("1")) == jsonl([seed]))
    }

    @Test
    func suspendedBurstKeepsNewestLinesAndDropAccounting() throws {
        let lines = (0..<1_152).map { jsonLine(index: $0) }
        let (writer, url, spy) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        lines.forEach(writer.enqueue)

        #expect(writer.backlogSnapshotForTesting().pending == 1_024)
        #expect(writer.backlogSnapshotForTesting().dropped == 128)
        writer.setFlushSuspendedForTesting(false)
        writer.flushForTesting()

        #expect(spy.writeSizes.count == 1)
        #expect(try Data(contentsOf: url) == jsonl(Array(lines.suffix(1_024))))
        #expect(writer.backlogSnapshotForTesting().pending == 0)
        #expect(writer.backlogSnapshotForTesting().dropped == 0)
    }

    @Test(arguments: [1, 2])
    func failedWriteStopsTheBatchAndNextFlushRecovers(failedCall: Int) throws {
        let lines = (0..<8).map { "{\"seq\":\($0)}" }
        let spy = CmuxEventLogWriteSpy(failedCall: failedCall)
        let (writer, url, _) = makeWriter(maxBytes: 30, spy: spy)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        flush(lines, with: writer)

        #expect(spy.writeSizes.count == failedCall)
        #expect(try Data(contentsOf: url).isEmpty)
        if failedCall == 2 {
            #expect(try Data(contentsOf: url.appendingPathExtension("1")) == jsonl(Array(lines.prefix(3))))
        } else {
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        }
        // As before, failed I/O is logged and abandoned, not retried or counted as queue drops.
        #expect(writer.backlogSnapshotForTesting().dropped == 0)
        flush([#"{"seq":9}"#], with: writer)
        #expect(try Data(contentsOf: url) == jsonl([#"{"seq":9}"#]))
    }

    private func makeWriter(
        maxBytes: UInt64 = 16 * 1024 * 1024,
        spy: CmuxEventLogWriteSpy = CmuxEventLogWriteSpy()
    ) -> (CmuxEventLogWriter, URL, CmuxEventLogWriteSpy) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-writer-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let writer = CmuxEventLogWriter(
            eventLogURL: url,
            maxEventLogBytes: maxBytes,
            maxPendingLines: 1_024,
            writeData: { try spy.write($0, data: $1) }
        )
        writer.setFlushSuspendedForTesting(true)
        return (writer, url, spy)
    }

    private func flush(_ lines: [String], with writer: CmuxEventLogWriter) {
        writer.setFlushSuspendedForTesting(true)
        lines.forEach(writer.enqueue)
        writer.setFlushSuspendedForTesting(false)
        writer.flushForTesting()
    }

    private func jsonLine(index: Int) -> String {
        "{\"seq\":\(index),\"name\":\"agent.hook.PreToolUse\",\"payload\":\"\(String(repeating: "x", count: 900))\"}"
    }

    private func jsonl(_ lines: [String]) -> Data {
        Data(lines.map { $0 + "\n" }.joined().utf8)
    }

    private func seedLog(_ url: URL, bytes: Int) throws -> Data {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(("{\"seed\":\"" + String(repeating: "x", count: bytes - 12) + "\"}\n").utf8)
        #expect(data.count == bytes)
        try data.write(to: url)
        return data
    }

    private func expectJSONRecords(_ data: Data, count: Int) throws {
        #expect(data.last == 0x0a)
        let records = data.split(separator: 0x0a)
        #expect(records.count == count)
        for record in records {
            #expect(try JSONSerialization.jsonObject(with: Data(record)) is [String: Any])
        }
    }
}
