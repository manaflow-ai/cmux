import Foundation
import Testing

@testable import cmux_cli

@Suite(.serialized)
struct ClaudeHookSessionStoreRecoveryTests {
    @Test("One malformed hook record does not discard valid session mappings")
    func malformedHookRecordDoesNotDiscardValidSessionMappings() throws {
        let validSessionID = "valid-hook-session"
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessions": [
                validSessionID: [
                    "sessionId": validSessionID,
                    "workspaceId": "workspace-valid",
                    "surfaceId": "surface-valid",
                    "startedAt": 1,
                    "updatedAt": 2,
                ],
                "malformed-hook-session": [
                    "sessionId": 42,
                    "workspaceId": "workspace-malformed",
                    "surfaceId": "surface-malformed",
                    "startedAt": 1,
                    "updatedAt": 2,
                ],
            ],
        ])

        let decoded = try JSONDecoder().decode(ClaudeHookSessionStoreFile.self, from: data)
        #expect(decoded.sessions.count == 1)
        #expect(decoded.sessions[validSessionID]?.workspaceId == "workspace-valid")
    }

    @Test("Repeated hook state quarantine keeps every recovery backup")
    func repeatedHookStateQuarantineKeepsEveryRecoveryBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-state-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        let environment = ["CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path]
        let store = ClaudeHookSessionStore(processEnv: environment)

        for _ in 0..<2 {
            try Data(#"{"sessions":["#.utf8).write(to: stateURL, options: .atomic)
            #expect(try store.lookup(sessionId: "any-session") == nil)
        }

        let backups = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent.contains(".claude-hook-sessions.json.quarantined.") }
        #expect(backups.count == 2)
    }
}
