import Foundation
import Testing
@testable import cmux

/// Behavior coverage for ``AgentChatTranscriptResolver``'s resume-binding
/// fallback: a session-restored terminal has no live index entry, but its
/// persisted resume binding still locates the transcript.
@Suite struct AgentChatTranscriptResolverResumeBindingTests {
    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chatresolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func claudeFallsBackToResumeBindingWhenIndexEmpty() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/dev/proj"
        let sessionId = "11112222-3333-4444-5555-666677778888"
        // Lay down the transcript where the resolver looks: <home>/.claude/projects/<encode(cwd)>/<id>.jsonl
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

        let resolution = resolver.resolve(
            index: .empty,
            workspaceId: UUID(),
            panelId: UUID(),
            resumeBinding: binding
        )

        let result = try #require(resolution)
        #expect(result.agentKind == .claudeCode)
        #expect(result.sessionId == sessionId)
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

        let resolution = resolver.resolve(
            index: .empty,
            workspaceId: UUID(),
            panelId: UUID(),
            resumeBinding: binding
        )

        let result = try #require(resolution)
        #expect(result.agentKind == .codex)
        #expect(result.sessionId == sessionId)
        #expect(result.transcriptURL?.standardizedFileURL == transcript.standardizedFileURL)
    }

    @Test func returnsNilWhenIndexAndResumeBindingAbsent() {
        let resolver = AgentChatTranscriptResolver(homeDirectory: NSHomeDirectory())
        #expect(
            resolver.resolve(
                index: .empty,
                workspaceId: UUID(),
                panelId: UUID(),
                resumeBinding: nil
            ) == nil
        )
    }

    @Test func returnsNilForNonTranscriptResumeBindingKind() {
        let resolver = AgentChatTranscriptResolver(homeDirectory: NSHomeDirectory())
        let binding = SurfaceResumeBindingSnapshot(
            kind: "amp",
            command: "amp",
            cwd: "/Users/dev/proj",
            checkpointId: "sess-1"
        )
        #expect(
            resolver.resolve(
                index: .empty,
                workspaceId: UUID(),
                panelId: UUID(),
                resumeBinding: binding
            ) == nil
        )
    }
}
