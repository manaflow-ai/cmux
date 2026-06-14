import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SessionIndexJSONLStreamTests {
    @Test
    func testJSONLStreamHonorsMaxLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-jsonl-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.jsonl", isDirectory: false)
        let lines = (0..<10).map { #"{"index":\#($0)}"# }.joined(separator: "\n") + "\n"
        try lines.write(to: historyURL, atomically: true, encoding: .utf8)

        var visited: [Int] = []
        let summary = SessionIndexStore.forEachJSONLine(url: historyURL, maxBytes: Int.max, maxLines: 3) { object in
            if let index = object["index"] as? Int {
                visited.append(index)
            }
            return false
        }

        #expect(visited == [0, 1, 2])
        #expect(summary.linesVisited == 3)
        #expect(summary.stopReason == .maxLines)
    }

    @Test
    func testReverseJSONLStreamHonorsMaxLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-jsonl-reverse-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.jsonl", isDirectory: false)
        let lines = (0..<10).map { #"{"index":\#($0)}"# }.joined(separator: "\n") + "\n"
        try lines.write(to: historyURL, atomically: true, encoding: .utf8)

        var visited: [Int] = []
        let summary = SessionIndexStore.forEachJSONLine(
            url: historyURL,
            maxBytes: Int.max,
            maxLines: 3,
            direction: .reverse
        ) { object in
            if let index = object["index"] as? Int {
                visited.append(index)
            }
            return false
        }

        #expect(visited == [9, 8, 7])
        #expect(summary.linesVisited == 3)
        #expect(summary.stopReason == .maxLines)
    }

    @Test
    func testReverseJSONLStreamHonorsMaxBytes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-jsonl-byte-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.jsonl", isDirectory: false)
        let lines = (0..<30).map { index in
            #"{"index":\#(index),"padding":"\#(String(repeating: "x", count: 80))"}"#
        }.joined(separator: "\n") + "\n"
        try lines.write(to: historyURL, atomically: true, encoding: .utf8)

        var visited: [Int] = []
        let summary = SessionIndexStore.forEachJSONLine(
            url: historyURL,
            maxBytes: 512,
            direction: .reverse
        ) { object in
            if let index = object["index"] as? Int {
                visited.append(index)
            }
            return false
        }

        #expect(summary.bytesRead <= 512)
        #expect(summary.stopReason == .maxBytes)
        #expect(visited.first == 29)
        #expect(visited.elementsEqual(visited.sorted(by: >)))
        #expect(visited.count < 30)
    }

    @Test
    func testReverseJSONLStreamProcessesLineStartingAtByteBoundary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-jsonl-byte-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let records = (0..<5).map { #"{"index":\#($0)}"# }
        let historyURL = tempDir.appendingPathComponent("history.jsonl", isDirectory: false)
        try (records.joined(separator: "\n") + "\n").write(to: historyURL, atomically: true, encoding: .utf8)

        let byteWindow = Data((records[3] + "\n" + records[4] + "\n").utf8).count
        var visited: [Int] = []
        let summary = SessionIndexStore.forEachJSONLine(
            url: historyURL,
            maxBytes: byteWindow,
            direction: .reverse
        ) { object in
            if let index = object["index"] as? Int {
                visited.append(index)
            }
            return false
        }

        #expect(visited == [4, 3])
        #expect(summary.stopReason == .maxBytes)
    }

    @Test
    func testForwardJSONLStreamFlushesTrailingLineAtExactByteBudget() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-jsonl-forward-exact-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let records = [
            #"{"index":0}"#,
            #"{"index":1}"#
        ]
        let payload = records.joined(separator: "\n")
        let historyURL = tempDir.appendingPathComponent("history.jsonl", isDirectory: false)
        try payload.write(to: historyURL, atomically: true, encoding: .utf8)

        var visited: [Int] = []
        let summary = SessionIndexStore.forEachJSONLine(
            url: historyURL,
            maxBytes: Data(payload.utf8).count
        ) { object in
            if let index = object["index"] as? Int {
                visited.append(index)
            }
            return false
        }

        #expect(visited == [0, 1])
        #expect(summary.stopReason == .completed)
    }
}
