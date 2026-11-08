import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    /// The Feed permission modes that allow a tool (`once` / `always` / `all`
    /// / `bypass`, the WorkstreamPermissionMode raw values) must exit 0 so
    /// Kiro proceeds; an unrecognized/malformed mode must fail closed with
    /// exit 2 rather than silently allowing the tool.
    func testKiroFeedAllowModesProceedAndUnknownModeDenies() throws {
        func runKiroDecision(mode: String) throws -> ProcessRunResult {
            let cliPath = try bundledCLIPath()
            let socketPath = makeSocketPath("kiro-feed-mode")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-kiro-feed-mode-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line), let id = payload["id"] as? String,
                      let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(raw: line)
                }
                if method == "agent.resolve_delivery_target" {
                    return self.v2Response(id: id, ok: true, result: [
                        "source": "surface",
                        "workspace_id": "33333333-3333-3333-3333-333333333333",
                        "surface_id": "44444444-4444-4444-4444-444444444444",
                    ])
                }
                if method == "agent.hook.barrier" {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
                guard method == "feed.push" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "unexpected_method", "message": method])
                }
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
                arguments: ["hooks", "feed", "--source", "kiro", "--event", "preToolUse"],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                    "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                    "CMUX_KIRO_PID": "525252",
                    "CMUX_KIRO_NOTIFICATION_LEVEL": "standard",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"hook_event_name":"preToolUse","session_id":"kiro-session-mode","cwd":"\#(root.path)","tool_name":"fs_write","tool_input":{"operations":[{"mode":"Line","path":"\#(root.appendingPathComponent("README.md").path)"}]}}"#,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            XCTAssertEqual(state.snapshot().filter { self.jsonObject($0)?["method"] as? String == "feed.push" }.count, 1)
            return result
        }

        for mode in ["once", "always", "all", "bypass"] {
            let result = try runKiroDecision(mode: mode)
            XCTAssertFalse(result.timedOut, "\(mode): \(result.stderr)")
            XCTAssertEqual(result.status, 0, "mode \(mode) should allow (exit 0): \(result.stderr)")
            XCTAssertEqual(result.stdout, "{}\n", "mode \(mode) should print {}")
        }

        let unknown = try runKiroDecision(mode: "totally-bogus-mode")
        XCTAssertFalse(unknown.timedOut, unknown.stderr)
        XCTAssertEqual(unknown.status, 2, "unrecognized mode must fail closed (exit 2): \(unknown.stderr)")
        XCTAssertTrue(unknown.stderr.contains("unrecognized"), unknown.stderr)
    }

}
