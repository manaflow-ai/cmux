import CMUXAgentLaunch
import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Muse Code Vault registration")
struct MuseVaultRegistrationTests {
    @Test("Built-in Muse registration is loaded and owns the muse resume kind")
    func builtInRegistrationIsLoaded() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-muse-vault-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        let registration = try #require(registry.registration(id: "muse"))

        #expect(registration.isBuiltInMuse)
        #expect(registration.registeredResumeKind == .muse)
        #expect(registration.defaultExecutable == "muse")
        #expect(SessionSnapshotImportTrust.builtInRegistrationsByID["muse"] == .builtInMuse)
    }

    @Test("Vault lists top-level Muse sessions with a resume command in the session workspace")
    func vaultListsMuseSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-muse-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("session-index.db", isDirectory: false)
        try exec(dbURL, """
        CREATE TABLE sessions (
          session_id TEXT PRIMARY KEY, workspace_root TEXT, git_branch TEXT, title TEXT,
          session_name TEXT, first_user_prompt TEXT, search_text TEXT, prompt_count INTEGER,
          updated_at_us INTEGER, msp_kind TEXT, msp_parent_session_id TEXT
        );
        INSERT INTO sessions VALUES
          ('01a131ce-3556-7142-a0c8-c366cf09cfa5', '/work/muse repo', 'main', 'Ship Muse', NULL,
           'ship muse', 'ship muse', 3, 1700000200000000, NULL, NULL),
          ('child-session', '/work/muse repo', NULL, 'reminder', NULL, 'reminder', NULL, 1,
           1700000300000000, 'subagent', '01a131ce-3556-7142-a0c8-c366cf09cfa5');
        """)

        let outcome = SessionIndexStore.loadMuseEntriesForTesting(indexDBPath: dbURL.path)
        let entry = try #require(outcome.entries.first)

        #expect(outcome.errors.isEmpty)
        #expect(outcome.entries.count == 1)
        #expect(entry.agent == .registered(RegisteredSessionAgent(registration: .builtInMuse)))
        #expect(entry.title == "Ship Muse")
        #expect(entry.cwd == "/work/muse repo")
        #expect(entry.gitBranch == "main")
        let resume = try #require(entry.copyResumeCommand)
        #expect(
            resume
                == "cd -- '/work/muse repo' 2>/dev/null || [ ! -d '/work/muse repo' ] && 'muse' 'resume' '01a131ce-3556-7142-a0c8-c366cf09cfa5'"
        )
    }

    private func exec(_ dbURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw HermesAgentIndexError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw HermesAgentIndexError.sqlite(message)
        }
    }
}
