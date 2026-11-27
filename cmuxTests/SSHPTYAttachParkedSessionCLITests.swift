import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// https://github.com/manaflow-ai/cmux/issues/12813: `ssh-pty-attach --wait`
/// against a remote session that gave up must end loudly and at once, not join
/// the wrapper's retry loop with a status line that says the service is
/// "starting".
extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPTYAttachAgainstParkedSessionStopsWithTheParkedDetail() throws {
        // Worded like a transient failure on purpose: only the structured
        // code may decide that this attach is over.
        let parkedDetail = "The cmux relay on dev@host did not become ready before the " +
            "connection timed out. Use Reconnect to try again."
        let result = try runSSHPTYAttachAgainstParkedSession(
            socketName: "sshptyparked",
            parkedDetail: parkedDetail
        )

        XCTAssertFalse(result.process.timedOut, result.process.stderr)
        XCTAssertEqual(result.process.status, 1, result.process.stderr)
        XCTAssertTrue(
            result.process.stderr.contains(parkedDetail),
            "the terminal must show the app's actionable detail verbatim: \(result.process.stderr)"
        )
        XCTAssertFalse(
            result.process.stderr.contains("remote_session_parked"),
            "the protocol code is not user-facing: \(result.process.stderr)"
        )
    }

    func testSSHPTYAttachAgainstParkedSessionKeepsTheRemoteSessionForReconnect() throws {
        // A session can park after a long outage while its persistent remote
        // PTY is still running. Reconnect must be able to reattach to it, so
        // the failed attach may neither retire the lifecycle nor untrack the
        // surface.
        let result = try runSSHPTYAttachAgainstParkedSession(
            socketName: "sshptyparkedkeep",
            parkedDetail: "SSH reconnect paused. Use Reconnect to try again."
        )

        XCTAssertEqual(result.process.status, 1, result.process.stderr)
        XCTAssertEqual(
            result.methods.filter { $0 == "workspace.remote.pty_bridge" }.count,
            1,
            "\(result.methods)"
        )
        XCTAssertFalse(result.methods.contains("workspace.remote.pty_attach_end"), "\(result.methods)")
        XCTAssertFalse(result.methods.contains("workspace.remote.pty_sessions"), "\(result.methods)")
        XCTAssertFalse(result.methods.contains("workspace.remote.pty_detach"), "\(result.methods)")
    }

    private func runSSHPTYAttachAgainstParkedSession(
        socketName: String,
        parkedDetail: String
    ) throws -> (process: ProcessRunResult, methods: [String]) {
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

        let bridgeRequested = startMockServer(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: { line in
                self.jsonObject(line)?["method"] as? String == "workspace.remote.pty_bridge"
            }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                return self.v2Response(id: id, ok: false, error: [
                    "code": "remote_session_parked",
                    "message": parkedDetail,
                ])
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: ["sessions": []])
            default:
                return self.v2Response(id: id, ok: true, result: [:])
            }
        }

        // The environment of an attach launched by the persistent wrapper
        // while it still has retries left.
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = "1"
        environment["CMUX_SSH_PTY_ATTACH_MANAGED_RECONNECT"] = "1"
        environment["CMUX_SURFACE_ID"] = surfaceId

        let process = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--wait",
                "--require-existing",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: environment,
            timeout: 10
        )
        wait(for: [bridgeRequested], timeout: 5)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        return (process, methods)
    }
}
