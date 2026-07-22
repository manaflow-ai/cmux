import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatArtifactIndexSafetyTests {
    @Test func oversizedTranscriptIndexesItsNewlineAlignedTail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let artifactPath = root.appendingPathComponent("latest.md").path
        let prefix = Array(repeating: String(repeating: "x", count: 80), count: 20)
        let artifactLine = try codexArtifactLine(path: artifactPath)
        try (prefix + [artifactLine]).joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let snapshot = try await AgentChatArtifactIndex().snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 512
        )

        let artifact = try #require(snapshot.artifacts.first)
        #expect(artifact.path == artifactPath)
        #expect(artifact.lastReferencedSeq == 20)
        #expect(snapshot.lineCount == 21)
    }

    @Test func canceledSnapshotStopsBeforeTranscriptParsing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AgentChatArtifactIndex().snapshot(
                sessionID: "session",
                agentKind: .claude,
                transcriptPath: transcript.path,
                workingDirectory: root.path,
                maximumFileBytes: 1_024
            )
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    private func codexArtifactLine(path: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-07-21T12:00:00.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "Saved artifact to \(path)"]],
            ],
        ])
        return String(decoding: data, as: UTF8.self)
    }
}
