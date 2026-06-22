import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testCopilotHookInstallWritesToHooksSubdirectory() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-copilot-hook-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "copilot", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let hookURL = root
            .appendingPathComponent(".copilot", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any],
            "Expected hook file at ~/.copilot/hooks/cmux.json"
        )

        XCTAssertEqual(json["version"] as? Int, 1)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])

        XCTAssertNotNil(hooks["SessionStart"], "Missing SessionStart hook")
        XCTAssertNotNil(hooks["Stop"], "Missing Stop hook")
        XCTAssertNotNil(hooks["Notification"], "Missing Notification hook")
        XCTAssertNotNil(hooks["SessionEnd"], "Missing SessionEnd hook")
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertTrue(
            preToolUse.contains {
                ($0["command"] as? String)?.contains("hooks feed --source copilot --event PreToolUse") == true
                    && ($0["type"] as? String) == "command"
                    && ($0["timeoutSec"] as? Int) == 125
                    && $0["hooks"] == nil
            },
            "Expected direct PreToolUse command hook with timeout slack, saw \(preToolUse)"
        )
    }

    func testCopilotFeedDecisionEmitsPreToolUsePermissionDecision() throws {
        func runCopilotDecision(mode: String) throws -> (ProcessRunResult, [String: Any]) {
            let cliPath = try bundledCLIPath()
            let socketPath = makeSocketPath("copilot-feed-decision")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-copilot-feed-decision-\(UUID().uuidString)", isDirectory: true)
            let workspaceId = "33333333-3333-3333-3333-333333333333"
            let surfaceId = "44444444-4444-4444-4444-444444444444"

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line) else {
                    return self.malformedRequestResponse(raw: line)
                }
                guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
                }
                XCTAssertEqual(method, "feed.push")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "status": "resolved",
                        "decision": ["kind": "permission", "mode": mode],
                    ]
                )
            }

            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", "copilot", "--event", "PreToolUse"],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": workspaceId,
                    "CMUX_SURFACE_ID": surfaceId,
                    "CMUX_COPILOT_PID": "525252",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"hook_event_name":"PreToolUse","session_id":"copilot-session-123","cwd":"\#(root.path)","tool_name":"Bash","tool_input":{"command":"touch \#(root.appendingPathComponent("README.md").path)"}}"#,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)

            let feedEvents = state.commands.compactMap { command -> [String: Any]? in
                guard let payload = self.jsonObject(command),
                      payload["method"] as? String == "feed.push",
                      let params = payload["params"] as? [String: Any],
                      let event = params["event"] as? [String: Any] else {
                    return nil
                }
                return event
            }
            XCTAssertEqual(feedEvents.count, 1, "Expected one Copilot Feed event, saw \(state.commands)")
            return (result, try XCTUnwrap(feedEvents.first))
        }

        let (allow, allowEvent) = try runCopilotDecision(mode: "once")
        XCTAssertFalse(allow.timedOut, allow.stderr)
        XCTAssertEqual(allow.status, 0, allow.stderr)
        XCTAssertEqual(allowEvent["hook_event_name"] as? String, "PermissionRequest")
        XCTAssertEqual(allowEvent["_source"] as? String, "copilot")
        XCTAssertEqual(allowEvent["_ppid"] as? Int, 525252)
        let allowOutput = try XCTUnwrap(jsonObject(allow.stdout))
        XCTAssertEqual(allowOutput["permissionDecision"] as? String, "allow")
        XCTAssertNil(allowOutput["hookSpecificOutput"])

        let (deny, _) = try runCopilotDecision(mode: "deny")
        XCTAssertFalse(deny.timedOut, deny.stderr)
        XCTAssertEqual(deny.status, 0, deny.stderr)
        let denyOutput = try XCTUnwrap(jsonObject(deny.stdout))
        XCTAssertEqual(denyOutput["permissionDecision"] as? String, "deny")
        XCTAssertEqual(denyOutput["permissionDecisionReason"] as? String, "User denied permission via cmux Feed.")
        XCTAssertNil(denyOutput["hookSpecificOutput"])
    }
}
