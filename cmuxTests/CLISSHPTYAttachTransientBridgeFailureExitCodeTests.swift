import Darwin
import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPTYAttachBridgeRPCTimeoutExitsRetryable() throws {
        try assertSSHPTYAttachBridgeRPCFailureExitCode(
            socketName: "sshptytimeout",
            error: [
                "code": "remote_pty_bridge_timeout",
                "message": "workspace.remote.pty_bridge timed out waiting for the remote daemon",
            ],
            expectedStatus: 255
        )
    }

    func testSSHPTYAttachBridgeRPCConnectionNotActiveExitsRetryable() throws {
        try assertSSHPTYAttachBridgeRPCFailureExitCode(
            socketName: "sshptynotactive",
            error: [
                "code": "remote_connection_inactive",
                "message": "remote connection is not active",
            ],
            expectedStatus: 255
        )
    }

    func testSSHPTYAttachUnknownFlagStaysFatal() throws {
        let cliPath = try bundledCLIPath()
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--bogus-flag",
            ],
            environment: sshPTYAttachTestEnvironment(socketPath: makeSocketPath("sshptybogus")),
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
    }

    private func assertSSHPTYAttachBridgeRPCFailureExitCode(
        socketName: String,
        error: [String: Any],
        expectedStatus: Int32
    ) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(socketName)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: { line in
                guard let payload = self.jsonObject(line) else { return false }
                return payload["method"] as? String == "workspace.remote.pty_attach_end"
            }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_bridge":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["session_id"] as? String, sessionId)
                XCTAssertEqual(params["attachment_id"] as? String, surfaceId)
                XCTAssertEqual(params["require_existing"] as? Bool, true)
                return self.v2Response(id: id, ok: false, error: error)
            case "workspace.remote.pty_detach":
                return self.v2Response(id: id, ok: true, result: ["detached": true])
            case "workspace.remote.pty_attach_end":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["surface_id"] as? String, surfaceId)
                XCTAssertEqual(params["session_id"] as? String, sessionId)
                return self.v2Response(id: id, ok: true, result: ["ended": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--wait",
                "--require-existing",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: sshPTYAttachTestEnvironment(socketPath: socketPath),
            timeout: 5
        )

        wait(for: [socketHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, expectedStatus, result.stderr)

        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertTrue(methods.contains("workspace.remote.pty_bridge"), "\(methods)")
        XCTAssertTrue(methods.contains("workspace.remote.pty_attach_end"), "\(methods)")
    }

    private func sshPTYAttachTestEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return environment
    }
}
