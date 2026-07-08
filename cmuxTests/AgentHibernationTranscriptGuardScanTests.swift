import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentHibernationTranscriptGuardScanTests {
    @Test
    func oversizedLineDiscardResumesScanningAfterNewline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let garbage = String(repeating: "x", count: 200 * 1024)
        let userTurn = #"{"type":"user","message":{"content":"later"}}"#
        let populated = directory.appendingPathComponent("oversized-then-user.jsonl")
        try (garbage + "\n" + userTurn + "\n").write(to: populated, atomically: true, encoding: .utf8)
        #expect(
            AgentHibernationTranscriptGuard.transcriptHasConversationTurns(
                atPath: populated.path,
                maxScannedLineBytes: 1_024
            )
        )

        let unpopulated = directory.appendingPathComponent("oversized-only.jsonl")
        try garbage.write(to: unpopulated, atomically: true, encoding: .utf8)
        #expect(
            AgentHibernationTranscriptGuard.transcriptHasConversationTurns(
                atPath: unpopulated.path,
                maxScannedLineBytes: 1_024
            ) == false
        )
    }

    @Test
    func streamingRestorePreservesExactBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotBytes = Data((String(repeating: #"{"type":"assistant","message":{"content":"chunk"}}"# + "\n", count: 96) + "\n\r\n").utf8)
        let stubBytes = Data(("\n\r\n" + metadataStub).utf8)
        try snapshotBytes.write(to: snapshot)
        try stubBytes.write(to: live)

        #expect(
            AgentHibernationTranscriptGuard.restoreIfClobbered(
                .init(transcriptPath: live.path, snapshotPath: snapshot.path)
            )
        )
        #expect(try Data(contentsOf: live) == expectedRestoredBytes(snapshot: snapshotBytes, stub: stubBytes))

        let missingLive = directory.appendingPathComponent("missing-live.jsonl")
        let secondSnapshot = directory.appendingPathComponent("snapshot-missing.jsonl")
        try snapshotBytes.write(to: secondSnapshot)
        #expect(
            AgentHibernationTranscriptGuard.restoreIfClobbered(
                .init(transcriptPath: missingLive.path, snapshotPath: secondSnapshot.path)
            )
        )
        #expect(try Data(contentsOf: missingLive) == snapshotBytes)
    }

    private var metadataStub: String {
        [
            #"{"type":"last-prompt","prompt":"continue"}"#,
            #"{"type":"ai-title","aiTitle":"Fix hibernation"}"#,
            #"{"type":"mode","mode":"default"}"#,
        ].joined(separator: "\n") + "\n"
    }

    private func expectedRestoredBytes(snapshot: Data, stub: Data) -> Data {
        var restored = snapshot
        while restored.last == 10 || restored.last == 13 {
            restored.removeLast()
        }
        restored.append(10)
        var trailing = stub
        while trailing.first == 10 || trailing.first == 13 {
            trailing.removeFirst()
        }
        restored.append(trailing)
        return restored
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-guard-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
