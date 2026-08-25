import CMUXAgentLaunch
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

    private func isRuntimeAuthorizedNotification(
        _ command: String,
        sessionID: String,
        generation: TimeInterval? = nil
    ) -> Bool {
        let runtimeKey = AgentRuntimeSessionKey(
            statusKey: "codex",
            sessionID: sessionID
        ).rawValue
        guard command.hasPrefix(
            "notify_target_async \(workspaceID) \(surfaceID) --runtime-key=\(runtimeKey) "
        ), command.contains(" -- Codex|") else {
            return false
        }
        return generation.map {
            command.contains("--runtime-generation=\($0)")
        } ?? true
    }

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

        let outcome = try runStop(
            root: root,
            sessionID: resumedSessionID,
            inheritedRuntimeGeneration: fixtureTimestamp
        )
        #expect(!outcome.result.timedOut, Comment(rawValue: outcome.result.stderr))
        #expect(outcome.result.status == 0, Comment(rawValue: outcome.result.stderr))
        #expect(
            outcome.commands.contains {
                isRuntimeAuthorizedNotification(
                    $0,
                    sessionID: resumedSessionID,
                    generation: fixtureTimestamp
                )
            },
            "A resumed turn completion must reach the notification command"
        )

        let savedPID = try persistedPID(sessionID: resumedSessionID, stateURL: stateURL)
        #expect(
            savedPID == Int(getpid()),
            "The resumed session must replace its dead pre-relaunch PID with the hook's live Codex PID"
        )
    }

    @Test("A dead recorded owner does not authorize an unrelated Stop process")
    func deadOwnerRejectsUnrelatedStopProcessWithoutInheritedGeneration() throws {
        let root = temporaryRoot("dead-owner")
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let deadOwnerPID = 999_999
        try writeState(
            [
                resumedSessionID: sessionRecord(
                    sessionID: resumedSessionID,
                    pid: deadOwnerPID,
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
            !outcome.commands.contains {
                isRuntimeAuthorizedNotification($0, sessionID: resumedSessionID)
            },
            "An unrelated process must not borrow a dead owner's stored generation"
        )
        #expect(try persistedPID(sessionID: resumedSessionID, stateURL: stateURL) == deadOwnerPID)
    }

    @Test("A live recorded owner prevents an unrelated Stop process from taking authority")
    func liveOwnerRejectsUnrelatedStopProcess() throws {
        let root = temporaryRoot("live-owner")
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let liveOwner = Process()
        liveOwner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        liveOwner.arguments = ["30"]
        liveOwner.standardOutput = FileHandle.nullDevice
        liveOwner.standardError = FileHandle.nullDevice
        try liveOwner.run()
        defer {
            if liveOwner.isRunning {
                liveOwner.terminate()
                liveOwner.waitUntilExit()
            }
        }

        try writeState(
            [
                resumedSessionID: sessionRecord(
                    sessionID: resumedSessionID,
                    pid: Int(liveOwner.processIdentifier),
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
            !outcome.commands.contains {
                isRuntimeAuthorizedNotification($0, sessionID: resumedSessionID)
            },
            "A Stop from a different live process must not publish under the recorded owner's session"
        )
        #expect(
            try persistedPID(sessionID: resumedSessionID, stateURL: stateURL)
                == Int(liveOwner.processIdentifier)
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
                isRuntimeAuthorizedNotification($0, sessionID: resumedSessionID)
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
                isRuntimeAuthorizedNotification(
                    $0,
                    sessionID: resumedSessionID,
                    generation: fixtureTimestamp
                )
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

    @Test("A new conversation overrides the restored process bootstrap generation")
    func newConversationUsesPIDMatchedGenerationInsteadOfStaleInheritedEnvironment() throws {
        let root = temporaryRoot("new-conversation-generation")
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let newSessionID = "55555555-5555-4555-8555-555555555555"
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

        let resumedStart = try runSessionStart(
            root: root,
            sessionID: resumedSessionID,
            inheritedRuntimeGeneration: fixtureTimestamp
        )
        #expect(resumedStart.result.status == 0, Comment(rawValue: resumedStart.result.stderr))
        #expect(
            try persistedRuntimeGeneration(sessionID: resumedSessionID, stateURL: stateURL)
                == fixtureTimestamp
        )

        let newStart = try runSessionStart(
            root: root,
            sessionID: newSessionID,
            inheritedRuntimeGeneration: fixtureTimestamp
        )
        #expect(newStart.result.status == 0, Comment(rawValue: newStart.result.stderr))
        let newGeneration = try persistedRuntimeGeneration(
            sessionID: newSessionID,
            stateURL: stateURL
        )
        #expect(newGeneration > fixtureTimestamp)

        let stop = try runStop(
            root: root,
            sessionID: newSessionID,
            inheritedRuntimeGeneration: fixtureTimestamp
        )
        #expect(stop.result.status == 0, Comment(rawValue: stop.result.stderr))
        #expect(
            stop.commands.contains {
                isRuntimeAuthorizedNotification(
                    $0,
                    sessionID: newSessionID,
                    generation: newGeneration
                )
            },
            "The live PID-matched record must override the process's stale restored environment"
        )
    }

    @Test("Runtime generations advance beyond a future persisted clock-era value")
    func runtimeGenerationSequenceAdvancesWithoutWallClockOrdering() throws {
        let root = temporaryRoot("monotonic-sequence")
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let sessionID = "66666666-6666-4666-8666-666666666666"
        let futureHighWaterMark: TimeInterval = 9_000_000_000
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeState(
            [:],
            to: stateURL,
            runtimeGenerationHighWaterMark: futureHighWaterMark
        )
        let start = try runSessionStart(root: root, sessionID: sessionID)
        #expect(start.result.status == 0, Comment(rawValue: start.result.stderr))
        #expect(
            try persistedRuntimeGeneration(sessionID: sessionID, stateURL: stateURL)
                > futureHighWaterMark,
            "A new boundary must advance the durable sequence even when wall time is earlier"
        )
    }

    @Test("A reset hook store advances beyond the app's retained generation floor")
    func resetHookStoreReconcilesWithAppGenerationFloor() throws {
        let root = temporaryRoot("reset-store-app-floor")
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let sessionID = "77777777-7777-4777-8777-777777777777"
        let appRuntimeGenerationFloor: TimeInterval = 500
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
        let start = try runSessionStart(
            root: root,
            sessionID: sessionID,
            appRuntimeGenerationFloor: appRuntimeGenerationFloor
        )

        #expect(start.result.status == 0, Comment(rawValue: start.result.stderr))
        #expect(
            try persistedRuntimeGeneration(sessionID: sessionID, stateURL: stateURL)
                > appRuntimeGenerationFloor
        )
        let floorRequest = start.commands.compactMap(codexHookJSONObject).first { payload in
            guard payload["method"] as? String == "surface.resume.get",
                  let params = payload["params"] as? [String: Any] else {
                return false
            }
            return params["runtime_status_key"] as? String == "codex"
        }
        #expect(floorRequest != nil)
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
            "runtimeGeneration": updatedAt,
            "startedAt": updatedAt,
            "updatedAt": updatedAt,
        ]
    }

    private func writeState(
        _ sessions: [String: [String: Any]],
        to stateURL: URL,
        runtimeGenerationHighWaterMark: TimeInterval? = nil
    ) throws {
        var state: [String: Any] = [
            "version": 1,
            "sessions": sessions,
        ]
        if let runtimeGenerationHighWaterMark {
            state["runtimeGenerationHighWaterMark"] = runtimeGenerationHighWaterMark
        }
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
    }

    private func runStop(
        root: URL,
        sessionID: String,
        inheritedRuntimeGeneration: TimeInterval? = nil
    ) throws -> (result: CodexHookProcessRunResult, commands: [String]) {
        try runLifecycleHook(
            root: root,
            sessionID: sessionID,
            subcommand: "stop",
            eventName: "Stop",
            inheritedRuntimeGeneration: inheritedRuntimeGeneration
        )
    }

    private func runSessionStart(
        root: URL,
        sessionID: String,
        inheritedRuntimeGeneration: TimeInterval? = nil,
        appRuntimeGenerationFloor: TimeInterval? = nil
    ) throws -> (result: CodexHookProcessRunResult, commands: [String]) {
        try runLifecycleHook(
            root: root,
            sessionID: sessionID,
            subcommand: "session-start",
            eventName: "SessionStart",
            inheritedRuntimeGeneration: inheritedRuntimeGeneration,
            appRuntimeGenerationFloor: appRuntimeGenerationFloor
        )
    }

    private func runLifecycleHook(
        root: URL,
        sessionID: String,
        subcommand: String,
        eventName: String,
        inheritedRuntimeGeneration: TimeInterval?,
        appRuntimeGenerationFloor: TimeInterval? = nil
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
            connectionLimit: 48,
            runtimeGenerationFloor: appRuntimeGenerationFloor
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: CLICodexResumeNotificationBundleMarker.self
        )
        var environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceID,
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CODEX_PID": String(getpid()),
        ]
        if let inheritedRuntimeGeneration {
            environment[
                AgentRuntimeSessionKey.runtimeGenerationEnvironmentKey
            ] = String(inheritedRuntimeGeneration)
        }
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", subcommand],
            environment: environment,
            standardInput: """
            {"session_id":"\(sessionID)","turn_id":"turn-resumed","cwd":"\(root.path)","hook_event_name":"\(eventName)","last_assistant_message":"resumed turn complete"}
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
                "--runtime-generation", String(fixtureTimestamp),
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

    private func persistedRuntimeGeneration(
        sessionID: String,
        stateURL: URL
    ) throws -> TimeInterval {
        let state = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(state["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionID] as? [String: Any])
        return try #require(session["runtimeGeneration"] as? TimeInterval)
    }
}
