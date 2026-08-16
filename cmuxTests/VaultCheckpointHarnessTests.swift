import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private let parentID = "aaaaaaaa-1111-2222-3333-444444444444"
private let newID = "bbbbbbbb-5555-6666-7777-888888888888"

private func makeEntry(agent: SessionAgent, fileURL: URL?, registeredID: String? = nil) -> SessionEntry {
    let specifics: AgentSpecifics
    switch agent {
    case .claude: specifics = .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
    case .codex: specifics = .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
    case .grok: specifics = .grok(model: nil, permissionMode: nil, sandboxMode: nil, grokHome: nil)
    case .opencode: specifics = .opencode(providerModel: nil, agentName: nil)
    case .rovodev: specifics = .rovodev
    case .hermesAgent: specifics = .hermesAgent(source: nil, model: nil, hermesHome: nil)
    case .registered:
        specifics = .registered(CmuxVaultAgentRegistration(
            id: registeredID ?? "pi",
            name: nil,
            detect: CmuxVaultAgentDetectRule(processNames: [registeredID ?? "pi"]),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "\(registeredID ?? "pi") --session {{sessionId}}",
            cwd: .preserve
        ))
    }
    return SessionEntry(
        id: agent.rawValue + ":test",
        agent: agent,
        sessionId: parentID,
        title: "parent",
        cwd: "/tmp",
        gitBranch: nil,
        pullRequest: nil,
        modified: Date(timeIntervalSince1970: 0),
        fileURL: fileURL,
        specifics: specifics
    )
}

private func tempDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readJSONLines(_ url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

@Suite
struct VaultCheckpointHarnessResolutionTests {
    @Test
    func fileBackedHarnessesSupportFork() {
        let url = URL(fileURLWithPath: "/tmp/x.jsonl")
        #expect(VaultCheckpointHarness.resolve(for: makeEntry(agent: .claude, fileURL: url)) == .claude)
        #expect(VaultCheckpointHarness.resolve(for: makeEntry(agent: .codex, fileURL: url)) == .codex)
        #expect(VaultCheckpointHarness.resolve(for: makeEntry(agent: .grok, fileURL: url)) == .grok)
        #expect(VaultCheckpointHarness.resolve(
            for: makeEntry(agent: .registered(RegisteredSessionAgent(id: "pi")), fileURL: url, registeredID: "pi")
        ) == .piFamily)
        #expect(VaultCheckpointHarness.claude.supportsFork)
        #expect(VaultCheckpointHarness.codex.supportsFork)
        #expect(VaultCheckpointHarness.grok.supportsFork)
        #expect(VaultCheckpointHarness.piFamily.supportsFork)
    }

    @Test
    func databaseBackedHarnessesAreTimelineOnly() {
        #expect(VaultCheckpointHarness.resolve(for: makeEntry(agent: .opencode, fileURL: nil)) == .timelineOnly)
        #expect(VaultCheckpointHarness.resolve(for: makeEntry(agent: .rovodev, fileURL: nil)) == .timelineOnly)
        #expect(VaultCheckpointHarness.resolve(for: makeEntry(agent: .hermesAgent, fileURL: nil)) == .timelineOnly)
        #expect(!VaultCheckpointHarness.timelineOnly.supportsFork)
    }
}

@Suite
struct VaultCodexCheckpointTests {
    private func codexLines() -> [String] {
        [
            #"{"timestamp":"2026-08-14T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"\#(parentID)","id":"\#(parentID)","cwd":"/tmp"}}"#,
            #"{"timestamp":"2026-08-14T10:00:01.000Z","ordinal":1,"type":"event_msg","payload":{"type":"user_message","message":"first prompt"}}"#,
            #"{"timestamp":"2026-08-14T10:00:02.000Z","ordinal":2,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"reply"}]}}"#,
            #"{"timestamp":"2026-08-14T10:00:03.000Z","ordinal":3,"type":"event_msg","payload":{"type":"user_message","message":"second prompt"}}"#,
        ]
    }

    @Test
    func derivesUserTurnsWithOrdinalAnchors() throws {
        let directory = try tempDirectory("cmux-codex-derive")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout-2026-08-14T10-00-00-\(parentID).jsonl")
        try Data((codexLines().joined(separator: "\n") + "\n").utf8).write(to: url)

        let derivation = VaultSessionCheckpoints.deriveCodexTurns(fileURL: url)
        #expect(derivation.checkpoints.count == 2)
        #expect(derivation.checkpoints[0].anchor == "ordinal:1")
        #expect(derivation.checkpoints[0].promptSnippet == "first prompt")
        #expect(derivation.checkpoints[1].anchor == "ordinal:3")
        // Envelope payloads are not prompts.
        let envelope = #"{"type":"event_msg","payload":{"type":"user_message","message":"<environment_context>x"}}"#
        let obj = try JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        #expect(VaultSessionCheckpoints.codexUserPromptText(from: obj ?? [:]) == nil)
    }

    @Test
    func forkRewritesSessionMetaAndKeepsTimestampPrefix() throws {
        let directory = try tempDirectory("cmux-codex-fork")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout-2026-08-14T10-00-00-\(parentID).jsonl")
        try Data((codexLines().joined(separator: "\n") + "\n").utf8).write(to: url)
        let parentBytes = try Data(contentsOf: url)

        let checkpoint = VaultSessionCheckpoint(
            id: "turn:ordinal:3", source: .turn, timestamp: nil, name: nil,
            turnIndex: 2, anchor: "ordinal:3", gitSHA: nil, promptSnippet: nil
        )
        let forked = try VaultCheckpointHarness.fork(
            entry: makeEntry(agent: .codex, fileURL: url),
            checkpoint: checkpoint,
            newSessionID: newID
        )
        #expect(forked.lastPathComponent == "rollout-2026-08-14T10-00-00-\(newID).jsonl")
        let rows = try readJSONLines(forked)
        // Strictly before the second prompt: meta + first prompt + reply.
        #expect(rows.count == 3)
        let meta = rows[0]["payload"] as? [String: Any]
        #expect(meta?["id"] as? String == newID)
        #expect(meta?["session_id"] as? String == newID)
        #expect(try Data(contentsOf: url) == parentBytes)
    }
}

