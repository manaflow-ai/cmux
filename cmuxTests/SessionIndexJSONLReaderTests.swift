import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SessionIndexJSONLReaderTests {
    @Test
    func tailReaderReturnsNewestRecordsWithoutReadingTheWholeHistory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let padding = String(repeating: "x", count: 512)
        let history = (0..<2_000).map { index in
            "{\"sessionId\":\"session-\(index)\",\"display\":\"\(padding)\"}"
        }.joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: url)

        var visitedSessionIDs: [String] = []
        let byteLimit = 64 * 1024
        let metrics = SessionIndexJSONLReader().fromTail(
            url: url,
            maxBytes: byteLimit
        ) { object in
            if let sessionID = object["sessionId"] as? String {
                visitedSessionIDs.append(sessionID)
            }
            return visitedSessionIDs.count == 30
        }

        #expect(visitedSessionIDs.first == "session-1999")
        #expect(visitedSessionIDs.count == 30)
        #expect(metrics.bytesRead <= byteLimit)
        #expect(metrics.recordsVisited < 2_000)
    }
}
