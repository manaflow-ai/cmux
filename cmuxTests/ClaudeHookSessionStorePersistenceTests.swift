import Foundation
import Testing

/// Exercises the CLI-owned hook store through the bundled hook command.
///
/// `ClaudeHookSessionStore` belongs to the `cmux-cli` executable target, while
/// this test bundle is hosted by the app target and cannot link executable
/// symbols. Running the real hook path keeps this coverage behavioral and
/// verifies the same persistence boundary used by Claude in production.
@Suite(.serialized)
struct ClaudeHookSessionStorePersistenceTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let workspaceId = "11111111-1111-1111-1111-111111111111"
    private static let surfaceId = "22222222-2222-2222-2222-222222222222"

    @Test func updatesExistingSessionWithLatestHookEventAndClearsSummary() throws {
        let context = try Harness.makeContext(name: "hook-store-update")
        defer { context.cleanup() }
        let sessionId = "hook-store-update-session"
        try writeStore(
            to: context.storeURL,
            sessionId: sessionId,
            hookEventName: "PermissionRequest",
            lastSubtitle: "Permission",
            lastBody: "Allow this command"
        )

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.workspaceId: [Self.surfaceId]],
            pidTarget: nil,
            surfaceTargets: [Self.surfaceId: Self.workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_WORKSPACE_ID"] = Self.workspaceId
        environment["CMUX_SURFACE_ID"] = Self.surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "claude", "pre-tool-use",
                "--workspace", Self.workspaceId,
                "--surface", Self.surfaceId,
            ],
            environment: environment,
            standardInput: "{\"session_id\":\"\(sessionId)\",\"turn_id\":\"turn-1\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"\(context.root.path)\"}"
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let savedRecord = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        let saved = try #require(savedRecord)
        #expect(saved["hookEventName"] as? String == "PreToolUse")
        #expect(saved["lastSubtitle"] == nil)
        #expect(saved["lastBody"] == nil)
    }

    @Test func decodesLegacyRecordWithoutHookEventName() throws {
        let context = try Harness.makeContext(name: "hook-store-legacy")
        defer { context.cleanup() }
        let sessionId = "legacy-session"
        let now = Date().timeIntervalSince1970
        let legacyJSON = """
        {
          "version": 1,
          "sessions": {
            "\(sessionId)": {
              "sessionId": "\(sessionId)",
              "workspaceId": "\(Self.workspaceId)",
              "surfaceId": "\(Self.surfaceId)",
              "cwd": "\(context.root.path)",
              "isRestorable": true,
              "startedAt": \(now),
              "updatedAt": \(now)
            }
          }
        }
        """
        try Data(legacyJSON.utf8).write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.workspaceId: [Self.surfaceId]],
            pidTarget: nil,
            surfaceTargets: [Self.surfaceId: Self.workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_WORKSPACE_ID"] = Self.workspaceId
        environment["CMUX_SURFACE_ID"] = Self.surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "claude", "prompt-submit",
                "--workspace", Self.workspaceId,
                "--surface", Self.surfaceId,
            ],
            environment: environment,
            standardInput: "{\"session_id\":\"\(sessionId)\",\"turn_id\":\"turn-legacy\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"\(context.root.path)\"}"
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let decodedRecord = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        let decoded = try #require(decodedRecord)
        #expect(decoded["hookEventName"] as? String == "UserPromptSubmit")
        #expect(decoded["sessionId"] as? String == sessionId)
    }

    private func writeStore(
        to url: URL,
        sessionId: String,
        hookEventName: String,
        lastSubtitle: String,
        lastBody: String
    ) throws {
        let now = Date().timeIntervalSince1970
        let record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": Self.workspaceId,
            "surfaceId": Self.surfaceId,
            "cwd": url.deletingLastPathComponent().path,
            "isRestorable": true,
            "hookEventName": hookEventName,
            "lastSubtitle": lastSubtitle,
            "lastBody": lastBody,
            "startedAt": now,
            "updatedAt": now,
        ]
        let store: [String: Any] = [
            "version": 1,
            "sessions": [sessionId: record],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func assertSuccessfulHook(_ result: Harness.ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }
}
