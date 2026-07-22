import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatArtifactIndexSafetyTests {
    @Test func oversizedTranscriptContinuesIndexingItsNewlineAlignedTail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let firstArtifactPath = root.appendingPathComponent("first.md").path
        let secondArtifactPath = root.appendingPathComponent("second.md").path
        let prefix = Array(repeating: String(repeating: "x", count: 80), count: 20)
        let artifactLine = try codexArtifactLine(path: firstArtifactPath)
        let initialTranscript = (prefix + [artifactLine]).joined(separator: "\n")
        try initialTranscript.write(to: transcript, atomically: true, encoding: .utf8)
        let firstArtifactOffset = (prefix.joined(separator: "\n") + "\n").utf8.count
        let index = AgentChatArtifactIndex()

        let firstSnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 512
        )
        let firstArtifact = try #require(firstSnapshot.artifacts.first)
        #expect(firstArtifact.path == firstArtifactPath)
        #expect(firstArtifact.lastReferencedSeq == firstArtifactOffset)

        let appendedPrefix = Array(repeating: String(repeating: "y", count: 80), count: 20)
        let appendedLines = appendedPrefix + [try codexArtifactLine(path: secondArtifactPath)]
        let secondArtifactOffset = initialTranscript.utf8.count
            + 1
            + appendedPrefix.joined(separator: "\n").utf8.count
            + 1
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + appendedLines.joined(separator: "\n")).utf8))
        try handle.close()
        let secondSnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 512
        )

        let artifacts = Dictionary(uniqueKeysWithValues: secondSnapshot.artifacts.map {
            ($0.path, $0.lastReferencedSeq)
        })
        #expect(artifacts[firstArtifactPath] == firstArtifactOffset)
        #expect(artifacts[secondArtifactPath] == secondArtifactOffset)
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
