import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SessionIndexJSONLStreamTests: XCTestCase {
    func testJSONLStreamHonorsMaxLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-jsonl-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.jsonl", isDirectory: false)
        let lines = (0..<10).map { #"{"index":\#($0)}"# }.joined(separator: "\n") + "\n"
        try lines.write(to: historyURL, atomically: true, encoding: .utf8)

        var visited: [Int] = []
        SessionIndexStore.forEachJSONLine(url: historyURL, maxBytes: Int.max, maxLines: 3) { object in
            if let index = object["index"] as? Int {
                visited.append(index)
            }
            return false
        }

        XCTAssertEqual(visited, [0, 1, 2])
    }
}
