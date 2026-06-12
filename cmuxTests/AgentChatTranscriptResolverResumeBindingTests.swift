import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for ``AgentChatTranscriptResolver``'s resume-binding
/// fallback: a session-restored terminal can miss both the live hook index and
/// the workspace's in-memory restored snapshot, but its persisted resume
/// binding (kind + session id + cwd + env) still locates the transcript.
@Suite struct AgentChatTranscriptResolverResumeBindingTests {
    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chatresolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func resolve(
        _ resolver: AgentChatTranscriptResolver,
        binding: SurfaceResumeBindingSnapshot?
    ) -> AgentChatTranscriptResolver.Resolution? {
        resolver.resolve(
            index: .empty,
            restoredSnapshot: nil,
            workspaceId: UUID(),
            panelId: UUID(),
            resumeBinding: binding
        )
    }

    @Test func claudeFallsBackToResumeBindingWhenIndexEmpty() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/dev/proj"
        let sessionId = "11112222-3333-4444-5555-666677778888"
        // Lay down the transcript where the resolver looks:
        // <home>/.claude/projects/<encode(cwd)>/<id>.jsonl
        let dirName = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        let projectDir = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcript = projectDir.appendingPathComponent("\(sessionId).jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home.path)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume \(sessionId)",
            cwd: cwd,
            checkpointId: sessionId
        )

        let result = try #require(resolve(resolver, binding: binding))
        #expect(result.provider == .claude)
        #expect(result.sessionId == sessionId)
        #expect(result.workingDirectory == cwd)
        #expect(result.transcriptURL?.standardizedFileURL == transcript.standardizedFileURL)
    }

    @Test func codexFallsBackToResumeBindingWhenIndexEmpty() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionId = "abcd1234-5678-90ab-cdef-1234567890ab"
        let dayDir = home
            .appendingPathComponent(".codex/sessions/2026/06/10", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let transcript = dayDir.appendingPathComponent("rollout-2026-06-10T00-00-00-\(sessionId).jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home.path)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionId)",
            cwd: "/Users/dev/proj",
            checkpointId: sessionId
        )

        let result = try #require(resolve(resolver, binding: binding))
        #expect(result.provider == .codex)
        #expect(result.sessionId == sessionId)
        #expect(result.transcriptURL?.standardizedFileURL == transcript.standardizedFileURL)
    }

    @Test func claudeResumeBindingResolvesWorkflowContainerToNewestSibling() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/dev/proj"
        // The resume binding's id is a workflow CONTAINER directory, not a transcript.
        let containerId = "00000000-0000-0000-0000-000000000000"
        let dirName = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        let projectDir = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // The container subdirectory named after the recorded id.
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent(containerId, isDirectory: true),
            withIntermediateDirectories: true
        )
        // Two sibling transcripts; the newer one should win.
        let older = projectDir.appendingPathComponent("aaaaaaaa-1111.jsonl")
        let newer = projectDir.appendingPathComponent("bbbbbbbb-2222.jsonl")
        try Data("{}\n".utf8).write(to: older)
        try Data("{}\n".utf8).write(to: newer)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newer.path)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home.path)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume \(containerId)",
            cwd: cwd,
            checkpointId: containerId
        )
        let result = try #require(resolve(resolver, binding: binding))
        #expect(result.transcriptURL?.standardizedFileURL == newer.standardizedFileURL)
    }

    @Test func returnsNilWhenIndexAndResumeBindingAbsent() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let resolver = AgentChatTranscriptResolver(homeDirectory: home.path)
        #expect(resolve(resolver, binding: nil) == nil)
    }

    @Test func rejectsResumeBindingCheckpointWithPathSeparator() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let resolver = AgentChatTranscriptResolver(homeDirectory: home.path)
        for unsafe in ["../other/abc", "a/b", "..", "."] {
            let binding = SurfaceResumeBindingSnapshot(
                kind: "claude",
                command: "claude --resume x",
                cwd: "/Users/dev/proj",
                checkpointId: unsafe
            )
            #expect(resolve(resolver, binding: binding) == nil)
        }
    }

    @Test func returnsNilForNonTranscriptResumeBindingKind() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let resolver = AgentChatTranscriptResolver(homeDirectory: home.path)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "amp",
            command: "amp",
            cwd: "/Users/dev/proj",
            checkpointId: "sess-1"
        )
        #expect(resolve(resolver, binding: binding) == nil)
    }
}
