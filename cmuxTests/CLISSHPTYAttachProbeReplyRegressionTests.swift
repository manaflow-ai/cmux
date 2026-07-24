import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPTYReconciliationRejectsMalformedLifecyclePayloads() throws {
        let malformedResults: [[String: Any]] = [
            ["errors": []],
            ["sessions": [], "errors": "invalid"],
        ]
        for (index, malformedResult) in malformedResults.enumerated() {
            let cliPath = try bundledCLIPath()
            let socketPath = makeSocketPath("sshptymalformed\(index)")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let bridge = try bindLoopbackTCP()
            let state = MockSocketServerState()
            let workspaceID = "22222222-2222-2222-2222-222222222222"
            let surfaceID = "33333333-3333-3333-3333-333333333333"
            let sessionID = "ssh-\(workspaceID)-\(surfaceID)"
            defer {
                Darwin.close(listenerFD)
                Darwin.close(bridge.fd)
                unlink(socketPath)
            }
            let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line),
                      let id = payload["id"] as? String,
                      let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(raw: line)
                }
                switch method {
                case "workspace.remote.pty_bridge":
                    return self.v2Response(id: id, ok: true, result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": "bridge-token",
                        "session_id": sessionID,
                        "attachment_id": surfaceID,
                    ])
                case "workspace.remote.pty_resize":
                    return self.v2Response(id: id, ok: true, result: ["resized": true])
                case "workspace.remote.pty_sessions":
                    return self.v2Response(id: id, ok: true, result: malformedResult)
                case "workspace.remote.pty_detach":
                    return self.v2Response(id: id, ok: true, result: ["detached": true])
                default:
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                    )
                }
            }
            let bridgeHandled = startBridgeReadyThenCloseServer(listenerFD: bridge.fd)

            var environment = ProcessInfo.processInfo.environment
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = "1"
            let result = runProcess(
                executablePath: cliPath,
                arguments: [
                    "ssh-pty-attach",
                    "--workspace", workspaceID,
                    "--session-id", sessionID,
                    "--attachment-id", surfaceID,
                ],
                environment: environment,
                timeout: 5
            )

            wait(for: [socketHandled, bridgeHandled], timeout: 5)
            #expect(!result.timedOut)
            #expect(result.status == SSHPTYAttachExitCode.retryableTransient.rawValue)
            #expect(result.stderr.contains("bridge closed before remote PTY exit could be confirmed"))
        }
    }

    func testSSHPTYAttachPreservesPipedProbeLikeInputBeforeForwardingInput() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyprobe")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"
        let bridgeInput = MockBridgeInputCapture()

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                #expect((payload["params"] as? [String: Any])?["require_existing"] as? Bool == true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                    ]
                )
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: ["sessions": []])
            case "workspace.remote.pty_attach_end":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "session_id": sessionId,
                        "cleared_remote_pty_session": true,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let bridgeHandled = startBridgeReadyCapturingInputUntilEOF(
            listenerFD: bridge.fd,
            capture: bridgeInput
        )

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let queuedProbeReplies =
            "\u{1B}]11;rgb:e5e5/e9e9/f0f0\u{1B}\\" +
            "\u{1B}]10;rgb:4141/4848/5858\u{07}" +
            "\u{1B}]12;rgb:ffff/ffff/ffff\u{07}" +
            "\u{1B}[1;1R" +
            "\u{1B}[?1;2c" +
            "\u{1B}[?0u" +
            "\u{1B}[?12;2$y"
        let forwardedInput = "\u{1B}[13;2uprintf keep\n"
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--require-existing",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: environment,
            standardInput: queuedProbeReplies + forwardedInput,
            timeout: 5
        )

        wait(for: [socketHandled], timeout: 5)
        #expect(bridgeHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        let forwardedBridgeInput = bridgeInput.snapshot()
        #expect(String(data: forwardedBridgeInput, encoding: .utf8) == queuedProbeReplies + forwardedInput)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        #expect(methods == [
            "workspace.remote.pty_bridge",
            "workspace.remote.pty_sessions",
            "workspace.remote.pty_attach_end",
        ])
    }
}
