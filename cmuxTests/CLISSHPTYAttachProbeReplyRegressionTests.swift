import Darwin
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPTYAttachDoesNotReplayTerminalQueriesIntoTheLocalTerminal() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyreplay")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceID = "22222222-2222-2222-2222-222222222222"
        let surfaceID = "33333333-3333-3333-3333-333333333333"
        let sessionID = "ssh-\(workspaceID)-\(surfaceID)"
        let replay = Data(
            (
                "remote prompt\n" +
                "\u{1B}[>q" + // XTVERSION query
                "\u{1B}[c" + // primary device-attributes query
                "\u{1B}[?2026$p" + // DECRQM query
                "\u{1B}]11;?\u{07}" + // OSC background-color query
                "visible after replay\n"
            ).utf8
        )

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
                return self.v2Response(id: id, ok: true, result: [
                    "sessions": [],
                    "errors": [],
                ])
            case "workspace.remote.pty_attach_end":
                return self.v2Response(id: id, ok: true, result: ["ended": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let bridgeHandled = startBridgeReadySendingReplayServer(
            listenerFD: bridge.fd,
            replay: replay
        )

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--require-existing",
                "--workspace", workspaceID,
                "--session-id", sessionID,
                "--attachment-id", surfaceID,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [socketHandled, bridgeHandled], timeout: 5)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
        #expect(
            result.stdout == "remote prompt\nvisible after replay\n",
            Comment(rawValue: result.stdout.debugDescription)
        )
    }

    func testSSHPTYReconciliationPreservesSessionForReattach() throws {
        let cliPath = try bundledCLIPath()
        let scenarios: [(name: String, wrapperRetry: String?, confirmsRunning: Bool)] = [
            ("pending-inconclusive", "1", false),
            ("exhausted-inconclusive", "0", false),
            ("direct-inconclusive", nil, false),
            ("pending-confirmed", "1", true),
            ("exhausted-confirmed", "0", true),
            ("direct-confirmed", nil, true),
        ]
        for (index, scenario) in scenarios.enumerated() {
            let socketPath = makeSocketPath("sshptyreconcile\(index)")
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
                    if scenario.confirmsRunning {
                        return self.v2Response(id: id, ok: true, result: [
                            "sessions": [["session_id": sessionID]],
                            "errors": [],
                        ])
                    }
                    // This is the exact callback-order race from issue 9965: the
                    // per-channel bridge has closed and the broker has already
                    // removed its ready tunnel, even though the daemon and PTY
                    // session can still be healthy behind the replacement tunnel.
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: [
                            "code": "remote_pty_error",
                            "message": "remote daemon tunnel is not ready",
                        ]
                    )
                case "workspace.remote.pty_detach":
                    return self.v2Response(id: id, ok: true, result: ["detached": true])
                case "workspace.remote.pty_attach_end":
                    return self.v2Response(id: id, ok: true, result: ["ended": true])
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
            environment.removeValue(forKey: "CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY")
            environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = scenario.wrapperRetry
            let result = runProcess(
                executablePath: cliPath,
                arguments: [
                    "ssh-pty-attach",
                    "--wait",
                    "--require-existing",
                    "--workspace", workspaceID,
                    "--session-id", sessionID,
                    "--attachment-id", surfaceID,
                ],
                environment: environment,
                timeout: 5
            )

            wait(for: [socketHandled, bridgeHandled], timeout: 5)
            #expect(!result.timedOut, Comment(rawValue: scenario.name))
            #expect(
                result.status == SSHPTYAttachExitCode.bridgeClosedSessionRunning.rawValue,
                Comment(rawValue: scenario.name)
            )
            if scenario.confirmsRunning {
                let claimsAutomaticReconnect = result.stderr.contains("cmux is reconnecting")
                #expect(
                    claimsAutomaticReconnect == (scenario.wrapperRetry == "1"),
                    Comment(rawValue: "\(scenario.name): \(result.stderr)")
                )
                if scenario.wrapperRetry != "1" {
                    #expect(result.stderr.contains("remote session may still be running"))
                }
            } else {
                #expect(result.stderr.contains("remote session state could be confirmed"))
            }
            let requests = state.snapshot().compactMap { self.jsonObject($0) }
            let reconciliationRequests = requests.filter {
                $0["method"] as? String == "workspace.remote.pty_sessions"
            }
            #expect(reconciliationRequests.count == 1, Comment(rawValue: scenario.name))
            for request in reconciliationRequests {
                guard let params = request["params"] as? [String: Any] else {
                    #expect(Bool(false), Comment(rawValue: scenario.name))
                    continue
                }
                #expect(
                    params["acknowledge_lifecycle"] as? Bool != true,
                    Comment(rawValue: scenario.name)
                )
                #expect(
                    params["acknowledge_lifecycle_if_session_absent"] as? Bool != true,
                    Comment(rawValue: scenario.name)
                )
            }
            let methods = requests.compactMap { $0["method"] as? String }
            #expect(!methods.contains("workspace.remote.pty_attach_end"))
        }
    }

    func testSSHPTYReconciliationRejectsMalformedLifecyclePayloads() throws {
        let malformedResults: [[String: Any]] = [
            ["errors": []],
            ["sessions": [], "errors": "invalid"],
            ["sessions": [[:]], "errors": []],
            ["sessions": [["session_id": "  "]], "errors": []],
            ["sessions": [["session_id": 42]], "errors": []],
            ["requested_session_lifecycle": 42, "sessions": [], "errors": []],
            ["requested_session_lifecycle": "  ", "sessions": [], "errors": []],
            ["requested_session_lifecycle": "unknown", "sessions": [], "errors": []],
        ]
        for (index, malformedResult) in malformedResults.enumerated() {
            let malformedCase = "malformed result \(index): \(malformedResult)"
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
            #expect(!result.timedOut, Comment(rawValue: malformedCase))
            #expect(
                result.status == SSHPTYAttachExitCode.bridgeClosedSessionRunning.rawValue,
                Comment(rawValue: malformedCase)
            )
            #expect(
                result.stderr.contains("remote session state could be confirmed"),
                Comment(rawValue: malformedCase)
            )
            let requests = state.snapshot().compactMap { self.jsonObject($0) }
            let methods = requests.compactMap { $0["method"] as? String }
            #expect(
                !methods.contains("workspace.remote.pty_attach_end"),
                Comment(rawValue: malformedCase)
            )
            let reconciliationRequests = requests.filter {
                $0["method"] as? String == "workspace.remote.pty_sessions"
            }
            #expect(reconciliationRequests.count == 1, Comment(rawValue: malformedCase))
            for request in reconciliationRequests {
                guard let params = request["params"] as? [String: Any] else {
                    #expect(Bool(false), Comment(rawValue: malformedCase))
                    continue
                }
                #expect(
                    params["acknowledge_lifecycle"] as? Bool != true,
                    Comment(rawValue: malformedCase)
                )
                #expect(
                    params["acknowledge_lifecycle_if_session_absent"] as? Bool != true,
                    Comment(rawValue: malformedCase)
                )
            }
        }
    }

    func testSSHPTYAttachClosedGenerationPreservesActiveLifecycleWithoutSessionProof() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyclosedactive")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "22222222-2222-2222-2222-222222222222"
        let surfaceID = "33333333-3333-3333-3333-333333333333"
        let sessionID = "ssh-\(workspaceID)-\(surfaceID)"
        let lifecycleID = "44444444-4444-4444-4444-444444444444"
        defer {
            Darwin.close(listenerFD)
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
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "pty_lifecycle_closed", "message": "remote PTY operation failed"]
                )
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: [
                    "sessions": [],
                    "errors": [],
                ])
            case "workspace.remote.pty_attach_end":
                return self.v2Response(id: id, ok: true, result: ["ended": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach", "--wait", "--require-existing",
                "--workspace", workspaceID, "--session-id", sessionID,
                "--lifecycle-id", lifecycleID, "--attachment-id", surfaceID,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [socketHandled], timeout: 5)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(
            result.status == SSHPTYAttachExitCode.retryableTransient.rawValue,
            Comment(rawValue: result.stderr)
        )
        let requests = state.snapshot().compactMap { self.jsonObject($0) }
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods.filter { $0 == "workspace.remote.pty_bridge" }.count == 1)
        #expect(methods.filter { $0 == "workspace.remote.pty_sessions" }.count == 1)
        #expect(!methods.contains("workspace.remote.pty_attach_end"), Comment(rawValue: "\(methods)"))
        let reconciliationParams: [[String: Any]] = requests.compactMap { request in
            guard request["method"] as? String == "workspace.remote.pty_sessions" else { return nil }
            return request["params"] as? [String: Any]
        }
        #expect(reconciliationParams.count == 1)
        guard let reconciliationParams = reconciliationParams.first else { return }
        #expect(reconciliationParams["acknowledge_lifecycle"] as? Bool != true)
        #expect(reconciliationParams["acknowledge_lifecycle_if_session_absent"] as? Bool != true)
    }

    func testSSHPTYAttachCleanupFailureDoesNotRetryConfirmedEndedSession() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyendedcleanup")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceID = "22222222-2222-2222-2222-222222222222"
        let surfaceID = "33333333-3333-3333-3333-333333333333"
        let sessionID = "ssh-\(workspaceID)-\(surfaceID)"
        let lifecycleID = "44444444-4444-4444-4444-444444444444"
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
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: [
                    "sessions": [],
                    "errors": [],
                ])
            case "workspace.remote.pty_resize", "workspace.remote.pty_detach":
                return self.v2Response(id: id, ok: true, result: [:])
            case "workspace.remote.pty_attach_end":
                let attemptCount = state.snapshot().compactMap { self.jsonObject($0) }.filter {
                    $0["method"] as? String == "workspace.remote.pty_attach_end"
                }.count
                if attemptCount == 1 {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "cleanup_failed", "message": "transient cleanup failure"]
                    )
                }
                return self.v2Response(id: id, ok: true, result: ["ended": true])
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
        environment.removeValue(forKey: "CMUX_TERMINAL_LIFECYCLE_ID")
        environment.removeValue(forKey: "CMUX_SSH_ATTEMPT_ID")
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach", "--wait", "--require-existing",
                "--workspace", workspaceID, "--session-id", sessionID,
                "--lifecycle-id", lifecycleID, "--attachment-id", surfaceID,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [socketHandled, bridgeHandled], timeout: 5)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == SSHPTYAttachExitCode.fatal.rawValue, Comment(rawValue: result.stderr))
        let requests = state.snapshot().compactMap { self.jsonObject($0) }
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods.filter { $0 == "workspace.remote.pty_bridge" }.count == 1)
        #expect(methods.filter { $0 == "workspace.remote.pty_sessions" }.count == 3)
        #expect(methods.filter { $0 == "workspace.remote.pty_attach_end" }.count == 2)
        #expect(methods.filter { $0 == "workspace.remote.pty_detach" }.count == 1)
        let lifecycleRetirements = requests.filter { request in
            guard request["method"] as? String == "workspace.remote.pty_sessions",
                  let params = request["params"] as? [String: Any] else { return false }
            return params["acknowledge_lifecycle"] as? Bool == true
        }
        #expect(lifecycleRetirements.count == 1)
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
        let requests = state.snapshot().compactMap { self.jsonObject($0) }
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods == [
            "workspace.remote.pty_bridge",
            "workspace.remote.pty_sessions",
            "workspace.remote.pty_sessions",
            "workspace.remote.pty_attach_end",
        ])
        let reconciliationParams: [[String: Any]] = requests.compactMap { request in
            guard request["method"] as? String == "workspace.remote.pty_sessions" else { return nil }
            return request["params"] as? [String: Any]
        }
        #expect(reconciliationParams.count == 2)
        guard reconciliationParams.count == 2 else { return }
        #expect(reconciliationParams[0]["acknowledge_lifecycle_if_session_absent"] as? Bool != true)
        #expect(reconciliationParams[1]["acknowledge_lifecycle_if_session_absent"] as? Bool == true)
    }
}
