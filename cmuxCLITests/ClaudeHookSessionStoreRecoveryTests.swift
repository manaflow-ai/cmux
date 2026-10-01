import Foundation
import Testing

/// Hook state recovery after decode drift, driven through the bundled CLI.
///
/// The CLI is a tool target that this bundle cannot import, so each test seeds
/// `claude-hook-sessions.json`, runs a real `hooks claude session-start`, and
/// reads back what the store persisted.
@Suite(.serialized)
struct ClaudeHookSessionStoreRecoveryTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let liveWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let liveSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let otherWorkspaceId = "33333333-3333-3333-3333-333333333333"
    private static let otherSurfaceId = "44444444-4444-4444-4444-444444444444"

    @Test("One malformed hook record does not discard valid session mappings")
    func malformedHookRecordDoesNotDiscardValidSessionMappings() throws {
        let context = try Harness.makeContext(name: "hook-store-salvage")
        defer { context.cleanup() }
        let validSessionId = "valid-hook-session"
        let malformedSessionId = "malformed-hook-session"
        let newSessionId = "new-hook-session"
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                validSessionId: [
                    "sessionId": validSessionId,
                    "workspaceId": Self.otherWorkspaceId,
                    "surfaceId": Self.otherSurfaceId,
                    "cwd": context.root.path,
                    "isRestorable": true,
                    "startedAt": now,
                    "updatedAt": now,
                ],
                malformedSessionId: [
                    "sessionId": 42,
                    "workspaceId": Self.otherWorkspaceId,
                    "surfaceId": Self.otherSurfaceId,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: context.storeURL)
        startServer(context: context)

        let result = runSessionStart(context: context, sessionId: newSessionId)

        assertSuccessfulHook(result)
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: context.storeURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        #expect(Set(sessions.keys) == [validSessionId, newSessionId])
        let valid = try #require(sessions[validSessionId] as? [String: Any])
        #expect(valid["workspaceId"] as? String == Self.otherWorkspaceId)
        #expect(valid["surfaceId"] as? String == Self.otherSurfaceId)
        #expect(quarantineBackups(in: context.root).isEmpty, "A salvageable store must not be quarantined")
    }

    @Test("Repeated hook state quarantine keeps every recovery backup")
    func repeatedHookStateQuarantineKeepsEveryRecoveryBackup() throws {
        let context = try Harness.makeContext(name: "hook-store-quarantine")
        defer { context.cleanup() }
        startServer(context: context)

        for attempt in 0..<2 {
            try Data(#"{"sessions":["#.utf8).write(to: context.storeURL, options: .atomic)
            let result = runSessionStart(context: context, sessionId: "quarantine-session-\(attempt)")
            assertSuccessfulHook(result)
        }

        #expect(quarantineBackups(in: context.root).count == 2)
    }

    /// One mock server serves every hook process in a test: its accept loop
    /// keeps running until the context closes the listener.
    private func startServer(context: Harness.Context) {
        _ = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.liveWorkspaceId: [Self.liveSurfaceId],
                Self.otherWorkspaceId: [Self.otherSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
    }

    private func runSessionStart(
        context: Harness.Context,
        sessionId: String
    ) -> Harness.ProcessRunResult {
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43401"
        return Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
    }

    private func quarantineBackups(in root: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        return entries.filter { $0.lastPathComponent.contains(".claude-hook-sessions.json.quarantined.") }
    }

    private func assertSuccessfulHook(_ result: Harness.ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
    }
}
