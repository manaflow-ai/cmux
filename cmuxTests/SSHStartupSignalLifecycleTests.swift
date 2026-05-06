import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPaneCloseSignalDoesNotReportSessionEndToSharedTransport() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pane-close-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let logFile = root.appendingPathComponent("ssh-session-end.log")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SESSION_END_LOG}\"",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "kill -\"${CMUX_TEST_SIGNAL:?}\" \"$PPID\"",
            "sleep 0.1",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let startupCommand = try generatedSSHStartupCommand()
        let expectedStatuses: [String: Int32] = ["HUP": 129, "INT": 130, "TERM": 143]
        for signal in ["HUP", "INT", "TERM"] {
            try? fileManager.removeItem(at: logFile)

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
            environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
            environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
            environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
            environment["CMUX_TEST_SESSION_END_LOG"] = logFile.path
            environment["CMUX_TEST_SIGNAL"] = signal

            let result = runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", startupCommand],
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stderr)
            let expectedStatus = try XCTUnwrap(expectedStatuses[signal])
            XCTAssertEqual(
                result.status,
                expectedStatus,
                "Pane-close \(signal) should exit through cmux_ssh_signal_exit with the signal-derived status; stderr: \(result.stderr)"
            )
            let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            let sessionEndCalls = recordedCalls
                .split(separator: "\n")
                .filter { $0.contains("ssh-session-end") }
            XCTAssertTrue(
                sessionEndCalls.isEmpty,
                "Pane-close \(signal) must not call ssh-session-end because that can tear down the shared SSH transport and kill sibling panes; recorded: \(recordedCalls)"
            )
        }
    }

    private func generatedSSHStartupCommand() throws -> String {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-pane-close")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:9"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                    ]
                )
            case "workspace.remote.configure":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": "connecting",
                        ],
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--no-focus",
                "--port", "2222",
                "--ssh-option", "ControlMaster no",
                "--ssh-option", "ControlPath /tmp/cmux-ssh-%C",
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        let configureRequest = try XCTUnwrap(
            requests.first { ($0["method"] as? String) == "workspace.remote.configure" }
        )
        let configureParams = try XCTUnwrap(configureRequest["params"] as? [String: Any])
        return try XCTUnwrap(configureParams["terminal_startup_command"] as? String)
    }

    private func writeShellFile(at url: URL, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
