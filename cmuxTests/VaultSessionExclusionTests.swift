import CmuxFoundation
import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Vault session exclusions")
struct VaultSessionExclusionTests {
    @Test("Claude metadata preserves an SDK entrypoint")
    func claudeMetadataReadsEntrypoint() {
        let parsed = SessionIndexStore.extractClaudeMetadata(
            head: #"{"type":"user","entrypoint":"sdk-py","cwd":"/tmp/cmux-vault-test","message":{"role":"user","content":"Review this change"}}"#,
            tail: "",
            projectDir: "-Users-me-project"
        )

        #expect(parsed.entrypoint == "sdk-py")
        #expect(parsed.title == "Review this change")
        #expect(parsed.cwd == "/tmp/cmux-vault-test")
    }

    @Test("SDK hiding only removes Claude SDK sessions")
    func sdkHidingIsScopedToClaude() {
        let registry = CmuxVaultAgentRegistry(
            registrations: [],
            hideClaudeSDKSessions: true
        )
        let claudeSDK = makeEntry(agent: .claude, entrypoint: "sdk-py")
        let claudeCLI = makeEntry(agent: .claude, entrypoint: "cli")
        let codexSDK = makeEntry(agent: .codex, entrypoint: "sdk-py")

        #expect(registry.excludes(claudeSDK))
        #expect(!registry.excludes(claudeCLI))
        #expect(!registry.excludes(codexSDK))
    }

