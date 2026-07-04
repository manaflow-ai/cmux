import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct ClaudeTranscriptSeedingTests {
    @Test func encodedProjectDirectoryNameMatchesClaudeCwdRule() {
        #expect(
            ClaudeTranscriptSeeder.encodedProjectDirectoryName(for: "/Users/lawrence/fun/cmuxterm-hq/.claude")
                == "-Users-lawrence-fun-cmuxterm-hq--claude"
        )
    }

    @Test func helperCopiesTranscriptAndSidecarIntoTargetCwdProjectDir() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        let didSeed = ClaudeTranscriptSeeder(fileManager: fileManager).seedTranscriptIfNeeded(
            sessionId: fixture.sessionId,
            targetWorkingDirectory: fixture.targetCwd.path,
            sourceWorkingDirectory: fixture.sourceCwd.path,
            environment: ["CLAUDE_CONFIG_DIR": fixture.configDir.path]
        )

        #expect(didSeed)
        try assertSeededFixture(fixture, fileManager: fileManager)
    }

    @Test func forkStartupInputSeedsClaudeTranscriptIntoTargetCwdProjectDir() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: fixture.sessionId,
            workingDirectory: fixture.targetCwd.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude"],
                workingDirectory: fixture.sourceCwd.path,
                environment: ["CLAUDE_CONFIG_DIR": fixture.configDir.path],
                capturedAt: 123,
                source: "test"
            )
        )

        #expect(snapshot.forkStartupInput(fileManager: fileManager, temporaryDirectory: fixture.root) != nil)

        try assertSeededFixture(fixture, fileManager: fileManager)
    }

    private func makeFixture(fileManager: FileManager) throws -> ClaudeTranscriptSeedFixture {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-transcript-seed-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let sourceCwd = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let targetCwd = root
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("feat-monaco-settings", isDirectory: true)
        try fileManager.createDirectory(at: sourceCwd, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: targetCwd, withIntermediateDirectories: true)

        let sessionId = "39c1eb84-1111-2222-3333-444444444444"
        let sourceProjectDir = projectDirectory(configDir: configDir, cwd: sourceCwd)
        let targetProjectDir = projectDirectory(configDir: configDir, cwd: targetCwd)
        try fileManager.createDirectory(at: sourceProjectDir, withIntermediateDirectories: true)
        let sourceTranscript = sourceProjectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        let sourceTranscriptContents = """
        {"type":"user","sessionId":"\(sessionId)","cwd":"\(sourceCwd.path)"}

        """
        try sourceTranscriptContents.write(to: sourceTranscript, atomically: true, encoding: .utf8)

        let sourceSidecarDir = sourceProjectDir.appendingPathComponent(sessionId, isDirectory: true)
        try fileManager.createDirectory(at: sourceSidecarDir, withIntermediateDirectories: true)
        let sourceSidecar = sourceSidecarDir.appendingPathComponent("metadata.json", isDirectory: false)
        try #"{"sidecar":true}"#.write(to: sourceSidecar, atomically: true, encoding: .utf8)

        return ClaudeTranscriptSeedFixture(
            root: root,
            configDir: configDir,
            sourceCwd: sourceCwd,
            targetCwd: targetCwd,
            sessionId: sessionId,
            sourceTranscript: sourceTranscript,
            targetProjectDir: targetProjectDir,
            sourceTranscriptContents: sourceTranscriptContents
        )
    }

    private func assertSeededFixture(
        _ fixture: ClaudeTranscriptSeedFixture,
        fileManager: FileManager
    ) throws {
        let targetTranscript = fixture.targetProjectDir
            .appendingPathComponent("\(fixture.sessionId).jsonl", isDirectory: false)
        let copiedTranscript = try String(contentsOf: targetTranscript, encoding: .utf8)
        #expect(copiedTranscript == fixture.sourceTranscriptContents)

        let copiedSidecar = fixture.targetProjectDir
            .appendingPathComponent(fixture.sessionId, isDirectory: true)
            .appendingPathComponent("metadata.json", isDirectory: false)
        let copiedSidecarContents = try String(contentsOf: copiedSidecar, encoding: .utf8)
        #expect(copiedSidecarContents == #"{"sidecar":true}"#)

        let sourceInode = try inodeNumber(at: fixture.sourceTranscript)
        let targetInode = try inodeNumber(at: targetTranscript)
        #expect(sourceInode != targetInode, "Transcript seeding must copy, not hardlink, the JSONL file.")
    }

    private func projectDirectory(configDir: URL, cwd: URL) -> URL {
        configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(expectedClaudeProjectDirName(cwd.path), isDirectory: true)
    }

    private func expectedClaudeProjectDirName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func inodeNumber(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = try #require(attributes[.systemFileNumber] as? NSNumber)
        return value.uint64Value
    }
}

private struct ClaudeTranscriptSeedFixture {
    var root: URL
    var configDir: URL
    var sourceCwd: URL
    var targetCwd: URL
    var sessionId: String
    var sourceTranscript: URL
    var targetProjectDir: URL
    var sourceTranscriptContents: String
}
