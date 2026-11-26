import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentHibernationTranscriptSnapshotRaceTests {
    @Test
    func snapshotFailsClosedWhenSourceChangesAfterCopy() throws {
        try assertSnapshotFailsClosed(
            sessionId: "post-copy-race",
            initialContent: originalContent,
            replacementContent: updatedContent,
            fileManager: PostCopyRewritingFileManager(replacement: updatedContent)
        )
    }

    @Test
    func newerSnapshotSurvivesWhenOlderContentReplacesLivePathAfterComparison() throws {
        try assertSnapshotFailsClosed(
            sessionId: "post-comparison-race",
            initialContent: updatedContent,
            replacementContent: originalContent,
            fileManager: PostComparisonRewritingFileManager(replacement: originalContent)
        )
    }

    @Test
    func repeatedFailedSnapshotsReplaceRetainedRecoveryCopyInsteadOfAccumulating() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-snapshot-retention-\(UUID().uuidString)", isDirectory: true)
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        let cwd = "/tmp/repo"
        let sessionId = "retention-race"
        let live = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        for _ in 0..<3 {
            try originalContent.write(to: live, atomically: true, encoding: .utf8)
            let outcome = AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: SessionRestorableAgentSnapshot(
                    kind: .claude,
                    sessionId: sessionId,
                    workingDirectory: cwd,
                    launchCommand: nil
                ),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                fileManager: PostCopyRewritingFileManager(replacement: updatedContent)
            )
            guard case .unableToProtect = outcome else {
                Issue.record("snapshot should fail closed when the live path changes")
                return
            }
        }

        let retainedSnapshots = try FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: nil
        )
        let retainedSnapshot = try #require(retainedSnapshots.first)
        #expect(retainedSnapshots.count == 1)
        #expect(retainedSnapshot.lastPathComponent == "\(sessionId)-retained.jsonl")
        #expect(try String(contentsOf: retainedSnapshot, encoding: .utf8) == originalContent)
    }

    @Test
    func finalLiveFileVersionCheckRejectsAtomicPathReplacementAfterComparison() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-final-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshotURL = directory.appendingPathComponent("snapshot.jsonl")
        try updatedContent.write(to: live, atomically: true, encoding: .utf8)
        try updatedContent.write(to: snapshotURL, atomically: true, encoding: .utf8)
        let validatedSnapshot = try #require(
            AgentHibernationTranscriptGuard.snapshotStillMatchesLive(
                .init(transcriptPath: live.path, snapshotPath: snapshotURL.path)
            )
        )

        // Model a transcript rewrite during the post-snapshot session-index await.
        // Even byte-identical atomic replacement changes path identity and must stop SIGTERM.
        try updatedContent.write(to: live, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.liveFileVersionStillMatches(validatedSnapshot) == false)
    }

    private func assertSnapshotFailsClosed(
        sessionId: String,
        initialContent: String,
        replacementContent: String,
        fileManager: FileManager
    ) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-snapshot-race-\(UUID().uuidString)", isDirectory: true)
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        let cwd = "/tmp/repo"
        let live = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try initialContent.write(to: live, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let outcome = AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: sessionId,
                workingDirectory: cwd,
                launchCommand: nil
            ),
            homeDirectory: home.path,
            snapshotDirectory: snapshots,
            fileManager: fileManager
        )

        guard case .unableToProtect = outcome else {
            Issue.record("snapshot should fail closed when the live path changes")
            return
        }
        #expect(try String(contentsOf: live, encoding: .utf8) == replacementContent)
        let retainedSnapshots = try FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: nil
        )
        let retainedSnapshot = try #require(retainedSnapshots.first)
        #expect(retainedSnapshots.count == 1)
        #expect(try String(contentsOf: retainedSnapshot, encoding: .utf8) == initialContent)
    }

    private var originalContent: String {
        #"{"type":"user","message":{"content":"before"}}"# + "\n"
    }

    private var updatedContent: String {
        originalContent + #"{"type":"assistant","message":{"content":"after copy"}}"# + "\n"
    }

    private func transcriptURL(home: URL, cwd: String, sessionId: String) -> URL {
        home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
    }

    private final class PostCopyRewritingFileManager: FileManager {
        private let replacement: String

        init(replacement: String) {
            self.replacement = replacement
            super.init()
        }

        override func copyItem(atPath srcPath: String, toPath dstPath: String) throws {
            try super.copyItem(atPath: srcPath, toPath: dstPath)
            try replacement.write(toFile: srcPath, atomically: true, encoding: .utf8)
        }
    }

    private final class PostComparisonRewritingFileManager: FileManager {
        private let replacement: String
        private var copiedSourcePath: String?
        private var sourceAttributeReadCount = 0

        init(replacement: String) {
            self.replacement = replacement
            super.init()
        }

        override func copyItem(atPath srcPath: String, toPath dstPath: String) throws {
            try super.copyItem(atPath: srcPath, toPath: dstPath)
            copiedSourcePath = srcPath
        }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            if path == copiedSourcePath {
                sourceAttributeReadCount += 1
                if sourceAttributeReadCount == 2 {
                    try replacement.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
            return try super.attributesOfItem(atPath: path)
        }
    }
}
