import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for `GhosttyApp.logBackground`: the background log must
/// not perform its file I/O on the calling (often main) thread, and must still
/// emit lines in submission order and flush on demand. See
/// https://github.com/manaflow-ai/cmux/issues/5833.
final class BackgroundLogWriterTests: XCTestCase {
    private final class RecordingSink: BackgroundLogSink {
        private let lock = NSLock()
        private(set) var lines: [String] = []
        private(set) var observedMainThreadWrite = false

        func write(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            if Thread.isMainThread {
                observedMainThreadWrite = true
            }
            lines.append(line)
        }

        var snapshot: (lines: [String], mainThread: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (lines, observedMainThreadWrite)
        }
    }

    private func sequenceNumber(from line: String) -> Int? {
        guard let range = line.range(of: "seq=") else { return nil }
        let tail = line[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    func testWritesHappenOffTheCallingThreadInSubmissionOrder() {
        let sink = RecordingSink()
        let writer = BackgroundLogWriter(sink: sink)

        // Called from the test's main thread, mirroring logBackground being
        // invoked inside SwiftUI view updates.
        XCTAssertTrue(Thread.isMainThread)
        let count = 200
        for index in 0..<count {
            writer.append("entry-\(index)")
        }
        writer.flush()

        let snapshot = sink.snapshot
        XCTAssertFalse(
            snapshot.mainThread,
            "Background log writes must run off the calling (main) thread"
        )
        XCTAssertEqual(snapshot.lines.count, count, "flush() must drain every enqueued line")

        let sequences = snapshot.lines.compactMap(sequenceNumber(from:))
        XCTAssertEqual(
            sequences,
            Array(1...count),
            "Lines must be written in submission order with a monotonic sequence"
        )

        for (index, line) in snapshot.lines.enumerated() {
            XCTAssertTrue(
                line.contains("entry-\(index)"),
                "Message payload must be preserved in order"
            )
            XCTAssertTrue(
                line.contains("thread=main"),
                "The originating (calling) thread label must be captured at call time"
            )
        }
    }

    func testFileSinkAppendsAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bg-log-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("bg-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = BackgroundLogWriter(url: url)
        writer.append("first")
        writer.append("second")
        writer.flush()

        let firstContents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(firstContents.contains("first"))
        XCTAssertTrue(firstContents.contains("second"))

        // A second writer for the same path must append, not truncate.
        let appendingWriter = BackgroundLogWriter(url: url)
        appendingWriter.append("third")
        appendingWriter.flush()

        let finalContents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(finalContents.contains("first"))
        XCTAssertTrue(finalContents.contains("third"))
    }
}
