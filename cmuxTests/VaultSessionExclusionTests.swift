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

    @Test("A filtered page parses later windows of one snapshot only until it is full")
    func filteredPageGrowsOverOneSnapshot() async {
        let source = (0..<200).map { makeEntry(agent: .claude, title: "s\($0)") }
        let hidden = Set(source.prefix(40).map(\.id))
        let windows = RangeRecorder()

        let page = await SessionIndexStore.growingWindowPage(
            candidateCount: source.count,
            offset: 5,
            limit: 10,
            cap: 1500,
            grows: true,
            parse: { range in
                windows.append(range)
                return Array(source[range])
            },
            isIncluded: { !hidden.contains($0.id) }
        )

        #expect(page.map(\.title) == (45..<55).map { "s\($0)" })
        #expect(windows.values == [0..<30, 30..<60])
    }

    @Test("A filtered page keeps parsing past windows the loader mostly drops")
    func filteredPageKeepsGrowingPastDroppedWindows() async {
        // Like Claude's loader: a window's sessions outside the folder or the
        // search are dropped, so a short window is not the end of the snapshot.
        let source = (0..<400).map { makeEntry(agent: .claude, title: "s\($0)") }
        let windows = RangeRecorder()

        let page = await SessionIndexStore.growingWindowPage(
            candidateCount: source.count,
            offset: 0,
            limit: 20,
            cap: 1500,
            grows: true,
            parse: { range in
                windows.append(range)
                return source[range].enumerated()
                    .filter { ($0.offset + range.lowerBound) % 10 == 0 }
                    .map(\.element)
            },
            isIncluded: { _ in true }
        )

        #expect(page.count == 20)
        #expect(windows.values == [0..<40, 40..<80, 80..<160, 160..<320])
    }

    @Test("A filtered page stops at the snapshot end or the cap, and an unfiltered page reads one window")
    func filteredPageStopsAtSnapshotEnd() async {
        let source = (0..<50).map { makeEntry(agent: .claude, title: "s\($0)") }
        let exhausted = RangeRecorder()
        let capped = RangeRecorder()
        let unfiltered = RangeRecorder()

        let short = await SessionIndexStore.growingWindowPage(
            candidateCount: source.count,
            offset: 0,
            limit: 30,
            cap: 1500,
            grows: true,
            parse: { range in
                exhausted.append(range)
                return Array(source[range])
            },
            isIncluded: { $0.title != "s0" }
        )
        _ = await SessionIndexStore.growingWindowPage(
            candidateCount: 10_000,
            offset: 0,
            limit: 100,
            cap: 120,
            grows: true,
            parse: { range in
                capped.append(range)
                return []
            },
            isIncluded: { _ in true }
        )
        _ = await SessionIndexStore.growingWindowPage(
            candidateCount: 10_000,
            offset: 0,
            limit: 30,
            cap: 1500,
            grows: false,
            parse: { range in
                unfiltered.append(range)
                return []
            },
            isIncluded: { _ in true }
        )

        #expect(short.count == 30)
        #expect(exhausted.values == [0..<50])
        #expect(capped.values == [0..<120])
        #expect(unfiltered.values == [0..<60])
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

    private final class RangeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Range<Int>] = []
        func append(_ value: Range<Int>) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(value)
        }
        var values: [Range<Int>] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
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
