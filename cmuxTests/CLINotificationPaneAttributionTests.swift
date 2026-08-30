import Darwin
import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    /// Regression for https://github.com/manaflow-ai/cmux/issues/11189: when
    /// the ambient surface is stale and the live resolver cannot prove a pane,
    /// a generic hook must no-op instead of using the workspace's focused tab.
    func testCodexPromptSubmitWithStaleSurfaceAndNoLiveEvidenceFailsClosed() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-stale-no-live")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-no-live-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurfaceId = "22222222-2222-2222-2222-222222222222"
        let focusedSurfaceId = "33333333-3333-3333-3333-333333333333"
        let probePath = root.appendingPathComponent("target-resolution-error.txt", isDirectory: false)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "agent.resolve_delivery_target":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "method_not_found", "message": "Legacy app without live resolver"]
                )
            case "system.top":
                return self.v2Response(id: id, ok: true, result: ["windows": []])
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                guard params["workspace_id"] as? String == workspaceId else {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "Workspace not found"]
                    )
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": focusedSurfaceId,
                                "ref": "surface:1",
                                "focused": true,
                            ],
                        ],
                    ]
                )
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH"] = probePath.path
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path
        environment.removeValue(forKey: "CMUX_CODEX_PID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"codex-stale-no-live","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(
            state.commands.contains { $0.contains("notify_target_async") || $0.contains("set_status codex") },
            "A stale surface with no live proof must not mutate the focused pane, saw \(state.commands)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: probePath.path),
            "Fail-closed target resolution must leave a diagnostic"
        )
    }
}
