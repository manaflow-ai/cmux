import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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

    func testSSHPTYAttachBridgeRPCTransientFailureWithoutPendingWrapperRetryCleansUp() throws {
        // Final wrapper attempt (or direct invocation): no retry is queued,
        // so the CLI must send pty_attach_end and release the surface.
        try assertSSHPTYAttachBridgeRPCFailureExitCode(
            socketName: "sshptyexhausted",
            error: [
                "code": "remote_pty_bridge_timeout",
                "message": "workspace.remote.pty_bridge timed out waiting for the remote daemon",
            ],
            expectedStatus: 255,
            wrapperRetryPending: false
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
        expectedStatus: Int32,
        wrapperRetryPending: Bool = true
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
                return payload["method"] as? String == "workspace.remote.pty_bridge"
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
                return self.v2Response(id: id, ok: true, result: ["ended": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = sshPTYAttachTestEnvironment(socketPath: socketPath)
        if wrapperRetryPending {
            environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = "1"
        } else {
            environment.removeValue(forKey: "CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY")
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
            environment: environment,
            timeout: 5
        )

        wait(for: [socketHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, expectedStatus, result.stderr)

        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertTrue(methods.contains("workspace.remote.pty_bridge"), "\(methods)")
        if wrapperRetryPending {
            // The wrapper re-runs the attach on this same surface; sending
            // pty_attach_end here would untrack it app-side and a successful
            // retry never re-tracks it.
            XCTAssertFalse(methods.contains("workspace.remote.pty_attach_end"), "\(methods)")
        } else {
            // No retry is queued: the CLI must release the surface.
            XCTAssertTrue(methods.contains("workspace.remote.pty_attach_end"), "\(methods)")
        }
    }

    func testRestoredPersistentAttachReauthenticatesAfterTransportLoss() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-restored-ssh-reauth-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        let authAttempts = root.appendingPathComponent("auth-attempts")
        let attachAttempts = root.appendingPathComponent("attach-attempts")
        let sleepAttempts = root.appendingPathComponent("sleep-attempts")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeSSHPTYReconnectTestShell(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \" $* \" in",
            "  *\" ssh-pty-attach \"*)",
            "    count=$(cat \"${CMUX_TEST_ATTACH_ATTEMPTS}\" 2>/dev/null || printf 0)",
            "    count=$((count + 1))",
            "    printf '%s' \"$count\" > \"${CMUX_TEST_ATTACH_ATTEMPTS}\"",
            "    case \"$count\" in 1) exit 255 ;; 2) exit 254 ;; *) exit 253 ;; esac",
            "    ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
        try writeSSHPTYReconnectTestShell(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_AUTH_ATTEMPTS}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_AUTH_ATTEMPTS}\"",
            "if [ \"$count\" -eq 2 ]; then exit 255; fi",
            "exit 0",
        ])
        try writeSSHPTYReconnectTestShell(at: fakeSleep, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_SLEEP_ATTEMPTS}\" 2>/dev/null || printf 0)",
            "printf '%s' $((count + 1)) > \"${CMUX_TEST_SLEEP_ATTEMPTS}\"",
        ])
        for executable in [fakeCLI, fakeSSH, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        var environment = sshPTYAttachTestEnvironment(socketPath: "/tmp/cmux-debug-test.sock")
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_AUTH_ATTEMPTS"] = authAttempts.path
        environment["CMUX_TEST_ATTACH_ATTEMPTS"] = attachAttempts.path
        environment["CMUX_TEST_SLEEP_ATTEMPTS"] = sleepAttempts.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "2"

        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "user@example.test",
                port: 22,
                identityFile: nil,
                sshOptions: [],
                token: "foreground-auth-token"
            )
        )
        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 253, result.stderr)
        XCTAssertEqual(try String(contentsOf: authAttempts, encoding: .utf8), "3")
        XCTAssertEqual(try String(contentsOf: attachAttempts, encoding: .utf8), "3")
        XCTAssertEqual(try String(contentsOf: sleepAttempts, encoding: .utf8), "3")
    }

    func testInitialPersistentAttachReauthenticatesAfterTransportLoss() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-initial-ssh-reauth-\(UUID().uuidString)", isDirectory: true)
        let fakeStartup = root.appendingPathComponent("startup")
        let fakeAuth = root.appendingPathComponent("ssh")
        let fakeAttach = root.appendingPathComponent("cmux-test-attach")
        let fakeSleep = root.appendingPathComponent("sleep")
        let authAttempts = root.appendingPathComponent("auth-attempts")
        let attachAttempts = root.appendingPathComponent("attach-attempts")
        let sleepAttempts = root.appendingPathComponent("sleep-attempts")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeSSHPTYReconnectTestShell(at: fakeAuth, lines: [
            "#!/bin/sh",
            "case \" $* \" in",
            "  *\" -T example.test true \"*) ;;",
            "  *) exit 0 ;;",
            "esac",
            "count=$(cat \"${CMUX_TEST_AUTH_ATTEMPTS}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_AUTH_ATTEMPTS}\"",
            "if [ \"$count\" -eq 2 ]; then exit 255; fi",
            "exit 0",
        ])
        try writeSSHPTYReconnectTestShell(at: fakeAttach, lines: [
            "#!/bin/sh",
            "case \" $* \" in",
            "  *\" ssh-pty-attach \"*)",
            "    count=$(cat \"${CMUX_TEST_ATTACH_ATTEMPTS}\" 2>/dev/null || printf 0)",
            "    count=$((count + 1))",
            "    printf '%s' \"$count\" > \"${CMUX_TEST_ATTACH_ATTEMPTS}\"",
            "    case \"$count\" in 1) exit 255 ;; 2) exit 254 ;; *) exit 253 ;; esac",
            "    ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
        try writeSSHPTYReconnectTestShell(at: fakeSleep, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_SLEEP_ATTEMPTS}\" 2>/dev/null || printf 0)",
            "printf '%s' $((count + 1)) > \"${CMUX_TEST_SLEEP_ATTEMPTS}\"",
        ])

        let generatedScript = try persistentSSHInitialStartupScriptForReconnectTest()
        let bundledCLI = try bundledCLIPath()
        let rewrittenScript = generatedScript.replacingOccurrences(of: bundledCLI, with: fakeAttach.path)
        XCTAssertNotEqual(rewrittenScript, generatedScript, "Expected generated wrapper to reference the bundled CLI")
        try writeSSHPTYReconnectTestShell(at: fakeStartup, contents: rewrittenScript)
        for executable in [fakeStartup, fakeAuth, fakeAttach, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        var environment = sshPTYAttachTestEnvironment(socketPath: "/tmp/cmux-debug-test.sock")
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeAttach.path
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_AUTH_ATTEMPTS"] = authAttempts.path
        environment["CMUX_TEST_ATTACH_ATTEMPTS"] = attachAttempts.path
        environment["CMUX_TEST_SLEEP_ATTEMPTS"] = sleepAttempts.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "2"

        let result = runProcess(
            executablePath: fakeStartup.path,
            arguments: [],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 253, result.stderr)
        XCTAssertEqual(try String(contentsOf: authAttempts, encoding: .utf8), "3")
        XCTAssertEqual(try String(contentsOf: attachAttempts, encoding: .utf8), "3")
        XCTAssertEqual(try String(contentsOf: sleepAttempts, encoding: .utf8), "3")
    }

    func testSSHPTYAttachSilentBridgeTimesOutRetryable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptysilent")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: { line in
                guard let payload = self.jsonObject(line) else { return false }
                return payload["method"] as? String == "workspace.remote.pty_bridge"
            }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
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
        let bridgeHandled = startSilentBridgeServer(listenerFD: bridge.fd)

        var environment = sshPTYAttachTestEnvironment(socketPath: socketPath)
        environment["CMUX_SSH_PTY_BRIDGE_READY_TIMEOUT_SECONDS"] = "1"
        environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = "1"

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
            timeout: 10
        )

        wait(for: [socketHandled, bridgeHandled], timeout: 10)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 255, result.stderr)
        XCTAssertTrue(
            result.stderr.contains("timed out waiting for bridge status"),
            result.stderr
        )
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertTrue(methods.contains("workspace.remote.pty_bridge"), "\(methods)")
        // Wrapper-retryable failures re-run the attach on this same surface;
        // sending pty_attach_end here would untrack it app-side and a
        // successful retry never re-tracks it.
        XCTAssertFalse(methods.contains("workspace.remote.pty_attach_end"), "\(methods)")
    }

    /// Accepts one bridge connection, drains the client handshake, and never
    /// writes a status line, so the CLI's bounded ready wait must fire.
    private func startSilentBridgeServer(listenerFD: Int32) -> XCTestExpectation {
        let handled = expectation(description: "silent pty bridge server handled")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.fulfill() }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 { continue }
                if count < 0 && errno == EINTR { continue }
                return
            }
        }
        return handled
    }

    private func sshPTYAttachTestEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return environment
    }

    private func writeSSHPTYReconnectTestShell(at url: URL, lines: [String]) throws {
        try writeSSHPTYReconnectTestShell(at: url, contents: lines.joined(separator: "\n") + "\n")
    }

    private func writeSSHPTYReconnectTestShell(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
