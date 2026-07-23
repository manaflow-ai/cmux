import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent chat transcript resolution review", .serialized)
struct AgentChatTranscriptResolutionReviewTests {
    @Test("Codex fallback scanning obeys its entry bound")
    func codexFallbackScanningIsBounded() throws {
        let fixture = try makeCodexFixture(sessionID: "bounded-session")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: fixture.home,
            environment: [:],
            maximumCodexFallbackEntries: 0
        )

        #expect(try resolver.transcriptPath(for: fixture.record) == nil)
    }

    @MainActor
    @Test("Mobile artifact indexing persists a successful Codex fallback")
    func mobileArtifactIndexingPersistsFallbackPath() async throws {
        let fixture = try makeCodexFixture(sessionID: "persisted-session")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = AgentChatSessionRegistry(restoredRecords: [fixture.record])
        let service = AgentChatTranscriptService(
            registry: registry,
            resolver: AgentChatTranscriptResolver(homeDirectory: fixture.home, environment: [:])
        )
        let controller = TerminalController.shared
        let previousService = controller.agentChatTranscriptService
        controller.agentChatTranscriptService = service
        defer { controller.agentChatTranscriptService = previousService }

        let indexed = try await controller.mobileChatArtifactIndexedSession(
            sessionID: fixture.record.sessionID
        )

        #expect(indexed != nil)
        #expect(registry.record(sessionID: fixture.record.sessionID)?.transcriptPath
            == fixture.transcript.path)
    }

    private func makeCodexFixture(
        sessionID: String
    ) throws -> (root: URL, home: URL, transcript: URL, record: AgentChatSessionRecord) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-chat-resolution-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let transcript = home
            .appendingPathComponent(".codex/sessions/2026/07/22", isDirectory: true)
            .appendingPathComponent("rollout-2026-07-22T00-00-00-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data().write(to: transcript)
        return (
            root,
            home,
            transcript,
            AgentChatSessionRecord(
                sessionID: sessionID,
                agentKind: .codex,
                workspaceID: "workspace",
                surfaceID: nil,
                workingDirectory: project.path,
                transcriptPath: nil,
                state: .idle,
                lastActivityAt: .now,
                title: nil,
                pid: nil
            )
        )
    }
}
