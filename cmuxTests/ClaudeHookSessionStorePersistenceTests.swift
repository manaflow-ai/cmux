import Foundation
import Testing

/// Exercises the hook-store persistence contract through the bundled CLI.
/// ClaudeHookSessionStore lives in the CLI helper target (rather than the app
/// module that hosts cmuxTests), so invoking the real hook entrypoint keeps
/// this coverage on the production serialization path.
@Suite(.serialized)
struct ClaudeHookSessionStorePersistenceTests {
    @Test func updatesExistingSessionWithLatestHookEventAndClearsSummary() throws {
        let support = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try support.makeClaudeHookContext(name: "claude-hook-store")
        defer { context.cleanup() }

        let sessionId = "session-1"
        let ttyName = "ttys-claude-hook-store"
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        try writeStore(
            to: storeURL,
            sessionId: sessionId,
            workspaceId: context.workspaceId,
            surfaceId: context.surfaceId,
            cwd: context.root.path,
            lastSubtitle: "Permission",
            lastBody: "Allow this command",
            lifecycle: "needsInput"
        )

        let serverHandled = support.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: ttyName,
            ttySurfaceId: context.surfaceId
        )
        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: support.claudeHookEnvironment(
                context: context,
                surfaceId: context.surfaceId,
                ttyName: ttyName,
                storeURL: storeURL
            ),
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        support.assertSuccessfulHook(result)

        let record = try persistedRecord(sessionId: sessionId, at: storeURL)
        #expect(record["hookEventName"] as? String == "UserPromptSubmit")
        #expect(record["lastSubtitle"] == nil)
        #expect(record["lastBody"] == nil)
    }

    @Test func decodesLegacyRecordWithoutHookEventName() throws {
        let support = ClaudeHookSurfaceResolutionSwiftTests()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-store-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("claude-hook-sessions.json")
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
        try Data(legacyJSON.utf8).write(to: storeURL)

        let result = support.runProcess(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self),
            arguments: [
                "sessions", "list",
                "--agent", "claude",
                "--state-dir", root.path,
                "--session", "legacy-session",
                "--all", "--json"
            ],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1"
            ],
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1)
        #expect(sessions[0]["session_id"] as? String == "legacy-session")
    }

    private func writeStore(
        to url: URL,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String,
        lastSubtitle: String,
        lastBody: String,
        lifecycle: String
    ) throws {
        let now = Date().timeIntervalSince1970
        let payload: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": cwd,
                    "isRestorable": true,
                    "agentLifecycle": lifecycle,
                    "lastSubtitle": lastSubtitle,
                    "lastBody": lastBody,
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "/usr/local/bin/claude",
                        "arguments": ["/usr/local/bin/claude"],
                        "workingDirectory": cwd,
                        "capturedAt": now,
                        "source": "test"
                    ],
                    "startedAt": now,
                    "updatedAt": now
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func persistedRecord(sessionId: String, at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try #require(object as? [String: Any])
        let sessions = try #require(root["sessions"] as? [String: Any])
        return try #require(sessions[sessionId] as? [String: Any])
    }
}
