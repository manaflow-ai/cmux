#if DEBUG
import Bonsplit
import CMUXDebugLog
import Foundation
import XCTest

/// Both debug-log entry points — `logDebugEvent` (what `cmuxDebugLog` wraps)
/// and bonsplit's `dlog` — append to the same log file. These tests pump both
/// paths from several threads at once and then read the file back. Every line
/// that reaches the file must be intact (no interleaved fragments), the
/// sequence numbers in the line prefix must be strictly increasing in file
/// order, and any line that never reached the file must be covered by a
/// `log.dropped N lines` marker. Before the writers shared one serialized
/// append path, each path opened its own FileHandle per line and did
/// seekToEnd()+write, so concurrent lines clobbered each other and landed out
/// of order — which once sent a live-capture investigation chasing timestamps
/// that were merely misfiled.
final class DebugEventLogSerializedAppendTests: XCTestCase {
    private static let logPath = CMUXDebugLog.DebugEventLog.currentLogPath()

    /// Keep in sync with `DebugEventLog.maxPersistedLinesPerWindow` in
    /// Packages/macOS/CMUXDebugLog. The value is duplicated here on purpose:
    /// the test must compile against builds that predate the constant.
    private static let maxPersistedLinesPerWindow = 2000

    private static let sequencedLinePattern = try! NSRegularExpression(
        pattern: "^\\d{2}:\\d{2}:\\d{2}\\.\\d{3} #(\\d+) "
    )
    private static let droppedMarkerPattern = try! NSRegularExpression(
        pattern: "log\\.dropped (\\d+) lines$"
    )

    override func setUp() {
        super.setUp()
        // Let the test-host app's launch logging drain and any rate-limit
        // window from a previous test expire, then start from an empty file.
        Thread.sleep(forTimeInterval: 1.1)
        truncateLogFile()
    }

    // MARK: - Tests

    func testConcurrentWritersKeepLinesIntactOrderedAndAccounted() throws {
        let marker = "seqrace\(UUID().uuidString.prefix(8).lowercased())"
        let threadsPerPath = 4
        let linesPerThread = 100
        let expected = threadsPerPath * linesPerThread * 2

        let start = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        for thread in 0..<threadsPerPath {
            done.enter()
            Thread.detachNewThread {
                start.wait()
                for index in 0..<linesPerThread {
                    let pad = String(repeating: "x", count: 1 + (index % 40))
                    logDebugEvent("\(marker).a t=\(thread) i=\(index) p=\(pad) end")
                }
                done.leave()
            }
            done.enter()
            Thread.detachNewThread {
                start.wait()
                for index in 0..<linesPerThread {
                    let pad = String(repeating: "y", count: 1 + (index % 40))
                    dlog("\(marker).b t=\(thread) i=\(index) p=\(pad) end")
                }
                done.leave()
            }
        }
        for _ in 0..<(threadsPerPath * 2) { start.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success, "writer threads did not finish")

        drainWriters(marker: marker)

        let lines = try logLines()
        let markerLines = lines.filter { $0.contains("\(marker).") }

        // (a) Every line mentioning this run's marker must be one whole,
        // well-formed line. A fragment here means two writers interleaved.
        let payloadPattern = try NSRegularExpression(
            pattern: "^\\d{2}:\\d{2}:\\d{2}\\.\\d{3} (#\\d+ )?\(marker)\\.(a|b) t=\\d+ i=\\d+ p=[xy]+ end$"
        )
        let sentinelPattern = try NSRegularExpression(
            pattern: "^\\d{2}:\\d{2}:\\d{2}\\.\\d{3} (#\\d+ )?\(marker)\\.sentinel\\.(a|b)$"
        )
        var intactPayloadLines: [String] = []
        for line in markerLines {
            if payloadPattern.wholeMatch(line) {
                intactPayloadLines.append(line)
            } else if !sentinelPattern.wholeMatch(line) {
                XCTFail("fragmented or malformed log line: \(line.debugDescription)")
            }
        }

        // (b) Sequence numbers must be strictly increasing in file order, and
        // every intact payload line must carry one.
        assertSequencesStrictlyIncreasing(in: lines)
        let sequencedPayloadCount = intactPayloadLines.filter { Self.sequencedLinePattern.wholeMatchAtStart($0) }.count
        XCTAssertEqual(
            sequencedPayloadCount, intactPayloadLines.count,
            "every persisted line must carry a monotonic #<seq> prefix so reordering is detectable in captures"
        )

        // (c) No silent loss: every line we sent is either intact in the file
        // or accounted for by an explicit dropped-lines marker.
        let droppedTotal = droppedLineTotal(in: lines)
        XCTAssertGreaterThanOrEqual(
            intactPayloadLines.count + droppedTotal, expected,
            "lost \(expected - intactPayloadLines.count) of \(expected) lines with only \(droppedTotal) accounted for by log.dropped markers"
        )
    }

