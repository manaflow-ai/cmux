import Foundation

/// Measures the real writer, using the same synchronous write spy as the regression suite.
@main
struct EventLogWriteBenchmark {
    static func main() throws {
        let samples = Int(CommandLine.arguments[1]) ?? 7
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for count in [32, 256, 1_024, 1_152] {
            try run(count: count, crossing: false, samples: samples, root: root)
        }
        try run(count: 256, crossing: true, samples: samples, root: root)
    }

    private static func run(count: Int, crossing: Bool, samples: Int, root: URL) throws {
        let limit = 16 * 1024 * 1024
        let lines = (0..<count).map { index in
            "{\"seq\":\(index),\"name\":\"agent.hook.PreToolUse\",\"payload\":\"\(String(repeating: "x", count: 900))\"}"
        }
        let expectedLines = Array(lines.suffix(1_024))
        let expected = Data((expectedLines.joined(separator: "\n") + "\n").utf8)
        let prefix = Data((expectedLines.prefix(128).joined(separator: "\n") + "\n").utf8)
        var observations: [[String: Any]] = []
        for iteration in 0...samples {
            let directory = root.appendingPathComponent("\(count)-\(crossing)-\(iteration)")
            let url = directory.appendingPathComponent("events.jsonl")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var seed = Data()
            if crossing {
                let padding = String(repeating: "x", count: limit - prefix.count - 12)
                seed = Data(("{\"seed\":\"" + padding + "\"}\n").utf8)
                try seed.write(to: url)
            }
            let spy = CmuxEventLogWriteSpy()
            let writer = CmuxEventLogWriter(
                eventLogURL: url,
                maxEventLogBytes: UInt64(limit),
                maxPendingLines: 1_024,
                writeData: { try spy.write($0, data: $1) }
            )
            writer.setFlushSuspendedForTesting(true)
            lines.forEach(writer.enqueue)
            let backlog = writer.backlogSnapshotForTesting()
            precondition(backlog.pending == expectedLines.count && backlog.dropped == max(0, count - 1_024))
            let start = DispatchTime.now().uptimeNanoseconds
            writer.setFlushSuspendedForTesting(false)
            writer.flushForTesting()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

            // Proof is outside the timer: exact bytes, complete JSON records, FIFO, rotation, and drops.
            let current = try Data(contentsOf: url)
            if crossing {
                let rotated = try Data(contentsOf: url.appendingPathExtension("1"))
                precondition(rotated == seed + prefix && rotated.count == limit)
                precondition(current == expected.dropFirst(prefix.count))
            } else {
                precondition(current == expected && current.count <= limit)
                precondition(!FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
            }
            precondition(!spy.wroteOnMainThread)
            precondition(spy.writeSizes.reduce(0, +) == expected.count)
            precondition(writer.backlogSnapshotForTesting().pending == 0)
            precondition(writer.backlogSnapshotForTesting().dropped == 0)
            for (offset, record) in expected.split(separator: 0x0a).enumerated() {
                let json = try JSONSerialization.jsonObject(with: Data(record)) as? [String: Any]
                precondition(json?["seq"] as? Int == max(0, count - 1_024) + offset)
            }
            if iteration > 0 { // Warm runtime once; each measured flush still uses a fresh file.
                observations.append([
                    "write_calls": spy.writeSizes.count, "flush_ms": elapsed,
                    "dropped_lines": backlog.dropped, "bytes_written": expected.count
                ])
            }
        }
        let result: [String: Any] = [
            "submitted_lines": count, "crossing_16_mib": crossing,
            "behavior_checks": "passed", "samples": observations
        ]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
    }
}
