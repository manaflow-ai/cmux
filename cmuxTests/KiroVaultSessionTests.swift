import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct KiroVaultSessionTests {
    @Test func defaultRegistryIncludesKiro() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: root.path, environment: [:])
        let registration = try #require(registry.registration(id: "kiro"))
        #expect(registration.iconAssetName == "AgentIcons/Kiro")
        #expect(registration.defaultExecutable == "kiro-cli")
    }

    @Test func discoversMetadataAndPersistedConversationWithoutHooks() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(in: root, id: "first-session", cwd: "/tmp/kiro repo", prompt: "Fix the Kiro Vault", modified: 200)
        let entries = await load(root: root)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.agent.id == "kiro")
        #expect(entry.sessionId == "first-session")
        #expect(entry.cwd == "/tmp/kiro repo")
        #expect(entry.title == "Fix the Kiro Vault")
        #expect(entry.fileURL == root.appendingPathComponent("first-session.jsonl"))
        let command = try #require(entry.copyResumeCommand)
        #expect(command.contains("kiro-cli"))
        #expect(command.contains("--resume-id"))
        #expect(command.contains("first-session"))
        #expect(command.contains("/tmp/kiro repo"))
    }

    @Test func searchAndPagingUseMetadataCWDAndTranscriptContent() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(in: root, id: "older", cwd: "/tmp/project", prompt: "Older prompt", modified: 100)
        try writeSession(in: root, id: "newer", cwd: "/tmp/project", prompt: "Newer prompt", modified: 200)
        try writeSession(in: root, id: "other", cwd: "/tmp/other", prompt: "Other prompt", modified: 300)
        let all = await load(root: root)
        #expect(all.map(\.sessionId) == ["other", "newer", "older"])
        let page = await load(root: root, needle: "needle-in-response", cwd: "/tmp/project", offset: 1, limit: 1)
        #expect(page.map(\.sessionId) == ["older"])
        let idMatch = await load(root: root, needle: "newer")
        #expect(idMatch.map(\.sessionId) == ["newer"])
    }

    @Test func previewReadsKiroMessageKindsAndSkipsUnknownRecords() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(in: root, id: "preview", cwd: "/tmp/project", prompt: "日本語の質問", modified: 100)
        // Construct independently of discovery so a discovery failure does not hide preview coverage.
        let registration = registration(root: root)
        let entry = SessionEntry(
            id: "kiro:preview", agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "preview", title: "", cwd: "/tmp/project", gitBranch: nil, pullRequest: nil,
            modified: .distantPast, fileURL: root.appendingPathComponent("preview.jsonl"),
            specifics: .registered(registration)
        )
        let turns = try await SessionTranscriptLoader.load(entry: entry)
        #expect(turns.map(\.role) == [.user, .assistant])
        #expect(turns.map(\.text) == ["日本語の質問", "needle-in-response"])
    }

    @Test func invalidMetadataDoesNotHideValidNeighbor() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(in: root, id: "valid", cwd: "/tmp/project", prompt: "Valid prompt", modified: 100)
        try Data("{truncated".utf8).write(to: root.appendingPathComponent("broken.json"))
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("broken.jsonl"))
        let entries = await load(root: root)
        #expect(entries.map(\.sessionId) == ["valid"])
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-kiro-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func registration(root: URL) -> CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "kiro", name: "Kiro", iconAssetName: "AgentIcons/Kiro",
            detect: CmuxVaultAgentDetectRule(processNames: ["kiro-cli", "kiro"]),
            sessionIdSource: .argvOption("--resume-id"),
            resumeCommand: "{{executable}} chat --resume-id {{sessionId}}",
            sessionDirectory: root.path
        )
    }

    private func load(root: URL, needle: String = "", cwd: String? = nil, offset: Int = 0, limit: Int = 10) async -> [SessionEntry] {
        await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration(root: root), needle: needle, cwdFilter: cwd, offset: offset, limit: limit
        )
    }

    private func writeSession(in root: URL, id: String, cwd: String, prompt: String, modified: TimeInterval) throws {
        // Kiro ACP persists a metadata sidecar and version/kind/data records, not wire notifications.
        // https://kiro.dev/docs/cli/acp/#session-storage
        // https://github.com/kirodotdev/Kiro/issues/6110#issuecomment-4040030540
        let metadata: [String: Any] = ["session_id": id, "cwd": cwd, "session_state": [:]]
        let metadataURL = root.appendingPathComponent("\(id).json")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        let records: [[String: Any]] = [
            ["version": "v1", "kind": "FutureEvent", "data": ["content": "ignore"]],
            ["version": "v1", "kind": "UserMessage", "data": ["content": [["kind": "text", "data": prompt]]]],
            ["version": "v1", "kind": "AssistantMessage", "data": ["content": [
                ["kind": "text", "data": "needle-in-response"],
                ["kind": "toolUse", "data": ["name": "read", "input": ["path": "/tmp/file"]]]
            ]]]
        ]
        var transcript = Data()
        for record in records {
            transcript.append(try JSONSerialization.data(withJSONObject: record))
            transcript.append(0x0a)
        }
        let transcriptURL = root.appendingPathComponent("\(id).jsonl")
        try transcript.write(to: transcriptURL)
        for url in [metadataURL, transcriptURL] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
        }
    }
}