@Suite
struct VaultPiFamilyCheckpointTests {
    private func piLines() -> [String] {
        [
            #"{"type":"session","version":3,"id":"\#(parentID)","timestamp":"2026-08-14T10:00:00.000Z","cwd":"/tmp"}"#,
            #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-08-14T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"first prompt"}]}}"#,
            #"{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-08-14T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}"#,
            #"{"type":"message","id":"m3","parentId":"m2","timestamp":"2026-08-14T10:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"second prompt"}]}}"#,
        ]
    }

    @Test
    func derivesUserTurnsWithLineIDAnchors() throws {
        let directory = try tempDirectory("cmux-pi-derive")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("2026-08-14T10-00-00-000Z_\(parentID).jsonl")
        try Data((piLines().joined(separator: "\n") + "\n").utf8).write(to: url)

        let derivation = VaultSessionCheckpoints.derivePiFamilyTurns(fileURL: url)
        #expect(derivation.checkpoints.count == 2)
        #expect(derivation.checkpoints[0].anchor == "id:m1")
        #expect(derivation.checkpoints[1].anchor == "id:m3")
        #expect(derivation.checkpoints[1].promptSnippet == "second prompt")
    }

    @Test
    func forkRewritesSessionLineAndFilename() throws {
        let directory = try tempDirectory("cmux-pi-fork")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("2026-08-14T10-00-00-000Z_\(parentID).jsonl")
        try Data((piLines().joined(separator: "\n") + "\n").utf8).write(to: url)

        let checkpoint = VaultSessionCheckpoint(
            id: "turn:id:m3", source: .turn, timestamp: nil, name: nil,
            turnIndex: 2, anchor: "id:m3", gitSHA: nil, promptSnippet: nil
        )
        let forked = try VaultCheckpointHarness.fork(
            entry: makeEntry(
                agent: .registered(RegisteredSessionAgent(id: "pi")),
                fileURL: url,
                registeredID: "pi"
            ),
            checkpoint: checkpoint,
            newSessionID: newID
        )
        #expect(forked.lastPathComponent == "2026-08-14T10-00-00-000Z_\(newID).jsonl")
        let rows = try readJSONLines(forked)
        #expect(rows.count == 3)
        #expect(rows[0]["id"] as? String == newID)
        // Record-level short ids stay intact — only the session line owns
        // session identity.
        #expect(rows[1]["id"] as? String == "m1")
    }
}

@Suite
struct VaultGrokCheckpointTests {
    private func grokLines() -> [String] {
        [
            #"{"type":"system","content":"system prompt"}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_info>env stuff</user_info>"}]}"#,
            #"{"type":"user","content":[{"type":"text","text":"first prompt"}]}"#,
            #"{"type":"assistant","content":"reply"}"#,
            #"{"type":"user","content":[{"type":"text","text":"second prompt"}]}"#,
        ]
    }

    private func writeGrokSession() throws -> URL {
        let root = try tempDirectory("cmux-grok-fork")
        let sessionDirectory = root.appendingPathComponent(parentID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let history = sessionDirectory.appendingPathComponent("chat_history.jsonl")
        try Data((grokLines().joined(separator: "\n") + "\n").utf8).write(to: history)
        try Data("{}".utf8).write(to: sessionDirectory.appendingPathComponent("prompt_context.json"))
        try Data("lock".utf8).write(to: sessionDirectory.appendingPathComponent("chat_history.jsonl.lock"))
        return history
    }

    @Test
    func derivationSkipsEnvironmentEnvelopes() throws {
        let history = try writeGrokSession()
        defer { try? FileManager.default.removeItem(at: history.deletingLastPathComponent().deletingLastPathComponent()) }

        let derivation = VaultSessionCheckpoints.deriveGrokTurns(fileURL: history)
        #expect(derivation.checkpoints.count == 2)
        #expect(derivation.checkpoints[0].promptSnippet == "first prompt")
        #expect(derivation.checkpoints[0].anchor == "line:2")
        #expect(derivation.checkpoints[1].anchor == "line:4")
    }

    @Test
    func forkCreatesSiblingDirectoryWithTruncatedHistoryAndSidecars() throws {
        let history = try writeGrokSession()
        let root = history.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let checkpoint = VaultSessionCheckpoint(
            id: "turn:line:4", source: .turn, timestamp: nil, name: nil,
            turnIndex: 2, anchor: "line:4", gitSHA: nil, promptSnippet: nil
        )
        let forked = try VaultCheckpointHarness.fork(
            entry: makeEntry(agent: .grok, fileURL: history),
            checkpoint: checkpoint,
            newSessionID: newID
        )
        #expect(forked.path.contains("/\(newID)/chat_history.jsonl"))
        let rows = try readJSONLines(forked)
        // Strictly before the second prompt: system + env + first + reply.
        #expect(rows.count == 4)
        let newDirectory = forked.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: newDirectory.appendingPathComponent("prompt_context.json").path))
        // Locks and telemetry stay behind.
        #expect(!FileManager.default.fileExists(atPath: newDirectory.appendingPathComponent("chat_history.jsonl.lock").path))
        // Parent history untouched.
        #expect(try readJSONLines(history).count == 5)
    }
}
