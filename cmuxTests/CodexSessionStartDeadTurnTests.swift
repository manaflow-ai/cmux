import Darwin
import Foundation
import Testing
import CmuxFoundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CodexSessionStartDeadTurnTests {
    @Test("SessionStart retires a turn owned by a dead process")
    func deadTurnOwnerIsRetired() throws {
        try runSessionStart(storedPID: Int(Int32.max), storedGeneration: nil)
    }

    @Test("SessionStart retires a turn when the PID was reused")
    func reusedPIDTurnOwnerIsRetired() throws {
        let identity = try #require(AgentPIDProcessIdentity(pid: getpid()))
        try runSessionStart(
            storedPID: Int(getpid()),
            storedGeneration: (
                identity.startSeconds + 1,
                identity.startMicroseconds
            )
        )
    }

    private func runSessionStart(
        storedPID: Int,
        storedGeneration: (seconds: Int64, microseconds: Int64)?
    ) throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-dead-turn-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("dead-turn")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let sessionID = "codex-dead-turn-session"
        let incomingPID = Int(getpid())
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rolloutDirectory = codexHome.appendingPathComponent(
            "sessions/2026/09/22",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let transcriptURL = rolloutDirectory.appendingPathComponent("rollout-\(sessionID).jsonl")
        let rollout: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": sessionID,
                "cwd": root.path,
                "source": "cli",
                "originator": "codex-tui",
            ],
        ]
        try JSONSerialization.data(withJSONObject: rollout, options: [.sortedKeys])
            .write(to: transcriptURL, options: .atomic)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        var record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID,
            "surfaceId": surfaceID,
            "cwd": root.path,
            "pid": storedPID,
            "agentLifecycle": "idle",
            "runtimeStatus": "idle",
            "hookEventName": "Stop",
            "activePromptDepth": 1,
            "activePromptTurnId": "turn-stale",
            "activePromptTurnIds": ["turn-stale"],
            "lastPromptTurnId": "turn-stale",
            "startedAt": now,
            "updatedAt": now,
        ]
        if let storedGeneration {
            record["pidStartSeconds"] = storedGeneration.seconds
            record["pidStartMicroseconds"] = storedGeneration.microseconds
        }
        let store: [String: Any] = [
            "version": 1,
            "sessions": [sessionID: record],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceID,
            connectionLimit: 12,
            processBinding: CodexHookMockProcessBinding(
                processID: incomingPID,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CODEX_HOME": codexHome.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": String(incomingPID),
            ],
            standardInput: #"{"session_id":"\#(sessionID)","cwd":"\#(root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(AgentJournalAppendCapture.contains(sentCommands, kind: "agent.session.started", agentKey: "codex"))
        let resumeSet = try #require(
            sentCommands.compactMap(codexHookJSONObject).first {
                $0["method"] as? String == "surface.resume.set"
            }
        )
        let resumeParams = try #require(resumeSet["params"] as? [String: Any])
        #expect(resumeParams["auto_resume"] as? Bool == true)
        #expect(sentCommands.contains { $0.hasPrefix("set_agent_pid ") && $0.contains(" \(incomingPID) ") })

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionID] as? [String: Any])
        #expect(session["pid"] as? Int == incomingPID)
        #expect(session["agentLifecycle"] as? String == "unknown")
        #expect(session["runtimeStatus"] as? String == "running")
        #expect(session["activePromptDepth"] == nil)
        #expect(session["activePromptTurnId"] == nil)
        #expect(session["activePromptTurnIds"] == nil)
        #expect(session["lastPromptTurnId"] == nil)
    }
}