    func testFloodIsBoundedAndAccountedWithDroppedMarker() throws {
        let marker = "logflood\(UUID().uuidString.prefix(8).lowercased())"
        // The burst can straddle one window boundary (the host app may have
        // opened the current window just before the burst starts), so size it
        // above two windows' budget to guarantee drops.
        let total = 2 * Self.maxPersistedLinesPerWindow + 1000

        for index in 0..<total {
            logDebugEvent("\(marker).f i=\(index) end")
        }
        // Let the rate-limit window expire so the next line flushes the
        // dropped-lines marker, then drain.
        Thread.sleep(forTimeInterval: 1.1)
        drainWriters(marker: marker)

        let lines = try logLines()
        let persisted = lines.filter { $0.contains("\(marker).f ") }.count
        let droppedTotal = droppedLineTotal(in: lines)

        // A flood must not translate into unbounded disk writes...
        XCTAssertLessThan(
            persisted, total,
            "a \(total)-line burst was written to disk in full; storms must be bounded"
        )
        // ...but nothing may go missing without a marker accounting for it.
        XCTAssertGreaterThanOrEqual(
            persisted + droppedTotal, total,
            "flood dropped \(total - persisted) lines but markers only account for \(droppedTotal)"
        )
        assertSequencesStrictlyIncreasing(in: lines)
    }

    // MARK: - Helpers

    private func truncateLogFile() {
        let path = Self.logPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        // Truncate in place (same inode): the writer may hold an open append
        // handle, and replacing the file would detach it from what we read.
        if let handle = FileHandle(forWritingAtPath: path) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        }
    }

    /// Push one sentinel through each public path and wait until both appear
    /// in the file, which means both writer queues drained everything queued
    /// before them.
    private func drainWriters(marker: String) {
        logDebugEvent("\(marker).sentinel.a")
        dlog("\(marker).sentinel.b")
        let needles = ["\(marker).sentinel.a", "\(marker).sentinel.b"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let content = try? String(contentsOfFile: Self.logPath, encoding: .utf8),
               needles.allSatisfy(content.contains) {
                // On a broken build the sentinels can land while racing
                // writes are still in flight; give them a moment.
                Thread.sleep(forTimeInterval: 0.3)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("writer queues did not drain sentinels to \(Self.logPath) within 10s")
    }

    private func logLines() throws -> [String] {
        let content = try String(contentsOfFile: Self.logPath, encoding: .utf8)
        return content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func assertSequencesStrictlyIncreasing(in lines: [String]) {
        var previous: UInt64?
        for line in lines {
            guard let sequence = Self.sequencedLinePattern.firstCaptureUInt64(in: line) else { continue }
            if let previous {
                XCTAssertGreaterThan(
                    sequence, previous,
                    "sequence numbers out of order (#\(previous) then #\(sequence)); lines landed out of order: \(line.debugDescription)"
                )
            }
            previous = sequence
        }
    }

    private func droppedLineTotal(in lines: [String]) -> Int {
        lines.reduce(0) { total, line in
            total + (Self.droppedMarkerPattern.firstCaptureUInt64(in: line).map(Int.init) ?? 0)
        }
    }
}

private extension NSRegularExpression {
    func wholeMatch(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return firstMatch(in: string, range: range)?.range == range
    }

    func wholeMatchAtStart(_ string: String) -> Bool {
        firstMatch(in: string, range: NSRange(string.startIndex..., in: string))?.range.location == 0
    }

    func firstCaptureUInt64(in string: String) -> UInt64? {
        let range = NSRange(string.startIndex..., in: string)
        guard let match = firstMatch(in: string, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: string) else { return nil }
        return UInt64(string[captureRange])
    }
}
#endif
