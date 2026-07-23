import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent chat transcript tailer bounds")
struct AgentChatTranscriptTailerBoundedReadTests {
    @Test("Initial backfill retains a byte-bounded transcript suffix")
    func initialBackfillIsByteBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("session.jsonl")
        let padding = String(repeating: "x", count: 1_000_000)
        let lines = try (0..<6).map { index in
            try claudeUserLine(id: index, content: "marker-\(index)-\(padding)")
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)

        let tailer = AgentChatTranscriptTailer(
            sessionID: "session",
            agentKind: .claude,
            path: transcript.path
        ) { _ in }
        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 20)
        await tailer.stop()

        #expect(page.messages.count < lines.count)
        guard let last = page.messages.last,
              case .prose(let prose) = last.kind else {
            Issue.record("Expected the newest retained transcript line")
            return
        }
        #expect(prose.text.hasPrefix("marker-5-"))
        #expect(page.hasMore)
    }

    private func claudeUserLine(id: Int, content: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "isSidechain": false,
            "uuid": "user-\(id)",
            "timestamp": "2026-07-22T12:00:00.000Z",
            "message": ["role": "user", "content": content],
        ])
        return String(decoding: data, as: UTF8.self)
    }
}
