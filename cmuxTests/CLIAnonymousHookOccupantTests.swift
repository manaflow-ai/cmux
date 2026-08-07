import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testLateAnonymousHookCannotMutateReplacementOccupant() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("anonymous-occupant")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-anonymous-occupant-\(UUID().uuidString)", isDirectory: true)
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startDetachedAgentHookMockServer(
            listenerFD: listenerFD,
            state: state,
            surfaceId: surfaceID,
            connectionCount: 80
        )

        func runKiroHook(_ subcommand: String, pid: Int, eventName: String) -> ProcessRunResult {
            runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "kiro", subcommand],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": workspaceID,
                    "CMUX_SURFACE_ID": surfaceID,
                    "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                    "CMUX_KIRO_PID": String(pid),
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"cwd":"\#(root.path)","hook_event_name":"\#(eventName)"}"#,
                timeout: 5
            )
        }

        let firstAgent = Process()
        firstAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        firstAgent.arguments = ["30"]
        let replacementAgent = Process()
        replacementAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        replacementAgent.arguments = ["30"]
        try firstAgent.run()
        try replacementAgent.run()
        defer {
            for process in [firstAgent, replacementAgent] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let firstPID = Int(firstAgent.processIdentifier)
        let replacementPID = Int(replacementAgent.processIdentifier)
        for pid in [firstPID, replacementPID] {
            let start = runKiroHook(
                "session-start",
                pid: pid,
                eventName: "SessionStart"
            )
            XCTAssertFalse(start.timedOut, start.stderr)
            XCTAssertEqual(start.status, 0, start.stderr)
            XCTAssertEqual(start.stdout, "{}\n")
        }

        let delayedStartCommandOffset = state.snapshot().count
        let delayedOlderStart = runKiroHook(
            "session-start",
            pid: firstPID,
            eventName: "SessionStart"
        )
        XCTAssertFalse(delayedOlderStart.timedOut, delayedOlderStart.stderr)
        XCTAssertEqual(delayedOlderStart.status, 0, delayedOlderStart.stderr)
        XCTAssertEqual(delayedOlderStart.stdout, "{}\n")
        let delayedStartCommands = Array(state.snapshot().dropFirst(delayedStartCommandOffset))
        XCTAssertFalse(
            delayedStartCommands.contains {
                $0.hasPrefix("set_agent_pid ")
                    || $0.hasPrefix("set_agent_lifecycle ")
                    || $0.hasPrefix("set_status ")
                    || $0.hasPrefix("clear_notifications ")
                    || $0.hasPrefix("notify_target_async ")
            },
            "A delayed older SessionStart must not reclaim durable or app ownership: \(delayedStartCommands)"
        )

        let lateCommandStart = state.snapshot().count
        let latePrompt = runKiroHook(
            "prompt-submit",
            pid: firstPID,
            eventName: "UserPromptSubmit"
        )
        XCTAssertFalse(latePrompt.timedOut, latePrompt.stderr)
        XCTAssertEqual(latePrompt.status, 0, latePrompt.stderr)
        XCTAssertEqual(latePrompt.stdout, "{}\n")
        let lateCommands = Array(state.snapshot().dropFirst(lateCommandStart))
        XCTAssertFalse(
            lateCommands.contains {
                $0.hasPrefix("set_agent_lifecycle ")
                    || $0.hasPrefix("set_status ")
                    || $0.hasPrefix("clear_notifications ")
                    || $0.hasPrefix("notify_target_async ")
            },
            "A late hook from the replaced anonymous process must not mutate the current occupant: \(lateCommands)"
        )

        let currentCommandStart = state.snapshot().count
        let currentPrompt = runKiroHook(
            "prompt-submit",
            pid: replacementPID,
            eventName: "UserPromptSubmit"
        )
        XCTAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.stdout, "{}\n")
        let currentCommands = Array(state.snapshot().dropFirst(currentCommandStart))
        XCTAssertTrue(
            currentCommands.contains {
                $0.hasPrefix("set_agent_lifecycle kiro running ")
                    && $0.contains("--expected-pid-key=kiro.\(surfaceID)")
                    && $0.contains("--expected-pid=\(replacementPID)")
            },
            "The current anonymous occupant must report lifecycle state with its PID token: \(currentCommands)"
        )
        XCTAssertFalse(
            currentCommands.contains { $0.hasPrefix("set_agent_pid ") },
            "Only anonymous session-start may claim PID ownership: \(currentCommands)"
        )

        let teardownCommandStart = state.snapshot().count
        let currentTeardown = runKiroHook(
            "session-end",
            pid: replacementPID,
            eventName: "SessionEnd"
        )
        XCTAssertFalse(currentTeardown.timedOut, currentTeardown.stderr)
        XCTAssertEqual(currentTeardown.status, 0, currentTeardown.stderr)
        XCTAssertEqual(currentTeardown.stdout, "{}\n")
        let teardownCommands = Array(state.snapshot().dropFirst(teardownCommandStart))
        XCTAssertTrue(
            teardownCommands.contains {
                $0.hasPrefix("clear_agent_pid kiro.\(surfaceID) ")
                    && $0.contains("--expected-pid=\(replacementPID)")
            },
            "Anonymous teardown must clear only the PID occupant it consumed: \(teardownCommands)"
        )
        XCTAssertTrue(
            teardownCommands.contains {
                guard let payload = self.jsonObject($0),
                      payload["method"] as? String == "surface.resume.clear",
                      let params = payload["params"] as? [String: Any] else {
                    return false
                }
                return (params["_cmux_expected_updated_at"] as? NSNumber)?.doubleValue == 123.25
            },
            "Anonymous teardown must compare-and-clear the binding revision it published: \(teardownCommands)"
        )
    }

    func testLateRovoDevHookCannotMutateReplacementOccupantSharingInferredSessionID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rovo-occupant")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-occupant-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let workspaceID = "33333333-3333-3333-3333-333333333333"
        let surfaceID = "44444444-4444-4444-4444-444444444444"

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try writeRovoDevSessionMetadata(
            sessionsRoot: sessionsRoot,
            sessionId: "workspace-scoped-session",
            workspacePath: workspace.path,
            modified: Date(timeIntervalSince1970: 200)
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startDetachedAgentHookMockServer(
            listenerFD: listenerFD,
            state: state,
            surfaceId: surfaceID,
            connectionCount: 80
        )

        func runRovoDevHook(_ subcommand: String, pid: Int, eventName: String) -> ProcessRunResult {
            runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "rovodev", subcommand],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": workspace.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": workspaceID,
                    "CMUX_SURFACE_ID": surfaceID,
                    "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                    "CMUX_ROVODEV_SESSIONS_DIR": sessionsRoot.path,
                    "CMUX_ROVODEV_PID": String(pid),
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"cwd":"\#(workspace.path)","hook_event_name":"\#(eventName)"}"#,
                timeout: 5
            )
        }

        let firstAgent = Process()
        firstAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        firstAgent.arguments = ["30"]
        let replacementAgent = Process()
        replacementAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        replacementAgent.arguments = ["30"]
        try firstAgent.run()
        try replacementAgent.run()
        defer {
            for process in [firstAgent, replacementAgent] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let firstPID = Int(firstAgent.processIdentifier)
        let replacementPID = Int(replacementAgent.processIdentifier)
        for pid in [firstPID, replacementPID] {
            let start = runRovoDevHook(
                "session-start",
                pid: pid,
                eventName: "session_start"
            )
            XCTAssertFalse(start.timedOut, start.stderr)
            XCTAssertEqual(start.status, 0, start.stderr)
            XCTAssertEqual(start.stdout, "{}\n")
        }
        let startLifecycleCommands = state.snapshot().filter {
            $0.hasPrefix("set_agent_lifecycle rovodev unknown ")
        }
        XCTAssertEqual(startLifecycleCommands.count, 2, "\(startLifecycleCommands)")
        XCTAssertTrue(
            startLifecycleCommands.allSatisfy { $0.contains("--new-occupant") },
            "Every Rovo Dev start must rotate its anonymous occupant generation: \(startLifecycleCommands)"
        )
        XCTAssertFalse(
            startLifecycleCommands.contains { $0.contains("--session-id=") },
            "Workspace-scoped inferred Rovo Dev metadata must not become authoritative occupant identity: \(startLifecycleCommands)"
        )

        let lateCommandStart = state.snapshot().count
        let latePrompt = runRovoDevHook(
            "prompt-submit",
            pid: firstPID,
            eventName: "on_tool_permission"
        )
        XCTAssertFalse(latePrompt.timedOut, latePrompt.stderr)
        XCTAssertEqual(latePrompt.status, 0, latePrompt.stderr)
        XCTAssertEqual(latePrompt.stdout, "{}\n")
        let lateCommands = Array(state.snapshot().dropFirst(lateCommandStart))
        XCTAssertFalse(
            lateCommands.contains {
                $0.hasPrefix("set_agent_lifecycle ")
                    || $0.hasPrefix("set_status ")
                    || $0.hasPrefix("clear_notifications ")
                    || $0.hasPrefix("notify_target_async ")
            },
            "A late Rovo Dev hook sharing an inferred workspace session must not mutate the current occupant: \(lateCommands)"
        )

        let currentCommandStart = state.snapshot().count
        let currentPrompt = runRovoDevHook(
            "prompt-submit",
            pid: replacementPID,
            eventName: "on_tool_permission"
        )
        XCTAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.stdout, "{}\n")
        let currentCommands = Array(state.snapshot().dropFirst(currentCommandStart))
        XCTAssertTrue(
            currentCommands.contains {
                $0.hasPrefix("set_agent_lifecycle rovodev running ")
                    && $0.contains("--expected-pid-key=rovodev.workspace-scoped-session")
                    && $0.contains("--expected-pid=\(replacementPID)")
            },
            "The replacement Rovo Dev occupant must report lifecycle state with its PID token: \(currentCommands)"
        )
        XCTAssertFalse(
            currentCommands.contains { $0.hasPrefix("set_agent_pid ") },
            "Only anonymous Rovo Dev session-start may claim PID ownership: \(currentCommands)"
        )
    }
}
