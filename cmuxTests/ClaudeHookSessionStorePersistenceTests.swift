import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct ClaudeHookSessionStorePersistenceTests {
    @Test func updatesExistingSessionWithLatestHookEventAndClearsSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let statePath = root.appendingPathComponent("sessions.json").path
        let store = ClaudeHookSessionStore(processEnv: ["CMUX_CLAUDE_HOOK_STATE_PATH": statePath])
        _ = try store.upsert(
            sessionId: "session-1",
            workspaceId: "workspace-1",
            surfaceId: "surface-1",
            agentLifecycle: .needsInput,
            hookEventName: "PermissionRequest",
            lastSubtitle: "Permission",
            lastBody: "Allow this command"
        )

        let waiting = try #require(store.lookup(sessionId: "session-1"))
        #expect(waiting.hookEventName == "PermissionRequest")
        #expect(waiting.lastSubtitle == "Permission")
        #expect(waiting.lastBody == "Allow this command")

        _ = try store.upsert(
            sessionId: "session-1",
            workspaceId: "workspace-1",
            surfaceId: "surface-1",
            agentLifecycle: .running,
            hookEventName: "UserPromptSubmit",
            updateLastSummary: true
        )

        let running = try #require(store.lookup(sessionId: "session-1"))
        #expect(running.hookEventName == "UserPromptSubmit")
        #expect(running.lastSubtitle == nil)
        #expect(running.lastBody == nil)
    }

    @Test func decodesLegacyRecordWithoutHookEventName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-store-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let statePath = root.appendingPathComponent("sessions.json")
        let legacyJSON = """
        {
          "version": 1,
          "sessions": {
            "legacy-session": {
              "sessionId": "legacy-session",
              "workspaceId": "workspace-1",
              "surfaceId": "surface-1",
              "startedAt": 1,
              "updatedAt": 2
            }
          }
        }
        """
        try Data(legacyJSON.utf8).write(to: statePath)

        let store = ClaudeHookSessionStore(processEnv: ["CMUX_CLAUDE_HOOK_STATE_PATH": statePath.path])
        let decoded = try #require(store.lookup(sessionId: "legacy-session"))
        #expect(decoded.hookEventName == nil)
        #expect(decoded.sessionId == "legacy-session")
    }
}