    @Test("Exclusion rules combine fields and support label patterns")
    func exclusionRuleMatchesAllFields() throws {
        let decoded = try JSONDecoder().decode(
            CmuxVaultConfigDefinition.self,
            from: Data(#"{"exclude":[{"agent":"claude","folder":"/work/*","entrypoint":"sdk-*","labelPattern":"re:^Review this"}]}"#.utf8)
        )
        let registry = CmuxVaultAgentRegistry(
            registrations: [],
            sessionExclusions: decoded.exclude
        )
        let matching = makeEntry(
            agent: .claude,
            entrypoint: "sdk-py",
            title: "Review this change",
            cwd: "/work/cmux"
        )
        let wrongFolder = makeEntry(
            agent: .claude,
            entrypoint: "sdk-py",
            title: "Review this change",
            cwd: "/other/cmux"
        )
        let wrongEntrypoint = makeEntry(
            agent: .claude,
            entrypoint: "cli",
            title: "Review this change",
            cwd: "/work/cmux"
        )

        #expect(registry.excludes(matching))
        #expect(!registry.excludes(wrongFolder))
        #expect(!registry.excludes(wrongEntrypoint))
    }

    @Test("Vault config can contain filters without agent registrations")
    func configDefaultsAgentsToEmpty() throws {
        let config = try JSONDecoder().decode(
            CmuxVaultConfigDefinition.self,
            from: Data(#"{"hideClaudeSDKSessions":true,"exclude":[{"labelPattern":"*background*"}]}"#.utf8)
        )

        #expect(config.agents.isEmpty)
        #expect(config.hideClaudeSDKSessions)
        #expect(config.exclude.count == 1)
    }

    @Test("Registry loads Vault filters from the user config")
    func registryLoadsFilters() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-vault-filter-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        try #"{"vault":{"hideClaudeSDKSessions":true,"exclude":[{"agent":"codex"}]}}"#.write(
            to: configDirectory.appendingPathComponent("cmux.json"),
            atomically: true,
            encoding: .utf8
        )

        let registry = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])

        #expect(registry.hasSessionExclusions(for: .claude))
        #expect(registry.excludes(makeEntry(agent: .claude, entrypoint: "sdk-ts")))
        #expect(registry.excludes(makeEntry(agent: .codex)))
        #expect(!registry.excludes(makeEntry(agent: .claude, entrypoint: "cli")))
    }

    @Test("A launch folder's project filters do not reach global listings")
    func launchFolderFiltersStayOutOfGlobalListings() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-vault-launch-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try #"{"vault":{"hideClaudeSDKSessions":true,"exclude":[{"agent":"codex"}],"agents":[{"id":"local-agent","name":"Local Agent","detect":{"processName":"local-agent"},"sessionIdSource":{"type":"argvOption","argvOption":"--session"},"resumeCommand":"local-agent --session {{sessionId}}","cwd":"preserve"}]}}"#.write(
            to: project.appendingPathComponent("cmux.json"),
            atomically: true,
            encoding: .utf8
        )

        let global = CmuxVaultAgentRegistry.load(
            homeDirectory: home.path,
            workingDirectory: nil,
            environment: ["PWD": project.path]
        )
        let scoped = CmuxVaultAgentRegistry.load(
            homeDirectory: home.path,
            workingDirectory: project.path,
            environment: [:]
        )

        #expect(!global.hasSessionExclusions(for: .claude))
        #expect(!global.hasSessionExclusions(for: .codex))
        #expect(scoped.hasSessionExclusions(for: .claude))
        #expect(scoped.excludes(makeEntry(agent: .codex)))
        // Agent registrations still come from the launch folder, as before.
        #expect(global.registrations.contains { $0.id == "local-agent" })
        #expect(scoped.registrations.contains { $0.id == "local-agent" })
    }

    @Test("Exclusions only make an agent filter when a rule can match it")
    func exclusionsAreScopedPerAgent() {
        let sdkOnly = CmuxVaultAgentRegistry(registrations: [], hideClaudeSDKSessions: true)
        let codexRule = CmuxVaultAgentRegistry(
            registrations: [],
            sessionExclusions: [CmuxVaultSessionExclusion(agent: "codex")]
        )
        let anyAgentRule = CmuxVaultAgentRegistry(
            registrations: [],
            sessionExclusions: [CmuxVaultSessionExclusion(folder: "/scratch/*")]
        )

        #expect(sdkOnly.hasSessionExclusions(for: .claude))
        #expect(!sdkOnly.hasSessionExclusions(for: .codex))
        #expect(codexRule.hasSessionExclusions(for: .codex))
        #expect(!codexRule.hasSessionExclusions(for: .claude))
        #expect(anyAgentRule.hasSessionExclusions(for: .claude))
        #expect(anyAgentRule.hasSessionExclusions(for: .codex))
    }

    @Test("Codex's SQL reader exposes the thread source as the entrypoint")
    func codexSQLReadsSourceAsEntrypoint() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-codex-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let stateDB = tempDir.appendingPathComponent("state_5.sqlite")

        var db: OpaquePointer?
        guard sqlite3_open(stateDB.path, &db) == SQLITE_OK, let db else {
            Issue.record("open failed")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, source TEXT NOT NULL,
          cwd TEXT NOT NULL, title TEXT NOT NULL, sandbox_policy TEXT NOT NULL,
          approval_mode TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
          git_branch TEXT, first_user_message TEXT NOT NULL DEFAULT '',
          model TEXT, reasoning_effort TEXT, updated_at_ms INTEGER
        );
        INSERT INTO threads (id, rollout_path, source, cwd, title, sandbox_policy, approval_mode, updated_at_ms)
        VALUES ('codex-exec', '/tmp/rollout-exec.jsonl', 'exec', '/work', 'Batch job', '{}', 'never', 2000),
               ('codex-cli', '/tmp/rollout-cli.jsonl', 'cli', '/work', 'Pairing', '{}', 'never', 1000);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

        let outcome = await SessionIndexStore.loadCodexEntriesForTesting(
            stateDBPath: stateDB.path,
            needle: ""
        )
        let registry = CmuxVaultAgentRegistry(
            registrations: [],
            sessionExclusions: [CmuxVaultSessionExclusion(agent: "codex", entrypoint: "exec")]
        )

        #expect(outcome.errors == [])
        #expect(outcome.entries.map(\.entrypoint) == ["exec", "cli"])
        #expect(outcome.entries.filter { !registry.excludes($0) }.map(\.sessionId) == ["codex-cli"])
    }

    private func makeEntry(
        agent: SessionAgent,
        entrypoint: String? = nil,
        title: String = "session",
        cwd: String = "/work"
    ) -> SessionEntry {
        SessionEntry(
            id: agent.rawValue + ":" + title,
            agent: agent,
            sessionId: "session-id",
            title: title,
            entrypoint: entrypoint,
            cwd: cwd,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1),
            fileURL: nil,
            specifics: agent == .claude
                ? .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
                : .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
        )
    }
}
