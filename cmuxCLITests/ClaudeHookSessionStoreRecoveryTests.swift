import Darwin
import Foundation
import Testing

/// Hook state recovery, driven through the bundled `cmux` binary.
///
/// The store and its file model live in the CLI executable, which this test
/// bundle cannot link, so each test seeds the hook state file, runs one real
/// `cmux hooks claude session-start` against it, and reads what the CLI left
/// on disk.
@Suite(.serialized)
struct ClaudeHookSessionStoreRecoveryTests {
    private let workspaceID = "55555555-5555-5555-5555-555555555555"
    private let surfaceID = "66666666-6666-6666-6666-666666666666"

    @Test("One malformed hook record does not discard valid session mappings")
    func malformedHookRecordDoesNotDiscardValidSessionMappings() throws {
        let root = try makeRoot("cmux-hook-state-salvage")
        defer { try? FileManager.default.removeItem(at: root) }
        let validSessionID = "valid-hook-session"
        let now = Date().timeIntervalSince1970
        let seeded = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessions": [
                validSessionID: [
                    "sessionId": validSessionID,
                    "workspaceId": "workspace-valid",
                    "surfaceId": "surface-valid",
                    "startedAt": now,
                    "updatedAt": now,
                ],
                "malformed-hook-session": [
                    "sessionId": 42,
                    "workspaceId": "workspace-malformed",
                    "surfaceId": "surface-malformed",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ])
        try seeded.write(to: stateURL(root), options: .atomic)

        try runSessionStart(root: root, sessionID: "fresh-hook-session")

        let sessions = try storedSessions(root)
        let valid = try #require(
            sessions[validSessionID] as? [String: Any],
            "The valid mapping must survive a malformed sibling record"
        )
        #expect(valid["workspaceId"] as? String == "workspace-valid")
        #expect(valid["surfaceId"] as? String == "surface-valid")
        #expect(sessions["malformed-hook-session"] == nil)
        #expect(sessions["fresh-hook-session"] != nil)
        #expect(try quarantineBackups(root).isEmpty, "A salvageable file is not quarantined")
    }

    @Test("Repeated hook state quarantine keeps every recovery backup")
    func repeatedHookStateQuarantineKeepsEveryRecoveryBackup() throws {
        let root = try makeRoot("cmux-hook-state-quarantine")
        defer { try? FileManager.default.removeItem(at: root) }

        for attempt in 0..<2 {
            try Data(#"{"sessions":["#.utf8).write(to: stateURL(root), options: .atomic)
            try runSessionStart(root: root, sessionID: "after-quarantine-\(attempt)")
        }

        let backups = try quarantineBackups(root)
        #expect(backups.count == 2, Comment(rawValue: backups.map(\.lastPathComponent).description))
        for backup in backups {
            #expect(try Data(contentsOf: backup) == Data(#"{"sessions":["#.utf8))
        }
        #expect(try storedSessions(root)["after-quarantine-1"] != nil)
    }

    private func makeRoot(_ prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stateURL(_ root: URL) -> URL {
        root.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
    }

    private func storedSessions(_ root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: stateURL(root))
        let store = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(store["sessions"] as? [String: Any])
    }

    private func quarantineBackups(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent.hasPrefix(".claude-hook-sessions.json.quarantined.") }
    }

    private func runSessionStart(root: URL, sessionID: String) throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self)
        let socketPath = makeCodexHookSocketPath("hook-store-recovery")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: CodexHookCapturedSocketCommands(),
            surfaceId: surfaceID,
            connectionLimit: 32,
            processBinding: CodexHookMockProcessBinding(
                processID: 1,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL(root).path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: """
            {"session_id":"\(sessionID)","source":"startup","hook_event_name":"SessionStart"}
            """,
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
    }
}
