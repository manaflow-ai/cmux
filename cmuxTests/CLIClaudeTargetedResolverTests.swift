import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testClaudeTargetedResolverFailureWithLocalIdentityFailsClosed() throws {
        let outcome = try runClaudeTargetedResolverScenario(response: .failure)
        XCTAssertFalse(outcome.result.timedOut, outcome.result.stderr)
        XCTAssertEqual(outcome.result.status, 0, outcome.result.stderr)
        XCTAssertFalse(
            outcome.commands.contains { command in
                command.hasPrefix("set_status ")
                    || command.hasPrefix("notify_target")
                    || self.jsonObject(command)?["method"] as? String == "feed.push"
            },
            "A failed identity lookup must not mutate or publish through the ambient target: \(outcome.commands)"
        )
    }

    func testClaudeTargetedResolverEmptySuccessPreservesRemoteFallback() throws {
        let outcome = try runClaudeTargetedResolverScenario(response: .emptySuccess)
        XCTAssertFalse(outcome.result.timedOut, outcome.result.stderr)
        XCTAssertEqual(outcome.result.status, 0, outcome.result.stderr)
        XCTAssertTrue(
            outcome.commands.contains {
                $0.hasPrefix("set_status claude_code Needs input ")
                    && $0.contains("--tab=\(outcome.workspaceId)")
                    && $0.contains("--panel=\(outcome.surfaceId)")
            },
            "A successful no-local-match response must preserve a valid remote binding: \(outcome.commands)"
        )
    }

    private enum TargetedResolverResponse: Sendable {
        case failure
        case emptySuccess
    }

    private func runClaudeTargetedResolverScenario(
        response: TargetedResolverResponse
    ) throws -> (
        result: ProcessRunResult,
        commands: [String],
        workspaceId: String,
        surfaceId: String
    ) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("claude-targeted-resolver")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-targeted-resolver-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "targeted-resolver-session"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state, connectionCount: 2) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            switch method {
            case "system.resolve_terminal":
                switch response {
                case .failure:
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unavailable", "message": "resolver unavailable"]
                    )
                case .emptySuccess:
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: ["tty_bindings": [], "pid_binding": NSNull()]
                    )
                }
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
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

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_CLI_TTY_NAME": "remote-or-stale-tty",
                "CMUX_CLAUDE_PID": "42424",
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification","message":"Claude needs your input"}"#,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)
        return (result, state.snapshot(), workspaceId, surfaceId)
    }
}
