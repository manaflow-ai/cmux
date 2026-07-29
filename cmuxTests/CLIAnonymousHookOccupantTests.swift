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

        let firstPID = 41_001
        let replacementPID = 41_002
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
            },
            "The current anonymous occupant must continue reporting lifecycle state: \(currentCommands)"
        )
    }
}
