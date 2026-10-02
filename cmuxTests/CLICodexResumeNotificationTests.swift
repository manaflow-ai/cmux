import Darwin
import Foundation
import Testing

private final class CLICodexResumeNotificationBundleMarker: NSObject {}

@Suite("Codex resumed-session notifications", .serialized)
struct CLICodexResumeNotificationTests {
    private let workspaceID = "11111111-1111-1111-1111-111111111111"
    private let surfaceID = "22222222-2222-2222-2222-222222222222"
    private let resumedSessionID = "33333333-3333-4333-8333-333333333333"
    private let fixtureTimestamp: TimeInterval = 1_778_888_888

    @Test("A Stop hook rebinds a resumed session to its live PID and notifies")
    func resumedStopRebindsLivePIDAndNotifies() throws {
        let root = temporaryRoot("live-pid")
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeState(
            [
                resumedSessionID: sessionRecord(
                    sessionID: resumedSessionID,
                    pid: 999_999,
                    runtimeStatus: "running",
                    updatedAt: fixtureTimestamp
                ),
            ],
            to: stateURL
        )

        let outcome = try runStop(root: root, sessionID: resumedSessionID)
        #expect(!outcome.result.timedOut, Comment(rawValue: outcome.result.stderr))
        #expect(outcome.result.status == 0, Comment(rawValue: outcome.result.stderr))
        #expect(
            outcome.commands.contains {
                $0.hasPrefix("notify_target_async \(workspaceID) \(surfaceID) Codex|")
            },
            "A resumed turn completion must reach the notification command"
        )

        let savedPID = try persistedPID(sessionID: resumedSessionID, stateURL: stateURL)
        #expect(
            savedPID == Int(getpid()),
            "The resumed session must replace its dead pre-relaunch PID with the hook's live Codex PID"
        )
    }

    @Test("A missing resumed record does not let an unrelated running session suppress completion")
    func missingResumedRecordFailsClosedAndNotifies() throws {
        let root = temporaryRoot("missing-record")
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let otherSessionID = "44444444-4444-4444-8444-444444444444"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeState(
            [
                otherSessionID: sessionRecord(
                    sessionID: otherSessionID,
                    pid: Int(getpid()),
                    runtimeStatus: "running",
                    updatedAt: fixtureTimestamp
                ),
            ],
            to: stateURL
        )

        let outcome = try runStop(root: root, sessionID: resumedSessionID)
        #expect(!outcome.result.timedOut, Comment(rawValue: outcome.result.stderr))
        #expect(outcome.result.status == 0, Comment(rawValue: outcome.result.stderr))
        #expect(
            outcome.commands.contains {
                $0.hasPrefix("notify_target_async \(workspaceID) \(surfaceID) Codex|")
            },
            "Without the excluded record there is no timestamp boundary, so suppression must fail closed"
        )
    }

    @Test("The rollout monitor recovers a dropped resumed Stop hook")
    func resumedRolloutCompletionReplaysStopAndNotifies() throws {
        let root = temporaryRoot("monitor-fallback")
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let transcriptURL = root.appendingPathComponent("rollout-\(resumedSessionID).jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var resumedRecord = sessionRecord(
            sessionID: resumedSessionID,
            pid: Int(getpid()),
            runtimeStatus: "running",
            updatedAt: fixtureTimestamp
        )
        resumedRecord["activePromptDepth"] = 1
        resumedRecord["activePromptTurnId"] = "turn-resumed"
        resumedRecord["activePromptTurnIds"] = ["turn-resumed"]
        try writeState([resumedSessionID: resumedRecord], to: stateURL)
        try """
        {"type":"session_meta","payload":{"id":"\(resumedSessionID)","cwd":"\(root.path)"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-resumed"}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"resumed turn complete"}]}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-resumed","last_agent_message":"resumed turn complete"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let outcome = try runMonitor(root: root, transcriptURL: transcriptURL)
        #expect(!outcome.result.timedOut, Comment(rawValue: outcome.result.stderr))
        #expect(outcome.result.status == 0, Comment(rawValue: outcome.result.stderr))
        #expect(
            outcome.commands.contains {
                $0.hasPrefix("notify_target_async \(workspaceID) \(surfaceID) Codex|")
            },
            "A task_complete rollout event must recover notification delivery when Codex drops Stop"
        )

        let duplicateNativeStop = try runStop(root: root, sessionID: resumedSessionID)
        #expect(!duplicateNativeStop.result.timedOut, Comment(rawValue: duplicateNativeStop.result.stderr))
        #expect(duplicateNativeStop.result.status == 0, Comment(rawValue: duplicateNativeStop.result.stderr))
        #expect(
            !duplicateNativeStop.commands.contains { $0.hasPrefix("notify_target_async ") },
            "A late native Stop for the same turn must not duplicate the recovered notification"
        )
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-resume-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func sessionRecord(
        sessionID: String,
        pid: Int,
        runtimeStatus: String,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        [
            "sessionId": sessionID,
            "workspaceId": workspaceID,
            "surfaceId": surfaceID,
            "pid": pid,
            "agentLifecycle": "running",
            "runtimeStatus": runtimeStatus,
            "startedAt": updatedAt,
            "updatedAt": updatedAt,
        ]
    }

    private func writeState(_ sessions: [String: [String: Any]], to stateURL: URL) throws {
        let state: [String: Any] = [
            "version": 1,
            "sessions": sessions,
        ]
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
    }

    private func runStop(
        root: URL,
        sessionID: String
    ) throws -> (result: CodexHookProcessRunResult, commands: [String]) {
        let socketPath = makeCodexHookSocketPath("resume")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceID,
            connectionLimit: 48
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: CLICodexResumeNotificationBundleMarker.self
        )
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": String(getpid()),
            ],
            standardInput: """
            {"session_id":"\(sessionID)","turn_id":"turn-resumed","cwd":"\(root.path)","hook_event_name":"Stop","last_assistant_message":"resumed turn complete"}
            """,
            timeout: 5
        )
        return (result, commands.snapshot())
    }

    private func runMonitor(
        root: URL,
        transcriptURL: URL
    ) throws -> (result: CodexHookProcessRunResult, commands: [String]) {
        let socketPath = makeCodexHookSocketPath("resume-monitor")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceID,
            connectionLimit: 48
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: CLICodexResumeNotificationBundleMarker.self
        )
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace", workspaceID,
                "--surface", surfaceID,
                "--session", resumedSessionID,
                "--turn", "turn-resumed",
                "--transcript", transcriptURL.path,
            ],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": String(getpid()),
            ],
            timeout: 5
        )
        return (result, commands.snapshot())
    }

    private func persistedPID(sessionID: String, stateURL: URL) throws -> Int {
        let state = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(state["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionID] as? [String: Any])
        return try #require(session["pid"] as? Int)
    }
}
