import Foundation
import Testing

/// Verifies that Codex session-start identity survives a process restart.
@Suite
struct CLICodexSessionStartPIDRegressionTests {
    @Test
    func newPIDSessionStartRetainsCompletedTurnMarkerForDuplicateGuard() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-new-pid-start-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-new-pid")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-new-pid-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": 1,
                    "agentLifecycle": "idle",
                    "runtimeStatus": "idle",
                    "lastPromptTurnId": "turn-done",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 16
        )

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CODEX_PID": "2",
        ]
        let payload = #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#

        let firstStart = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: environment,
            standardInput: payload,
            timeout: 5
        )
        #expect(!firstStart.timedOut, Comment(rawValue: firstStart.stderr))
        #expect(firstStart.status == 0, Comment(rawValue: firstStart.stderr))
        #expect(firstStart.stdout == "{}\n")
        let firstStartCommands = commands.snapshot()
        #expect(
            AgentJournalAppendCapture.contains(firstStartCommands, kind: "agent.session.started", agentKey: "codex"),
            "A fresh SessionStart with a new PID must be accepted"
        )
        #expect(
            firstStartCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" },
            "An accepted SessionStart must publish its resume binding"
        )

        let savedAfterFirstStart = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessionsAfterFirstStart = try #require(savedAfterFirstStart["sessions"] as? [String: Any])
        let sessionAfterFirstStart = try #require(sessionsAfterFirstStart[sessionId] as? [String: Any])
        #expect(sessionAfterFirstStart["pid"] as? Int == 2)
        #expect(sessionAfterFirstStart["lastPromptTurnId"] as? String == "turn-done")

        let commandsBeforeDuplicate = commands.snapshot().count
        let duplicateStart = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: environment,
            standardInput: payload,
            timeout: 5
        )
        #expect(!duplicateStart.timedOut, Comment(rawValue: duplicateStart.stderr))
        #expect(duplicateStart.status == 0, Comment(rawValue: duplicateStart.stderr))
        #expect(duplicateStart.stdout == "{}\n")

        let duplicateCommands = Array(commands.snapshot().dropFirst(commandsBeforeDuplicate))
        #expect(
            !AgentJournalAppendCapture.contains(duplicateCommands, kind: "agent.session.started", agentKey: "codex"),
            "A duplicate SessionStart from the accepted PID must remain stale"
        )
        #expect(
            !duplicateCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" },
            "A duplicate SessionStart must not publish another resume binding"
        )
    }
}
