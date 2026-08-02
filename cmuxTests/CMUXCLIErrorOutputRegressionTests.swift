import CmuxSettings
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct CMUXCLIErrorOutputRegressionTests {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }

    @Test func testCLIErrorPathDoesNotCrashWhenStderrIsClosed() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) definitely-not-a-command 2>&-",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Usage:"), result.stdout)
    }

    @Test func testAgentTeamsHelpDoesNotLaunchExternalAgentCLI() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["PATH"] = "/usr/bin:/bin"

        for command in ["claude-teams", "codex-teams"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: [command, "--help"],
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stdout)
            XCTAssertEqual(result.status, 0, result.stdout)
            XCTAssertTrue(result.stdout.contains("Usage: cmux \(command)"), result.stdout)
            XCTAssertFalse(result.stdout.contains("Failed to launch"), result.stdout)
        }
    }

    @Test func testIOSContextFromTerminalFallsBackToWorkspaceSimulator() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-ios-routing-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":true,"result":{"simulator_id":"PAD","device_name":"iPad","runtime_id":"runtime","device_type_id":"type","family":"ipad","state":"booted"}}"#
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_WORKSPACE_ID"] = "workspace:caller"
        environment["CMUX_SURFACE_ID"] = "surface:terminal"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "ios", "context", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let requests = responder.receivedRequests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let data = try #require(request.data(using: String.Encoding.utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["method"] as? String == "simulator.context")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == "workspace:caller")
        #expect(params["pane_id"] == nil)
        #expect(params["surface_id"] == nil)
    }

    @Test func testRestoreExecutesStructuredArgvEnvironmentAndCwdDirectly() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux restore 项目 'space' \(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("工作 dir", isDirectory: true)
        let executable = root.appendingPathComponent("fake agent", isDirectory: false)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf 'pwd=%s\\n' "$PWD"
        printf 'env=%s\\n' "$RESTORE_VALUE"
        for argument in "$@"; do
          printf 'arg=%s\\n' "$argument"
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let checkpointID = "checkpoint-\(UUID().uuidString)"
        let arguments = [executable.path, "space value", "quote'\"", "日本語", String(repeating: "x", count: 4_000)]
        let surfaceID = UUID().uuidString.lowercased()
        let workspaceID = UUID().uuidString.lowercased()
        let response = try restoreResponse(
            result: [
                "terminals": [[
                    "tty": "ttys9258",
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                ]],
                "restore_record": [
                    "mode": "direct",
                    "kind": "custom",
                    "checkpoint_id": checkpointID,
                    "source": "test",
                    "working_directory": workingDirectory.path,
                    "environment": ["RESTORE_VALUE": "値 with spaces"],
                    "launch_command": [
                        "arguments": arguments,
                        "executable_path": executable.path,
                        "working_directory": workingDirectory.path,
                        "environment": ["RESTORE_VALUE": "値 with spaces"],
                    ],
                    "prepared_arguments": arguments,
                ],
            ],
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let socketPath = "/tmp/cmux-restore-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["TTY"] = "/dev/ttys9258"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "--surface"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains("pwd=\(workingDirectory.path)\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("env=値 with spaces\n"), result.stdout)
        for argument in arguments.dropFirst() {
            XCTAssertTrue(result.stdout.contains("arg=\(argument)\n"), result.stdout)
        }
        let methods = try responder.receivedRequests.map { request in
            let data = try XCTUnwrap(request.data(using: .utf8))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            return try XCTUnwrap(object["method"] as? String)
        }
        XCTAssertEqual(methods, ["agent.resolve_delivery_target", "surface.resume.get"])
    }

    @Test func testRestoreDoesNotResolveBareExecutableFromEmptyPATHComponent() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux restore untrusted cwd \(UUID().uuidString)", isDirectory: true)
        let executableName = "restore-agent"
        let executable = root.appendingPathComponent(executableName, isDirectory: false)
        let marker = root.appendingPathComponent("executed", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        touch \(shellSingleQuote(marker.path))
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let checkpointID = "path-\(UUID().uuidString)"
        let response = try restoreResponse(result: [
            "restore_record": [
                "mode": "direct",
                "kind": "custom",
                "checkpoint_id": checkpointID,
                "working_directory": root.path,
                "environment": ["PATH": "/usr/bin:"],
                "launch_command": [
                    "arguments": [executableName],
                    "executable_path": executableName,
                    "working_directory": root.path,
                    "environment": ["PATH": "/usr/bin:"],
                ],
                "prepared_arguments": [executableName],
            ],
        ])
        let socketPath = "/tmp/cmux-restore-path-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = UUID().uuidString

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "custom", checkpointID],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(
            result.stdout.contains(
                "restore: the saved agent command is unavailable. "
                    + "Make sure the agent is installed, then retry."
            ),
            result.stdout
        )
        XCTAssertFalse(result.stdout.contains(executableName), result.stdout)
        XCTAssertFalse(result.stdout.contains(root.path), result.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testRestorePreflightIsQuietAndTimesOut() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux restore preflight \(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fake hermes", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        if [ "$1" = "config" ]; then
          printf 'preflight stdout chatter\\n'
          printf 'preflight stderr chatter\\n' >&2
          exec /bin/sleep 60
        fi
        printf 'unexpected agent launch\\n'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let checkpointID = "preflight-\(UUID().uuidString)"
        let launchEnvironment = ["CUSTOM_BASE_URL": "https://codex.example.test/v1"]
        let response = try restoreResponse(result: [
            "restore_record": [
                "mode": "resumeAgent",
                "kind": "hermes-agent",
                "checkpoint_id": checkpointID,
                "working_directory": root.path,
                "environment": launchEnvironment,
                "launch_command": [
                    "launcher": "hermes-agent",
                    "arguments": [
                        executable.path,
                        "--provider",
                        "openai-codex",
                    ],
                    "executable_path": executable.path,
                    "working_directory": root.path,
                    "environment": launchEnvironment,
                ],
            ],
        ])
        let socketPath = "/tmp/cmux-restore-preflight-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = UUID().uuidString

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "hermes-agent", checkpointID],
            environment: environment,
            timeout: 15
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(
            result.stdout.contains(
                "restore: provider setup took too long. "
                    + "Check the provider connection, then retry."
            ),
            result.stdout
        )
        XCTAssertFalse(result.stdout.contains("fake hermes"), result.stdout)
        XCTAssertFalse(result.stdout.contains("model.provider"), result.stdout)
        XCTAssertFalse(result.stdout.contains("preflight stdout chatter"), result.stdout)
        XCTAssertFalse(result.stdout.contains("preflight stderr chatter"), result.stdout)
        XCTAssertFalse(result.stdout.contains("unexpected agent launch"), result.stdout)
    }

    @Test func testRestoreRetargetsPreparedCwdWhenPersistedDirectoryIsMissing() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux missing cwd \(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fake cwd agent", isDirectory: false)
        let missingDirectory = root.appendingPathComponent("deleted", isDirectory: true)
        let capturedDirectory = root.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf 'pwd=%s\\n' "$PWD"
        for argument in "$@"; do
          printf 'arg=%s\\n' "$argument"
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let checkpointID = "cwd-\(UUID().uuidString)"
        let preparedArguments = [
            executable.path,
            "--cwd",
            capturedDirectory.path,
            "--session",
            checkpointID,
        ]
        let response = try restoreResponse(result: [
            "restore_record": [
                "mode": "resumeAgent",
                "kind": "cwd-agent",
                "checkpoint_id": checkpointID,
                "working_directory": missingDirectory.path,
                "environment": [:],
                "launch_command": [
                    "arguments": [executable.path],
                    "executable_path": executable.path,
                    "working_directory": capturedDirectory.path,
                ],
                "prepared_arguments": preparedArguments,
                "prepared_arguments_working_directory": capturedDirectory.path,
            ],
        ])
        let socketPath = "/tmp/cmux-missing-cwd-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = UUID().uuidString

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "cwd-agent", checkpointID],
            environment: environment,
            currentDirectoryURL: root,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains("pwd=\(root.path)\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("arg=\(root.path)\n"), result.stdout)
        XCTAssertFalse(result.stdout.contains(missingDirectory.path), result.stdout)
    }

    @Test func testRestoreRunsCommandOnlyLegacyRecordThroughCompatibilityShell() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux legacy restore \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let checkpointID = "legacy-\(UUID().uuidString)"
        let response = try restoreResponse(result: [
            "restore_record": [
                "mode": "resumeAgent",
                "kind": "codex",
                "checkpoint_id": checkpointID,
                "working_directory": root.path,
                "environment": ["LEGACY_RESTORE_VALUE": "kept"],
                "legacy_command": #"printf 'legacy=%s|%s\n' "$PWD" "$LEGACY_RESTORE_VALUE""#,
            ],
        ])
        let socketPath = "/tmp/cmux-legacy-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = UUID().uuidString
        environment["SHELL"] = "/bin/sh"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "codex", checkpointID],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains("legacy=\(root.path)|kept"), result.stdout)
    }

    @Test func testRestoreFallsBackWhenStructuredPlannerCannotBuildInvocation() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux structured fallback \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let checkpointID = "fallback-\(UUID().uuidString)"
        let response = try restoreResponse(result: [
            "restore_record": [
                "mode": "relaunchAgent",
                "kind": "custom-relaunch",
                "checkpoint_id": checkpointID,
                "working_directory": root.path,
                "environment": ["FALLBACK_VALUE": "structured"],
                "launch_command": [
                    "arguments": ["/missing/custom-relaunch"],
                    "executable_path": "/missing/custom-relaunch",
                ],
                "legacy_command": #"printf 'fallback=%s|%s\n' "$PWD" "$FALLBACK_VALUE""#,
            ],
        ])
        let socketPath = "/tmp/cmux-fallback-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = UUID().uuidString
        environment["SHELL"] = "/bin/sh"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "custom-relaunch", checkpointID],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertTrue(
            result.stdout.contains("fallback=\(root.path)|structured"),
            result.stdout
        )
    }

    @Test func testRestorePositionalFormRequiresSurfaceContext() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "codex", UUID().uuidString.lowercased()],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(
            result.stdout.contains(
                "restore: the current cmux surface could not be identified. "
                    + "Retry from this terminal or pass --surface <id|ref>."
            ),
            result.stdout
        )
    }

    @Test func testRestorePositionalFormFailsClosedWhenBindingIdentityDrifts() throws {
        let cliPath = try bundledCLIPath()
        let currentCheckpointID = UUID().uuidString.lowercased()
        let response = try restoreResponse(result: [
            "restore_record": [
                "mode": "direct",
                "kind": "codex",
                "checkpoint_id": currentCheckpointID,
                "environment": [:],
                "launch_command": [
                    "arguments": ["/usr/bin/true"],
                    "executable_path": "/usr/bin/true",
                ],
                "prepared_arguments": ["/usr/bin/true"],
            ],
        ])
        let socketPath = "/tmp/cmux-restore-drift-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = UUID().uuidString

        for arguments in [
            ["restore", "claude", currentCheckpointID],
            ["restore", "codex", UUID().uuidString.lowercased()],
        ] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stdout)
            XCTAssertEqual(result.status, 1, result.stdout)
            XCTAssertTrue(
                result.stdout.contains("Run 'cmux restore --surface'"),
                result.stdout
            )
        }
    }

    @Test func testRestoreExplicitSocketFailureReportsTheSocketError() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-restore-offline-\(UUID().uuidString.prefix(8)).sock"
        unlink(socketPath)
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--socket",
                socketPath,
                "restore",
                "codex",
                UUID().uuidString.lowercased(),
            ],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(
            result.stdout.contains("Socket not found at \(socketPath)"),
            result.stdout
        )
        XCTAssertFalse(
            result.stdout.contains("Retry the visible restore command after cmux finishes opening."),
            result.stdout
        )
    }

    @Test func testRestoreWaitsForControlSocketDuringAppStartup() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = UUID().uuidString.lowercased()
        let response = try restoreResponse(result: [
            "restore_record": [
                "mode": "direct",
                "kind": "custom",
                "checkpoint_id": checkpointID,
                "environment": [:],
                "launch_command": [
                    "arguments": ["/usr/bin/true"],
                    "executable_path": "/usr/bin/true",
                ],
                "prepared_arguments": ["/usr/bin/true"],
            ],
        ])
        let socketPath = "/tmp/cmux-restore-startup-\(UUID().uuidString.prefix(8)).sock"
        unlink(socketPath)
        var responder: UnixSocketResponder?
        defer { responder?.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = UUID().uuidString

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "restore",
                "custom",
                checkpointID,
            ],
            environment: environment,
            timeout: 5,
            afterLaunch: {
                usleep(100_000)
                responder = try? UnixSocketResponder(path: socketPath, response: response)
            }
        )

        let requiredResponder = try #require(responder)
        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(requiredResponder.receivedRequests.count, 2)
    }

    @Test(arguments: ["pi", "grok"])
    func testRestorePrefersLiveProcessTargetOverStaleAmbientRouting(kind: String) throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "\(kind)-\(UUID().uuidString.lowercased())"
        let staleSurfaceID = UUID().uuidString
        let staleTTYSurfaceID = UUID().uuidString
        let currentSurfaceID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let callerTargetResponse = try jsonResponse(result: [
            "terminals": [[
                "tty": "ttys9380",
                "workspace_id": UUID().uuidString,
                "surface_id": staleTTYSurfaceID,
            ]],
            "source": "pid",
            "pid_resolution": "controlling_tty",
            "workspace_id": workspaceID,
            "surface_id": currentSurfaceID,
        ])
        let restoreResponse = try restoreResponse(result: [
            "restore_record": [
                "mode": "direct",
                "kind": kind,
                "checkpoint_id": checkpointID,
                "environment": [:],
                "launch_command": [
                    "arguments": ["/usr/bin/true"],
                    "executable_path": "/usr/bin/true",
                ],
                "prepared_arguments": ["/usr/bin/true"],
            ],
        ])
        let socketPath = "/tmp/cmux-restore-stale-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [callerTargetResponse, restoreResponse]
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = staleSurfaceID
        environment["TTY"] = "/dev/ttys9380"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", kind, checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "agent.resolve_delivery_target",
            "surface.resume.get",
        ])
        let callerTargetRequest = try #require(requests.first)
        let callerTargetParams = try #require(callerTargetRequest["params"] as? [String: Any])
        #expect((callerTargetParams["pid"] as? Int).map { $0 > 0 } == true)
        #expect(callerTargetParams["pid_resolution"] as? String == "controlling_tty")
        let restoreRequest = try #require(requests.last)
        let restoreParams = try #require(restoreRequest["params"] as? [String: Any])
        #expect(restoreParams["surface_id"] as? String == currentSurfaceID)
        #expect(restoreParams["surface_id"] as? String != staleSurfaceID)
        #expect(restoreParams["surface_id"] as? String != staleTTYSurfaceID)
    }

    @Test func testRelayRestoreFailsClosedOnFirstMissingTTYTarget() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID().uuidString
        let notFoundResponse = try jsonErrorResponse(
            code: "not_found",
            message: "No live delivery target"
        )
        let relayID = "relay-\(UUID().uuidString.lowercased())"
        let responder = try RelaySocketResponder(
            relayID: relayID,
            responses: [notFoundResponse]
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = responder.endpoint
        environment["CMUX_RELAY_ID"] = relayID
        environment["CMUX_RELAY_TOKEN"] = String(repeating: "11", count: 32)
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_CLI_TTY_NAME"] = "0"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(
            result.stdout.contains("the current cmux surface could not be identified"),
            Comment(rawValue: result.stdout)
        )
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(
            requests.compactMap { $0["method"] as? String } == [
                "agent.resolve_delivery_target"
            ]
        )
        let params = try #require(requests.first?["params"] as? [String: Any])
        #expect(params["tty_name"] as? String == "0")
        #expect(params["tty_resolution"] as? String == "reported_tty")
        #expect(params["workspace_id"] as? String == workspaceID)
    }

    @Test func testRestoreFailsClosedWhenLiveProcessTargetIsNotFound() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let staleSurfaceID = UUID().uuidString
        let callerTargetResponse = try jsonErrorResponse(
            code: "not_found",
            message: "No live delivery target"
        )
        let socketPath = "/tmp/cmux-restore-ambiguous-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: callerTargetResponse
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = staleSurfaceID
        environment["TTY"] = "/dev/ttys9380"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(
            result.stdout.contains("the current cmux surface could not be identified"),
            Comment(rawValue: result.stdout)
        )
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(
            requests.compactMap { $0["method"] as? String } == [
                "agent.resolve_delivery_target"
            ]
        )
    }

    @Test func testRestoreUsesUniqueTTYBindingWhenLiveTargetMethodIsUnsupported() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let callerTargetResponse = try jsonErrorResponse(
            code: "method_not_found",
            message: "Unknown method"
        )
        let terminalsResponse = try jsonResponse(result: [
            "terminals": [[
                "tty": "ttys9380",
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
            ]],
        ])
        let restoreResponse = try restoreResponse(result: [
            "restore_record": [
                "mode": "direct",
                "kind": "pi",
                "checkpoint_id": checkpointID,
                "environment": [:],
                "launch_command": [
                    "arguments": ["/usr/bin/true"],
                    "executable_path": "/usr/bin/true",
                ],
                "prepared_arguments": ["/usr/bin/true"],
            ],
        ])
        let socketPath = "/tmp/cmux-restore-legacy-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [callerTargetResponse, terminalsResponse, restoreResponse]
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_TTY_NAME"] = "ttys9380"
        environment["TTY"] = "/dev/ttys-stale"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "agent.resolve_delivery_target",
            "debug.terminals",
            "surface.resume.get",
        ])
        let restoreRequest = try #require(requests.last)
        let restoreParams = try #require(restoreRequest["params"] as? [String: Any])
        #expect(restoreParams["surface_id"] as? String == surfaceID)
    }

    @Test func testRestoreScopesRelayTTYResolutionToAuthenticatedWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let siblingWorkspaceID = UUID().uuidString
        let siblingSurfaceID = UUID().uuidString
        let liveTargetResponse = try jsonResponse(result: [
            "terminals": [
                [
                    "tty": "0",
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                ],
                [
                    "tty": "0",
                    "workspace_id": siblingWorkspaceID,
                    "surface_id": siblingSurfaceID,
                ],
            ],
            "source": "tty",
            "tty_resolution": "reported_tty",
            "workspace_id": workspaceID,
            "surface_id": surfaceID,
        ])
        let recordResponse = try jsonResponse(result: [
            "restore_record": [
                "mode": "direct",
                "kind": "pi",
                "checkpoint_id": checkpointID,
                "environment": [:],
                "launch_command": [
                    "arguments": ["/usr/bin/true"],
                    "executable_path": "/usr/bin/true",
                ],
                "prepared_arguments": ["/usr/bin/true"],
            ],
        ])
        let relayID = "relay-\(UUID().uuidString.lowercased())"
        let responder = try RelaySocketResponder(
            relayID: relayID,
            responses: [liveTargetResponse, recordResponse]
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = responder.endpoint
        environment["CMUX_RELAY_ID"] = relayID
        environment["CMUX_RELAY_TOKEN"] = String(repeating: "11", count: 32)
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_CLI_TTY_NAME"] = "0"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "agent.resolve_delivery_target",
            "surface.resume.get",
        ])
        let targetParams = try #require(requests.first?["params"] as? [String: Any])
        #expect(targetParams["tty_name"] as? String == "0")
        #expect(targetParams["tty_resolution"] as? String == "reported_tty")
        let restoreParams = try #require(requests.last?["params"] as? [String: Any])
        #expect(restoreParams["surface_id"] as? String == surfaceID)
        #expect(restoreParams["surface_id"] as? String != siblingSurfaceID)
    }

    @Test func testRestoreScopesLegacyRelayTTYFallbackToResolvedWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let staleWorkspaceID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let siblingWorkspaceID = UUID().uuidString
        let siblingSurfaceID = UUID().uuidString
        let workspaceResponse = try jsonResponse(result: [
            "source": "workspace",
            "workspace_id": workspaceID,
            "surface_id": NSNull(),
        ])
        let terminalsResponse = try jsonResponse(result: [
            "terminals": [
                [
                    "tty": "0",
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                ],
                [
                    "tty": "0",
                    "workspace_id": siblingWorkspaceID,
                    "surface_id": siblingSurfaceID,
                ],
            ],
        ])
        let recordResponse = try jsonResponse(result: [
            "restore_record": [
                "mode": "direct",
                "kind": "pi",
                "checkpoint_id": checkpointID,
                "environment": [:],
                "launch_command": [
                    "arguments": ["/usr/bin/true"],
                    "executable_path": "/usr/bin/true",
                ],
                "prepared_arguments": ["/usr/bin/true"],
            ],
        ])
        let relayID = "relay-\(UUID().uuidString.lowercased())"
        let responder = try RelaySocketResponder(
            relayID: relayID,
            responses: [workspaceResponse, terminalsResponse, recordResponse]
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = responder.endpoint
        environment["CMUX_RELAY_ID"] = relayID
        environment["CMUX_RELAY_TOKEN"] = String(repeating: "11", count: 32)
        environment["CMUX_WORKSPACE_ID"] = staleWorkspaceID
        environment["CMUX_CLI_TTY_NAME"] = "0"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "agent.resolve_delivery_target",
            "debug.terminals",
            "surface.resume.get",
        ])
        let targetParams = try #require(requests.first?["params"] as? [String: Any])
        #expect(targetParams["workspace_id"] as? String == staleWorkspaceID)
        let restoreParams = try #require(requests.last?["params"] as? [String: Any])
        #expect(restoreParams["surface_id"] as? String == surfaceID)
        #expect(restoreParams["surface_id"] as? String != siblingSurfaceID)
    }

    @Test func testRestoreRejectsMalformedLiveProcessTargetWithoutFallingBack() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let callerTargetResponse = try jsonResponse(result: [
            "terminals": [],
            "source": "pid",
            "pid_resolution": "controlling_tty",
            "workspace_id": UUID().uuidString,
            "surface_id": "not-a-surface-id",
        ])
        let restoreResponse = try restoreResponse(result: [
            "restore_record": [
                "mode": "direct",
                "kind": "pi",
                "checkpoint_id": checkpointID,
                "environment": [:],
                "launch_command": [
                    "arguments": ["/usr/bin/true"],
                    "executable_path": "/usr/bin/true",
                ],
                "prepared_arguments": ["/usr/bin/true"],
            ],
        ])
        let socketPath = "/tmp/cmux-restore-malformed-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [callerTargetResponse, restoreResponse]
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = UUID().uuidString
        environment["TTY"] = "/dev/ttys9380"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(
            result.stdout.contains("the current cmux surface could not be identified"),
            Comment(rawValue: result.stdout)
        )
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "agent.resolve_delivery_target",
        ])
    }

    @Test func testRestoreDoesNotReuseSocketAfterCallerTargetTimeout() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let currentSurfaceID = UUID().uuidString
        let callerTargetResponse = try jsonResponse(result: [
            "terminals": [[
                "tty": "ttys9380",
                "workspace_id": UUID().uuidString,
                "surface_id": currentSurfaceID,
            ]],
            "source": "pid",
            "pid_resolution": "controlling_tty",
            "workspace_id": UUID().uuidString,
            "surface_id": currentSurfaceID,
        ])
        let restoreResponse = try restoreResponse(result: [
            "restore_record": [
                "mode": "direct",
                "kind": "pi",
                "checkpoint_id": checkpointID,
                "environment": [:],
                "launch_command": [
                    "arguments": ["/usr/bin/true"],
                    "executable_path": "/usr/bin/true",
                ],
                "prepared_arguments": ["/usr/bin/true"],
            ],
        ])
        let socketPath = "/tmp/cmux-restore-timeout-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [callerTargetResponse, restoreResponse],
            responseDelay: 0.3
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = UUID().uuidString
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.2"
        environment["TTY"] = "/dev/ttys9380"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("Command timed out"), Comment(rawValue: result.stdout))
        #expect(
            !result.stdout.contains("this session has nothing to restore"),
            Comment(rawValue: result.stdout)
        )
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "agent.resolve_delivery_target",
        ])
    }

    @Test func testBundledCLIInTaggedDebugAppPrefersItsOwnSocketWithoutEnvironmentOverride() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-socket-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // Redirect the CLI's stable-socket resolution to the temp home so this
        // test is hermetic (CFFIXED_USER_HOME overrides homeDirectoryForCurrentUser).
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "TAGGED",
            result.stdout
        )
    }

    @Test func testBundledCLIInTaggedDebugAppTreatsCaseVariantStableEnvSocketAsImplicitDefault() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-case-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)
        let stableSocketPath = stableSocketURL.path
        let caseVariantStablePath = stableSocketURL
            .deletingLastPathComponent()
            .appendingPathComponent("CMUX.sock", isDirectory: false)
            .path

        let stableResponder = try UnixSocketResponder(path: stableSocketPath, response: "OK STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "PONG")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = caseVariantStablePath
        // Resolve the stable path under the temp home so the case-variant env
        // socket is recognized as the implicit default hermetically.
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "PONG",
            result.stdout
        )
        XCTAssertEqual(stableResponder.receivedRequests, [])
    }

    @Test func testBundledCLIInTaggedDebugAppDoesNotFallBackToStableEnvSocketWhenTaggedSocketIsMissing() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let stableSocketURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
            .appendingPathComponent("cmux.sock", isDirectory: false)
        try FileManager.default.createDirectory(
            at: stableSocketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tagSlug = "cli-missing-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        try? FileManager.default.removeItem(atPath: taggedSocketPath)
        defer { try? FileManager.default.removeItem(atPath: taggedSocketPath) }

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "OK STABLE")
        defer { stableResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"
        environment["CMUX_SOCKET_PATH"] = stableSocketURL.path
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains(taggedSocketPath), result.stdout)
        XCTAssertFalse(result.stdout.contains("OK STABLE"), result.stdout)
        XCTAssertEqual(stableResponder.receivedRequests, [])
    }

    @Test func testBundledCLIInTaggedDebugAppTreatsUserScopedStableEnvSocketAsImplicitDefault() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmux-cli-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let stableSocketURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
        let stableSocketPath = stableSocketURL.path
        try FileManager.default.createDirectory(
            at: stableSocketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let aliases = [
            stableSocketPath,
            stableSocketURL
                .deletingLastPathComponent()
                .appendingPathComponent("CMUX-\(getuid()).sock", isDirectory: false)
                .path,
        ]

        if FileManager.default.fileExists(atPath: stableSocketPath) {
            return
        }

        for alias in aliases {
            try autoreleasepool {
                let tagSlug = "cli-user-\(UUID().uuidString.lowercased())"
                let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
                let stableResponder = try UnixSocketResponder(path: stableSocketPath, response: "OK STABLE")
                defer { stableResponder.stop() }
                let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "PONG")
                defer { taggedResponder.stop() }

                let fakeCLIPath = try fakeTaggedBundledCLIPath(
                    sourceCLIPath: cliPath,
                    tagSlug: tagSlug
                )
                var environment = ProcessInfo.processInfo.environment
                for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
                    environment.removeValue(forKey: key)
                }
                environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
                environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
                environment["CMUX_SOCKET_PATH"] = alias
                environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

                let result = runProcess(
                    executablePath: fakeCLIPath,
                    arguments: ["ping"],
                    environment: environment,
                    timeout: 5
                )

                XCTAssertFalse(result.timedOut, result.stdout)
                XCTAssertEqual(result.status, 0, result.stdout)
                XCTAssertEqual(
                    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    "PONG",
                    result.stdout
                )
                XCTAssertEqual(stableResponder.receivedRequests, [], alias)
            }
        }
    }

    @Test func testBundledStableCLIPreservesLiveUserScopedStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let userScopedStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
            .path
        if FileManager.default.fileExists(atPath: userScopedStableSocketPath) {
            return
        }

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }
        let userScopedResponder = try UnixSocketResponder(path: userScopedStableSocketPath, response: "OK USER")
        defer { userScopedResponder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = userScopedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK USER",
            result.stdout
        )
        XCTAssertEqual(defaultResponder.receivedRequests, [])
        XCTAssertEqual(
            userScopedResponder.receivedRequests.count,
            1,
            userScopedResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertTrue(
            userScopedResponder.receivedRequests.contains { $0.contains("ping") },
            userScopedResponder.receivedRequests.joined(separator: "\n")
        )
    }

    @Test func testBundledStableCLIFallsBackFromStaleUserScopedStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let userScopedStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
            .path
        if FileManager.default.fileExists(atPath: userScopedStableSocketPath) {
            return
        }

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = userScopedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK DEFAULT",
            result.stdout
        )
        XCTAssertEqual(
            defaultResponder.receivedRequests.count,
            1,
            defaultResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertTrue(
            defaultResponder.receivedRequests.contains { $0.contains("ping") },
            defaultResponder.receivedRequests.joined(separator: "\n")
        )
    }

    @Test func testBundledStableCLIFallsBackFromSymlinkedLegacyStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let legacyStableSocketPath = "/tmp/cmux.sock"
        let symlinkTargetSocketPath = "/tmp/cmux-symlink-target-\(UUID().uuidString).sock"
        if lstatPathExists(legacyStableSocketPath) {
            return
        }

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }
        let targetResponder = try UnixSocketResponder(path: symlinkTargetSocketPath, response: "OK TARGET")
        defer { targetResponder.stop() }
        XCTAssertEqual(symlink(symlinkTargetSocketPath, legacyStableSocketPath), 0)
        defer { unlink(legacyStableSocketPath) }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = legacyStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK DEFAULT",
            result.stdout
        )
        XCTAssertEqual(
            defaultResponder.receivedRequests.count,
            1,
            defaultResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertTrue(
            defaultResponder.receivedRequests.contains { $0.contains("ping") },
            defaultResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertEqual(targetResponder.receivedRequests, [])
    }

    @Test func testBundledStableCLIPreservesLiveLegacyStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let legacyStableSocketPath = "/tmp/cmux.sock"
        if FileManager.default.fileExists(atPath: legacyStableSocketPath) {
            return
        }

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }
        let legacyResponder = try UnixSocketResponder(path: legacyStableSocketPath, response: "OK LEGACY")
        defer { legacyResponder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = legacyStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK LEGACY",
            result.stdout
        )
        XCTAssertEqual(defaultResponder.receivedRequests, [])
        XCTAssertEqual(
            legacyResponder.receivedRequests.count,
            1,
            legacyResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertTrue(
            legacyResponder.receivedRequests.contains { $0.contains("ping") },
            legacyResponder.receivedRequests.joined(separator: "\n")
        )
    }

    @Test func testBundledCLISkipsIdentifierlessNestedAppWhenResolvingTaggedSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-nested-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug,
            nestedIdentifierlessApp: true
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // Redirect the CLI's stable-socket resolution to the temp home (hermetic).
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "TAGGED",
            result.stdout
        )
    }

    @Test func testThemesSetReloadsRunningAppAfterEveryThemeWrite() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-socket-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)
        try writeTheme(named: "Theme B", background: "#f8f8f8", to: themesURL)
        try writeTheme(named: "Theme C", background: "#003b49", to: themesURL)

        let socketPath = "/tmp/cmux-theme-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "OK")
        defer { responder.stop() }
        let bundleIdentifier = "com.cmuxterm.app.debug.issue-4355-test"
        let reloadExpectation = expectation(description: "cmux themes set posts final reload notifications")
        reloadExpectation.expectedFulfillmentCount = 3
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?)] = []
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cmuxterm.themes.reload-config"),
            object: nil,
            queue: notificationQueue
        ) { notification in
            let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            guard observedBundleIdentifier == bundleIdentifier else { return }
            let observedPhase = notification.userInfo?["phase"] as? String
            notificationLock.lock()
            observedReloads.append((bundleIdentifier: observedBundleIdentifier, phase: observedPhase))
            notificationLock.unlock()
            reloadExpectation.fulfill()
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = bundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let configURL = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)

        var observedThemeValues: [String] = []
        for themeName in ["Theme A", "Theme B", "Theme C"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["themes", "set", themeName],
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stdout)
            XCTAssertEqual(result.status, 0, result.stdout)
            observedThemeValues.append(try managedThemeValue(in: configURL))
        }
        wait(for: [reloadExpectation], timeout: 5)

        XCTAssertEqual(observedThemeValues, [
            "light:Theme A,dark:Theme A",
            "light:Theme B,dark:Theme B",
            "light:Theme C,dark:Theme C",
        ])
        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, Array(repeating: bundleIdentifier, count: 3))
        XCTAssertEqual(reloads.map { $0.phase }, Array(repeating: "final", count: 3))
        XCTAssertEqual(responder.receivedRequests, [])
    }

    @Test func testThemesSetTargetsResolvedTaggedSocketWhenBundleEnvironmentIsStale() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-stale-bundle-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)

        let socketPath = "/tmp/cmux-debug-active-theme-\(UUID().uuidString).sock"
        let staleBundleIdentifier = "com.cmuxterm.app.debug.stale.theme"
        let targetBundleIdentifier = "com.cmuxterm.app.debug.active.theme"
        let reloadExpectation = expectation(description: "cmux themes set targets the resolved socket bundle")
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?, socketPath: String?)] = []
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cmuxterm.themes.reload-config"),
            object: nil,
            queue: notificationQueue
        ) { notification in
            let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            guard observedBundleIdentifier == targetBundleIdentifier else { return }
            let observedPhase = notification.userInfo?["phase"] as? String
            let observedSocketPath = notification.userInfo?["socketPath"] as? String
            notificationLock.lock()
            observedReloads.append((
                bundleIdentifier: observedBundleIdentifier,
                phase: observedPhase,
                socketPath: observedSocketPath
            ))
            notificationLock.unlock()
            reloadExpectation.fulfill()
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = staleBundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "themes", "set", "Theme A"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        wait(for: [reloadExpectation], timeout: 5)

        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, [targetBundleIdentifier])
        XCTAssertEqual(reloads.map { $0.phase }, ["final"])
        XCTAssertEqual(reloads.map { $0.socketPath }, [socketPath])
        XCTAssertFalse(result.stdout.contains(staleBundleIdentifier), result.stdout)
        XCTAssertTrue(result.stdout.contains(targetBundleIdentifier), result.stdout)
    }

    @Test func testThemesSetNightlyOverridePathIsReadableByNightlyAppConfigResolution() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-nightly-path-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)

        let bundleIdentifier = "com.cmuxterm.app.nightly"
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-nightly.sock"
        environment["CMUX_BUNDLE_ID"] = bundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "themes", "set", "Theme A"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
            result.stdout
        )
        let configPath = try XCTUnwrap(payload["config_path"] as? String, result.stdout)
        XCTAssertEqual(payload["reload_target_bundle_id"] as? String, bundleIdentifier)

        let appSupportDirectory = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let expectedConfigURL = appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
        XCTAssertEqual(configPath, expectedConfigURL.path)

        let appReadablePaths = GhosttyApp.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory
        ).map(\.path)
        XCTAssertEqual(appReadablePaths, [expectedConfigURL.path])
    }

    @Test func testBareInteractiveThemesReloadsRunningAppAfterPickerExits() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-picker-socket-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "theme-picker-\(UUID().uuidString.lowercased())"
        )
        let fakeGhosttyHelperURL = URL(fileURLWithPath: fakeCLIPath)
            .deletingLastPathComponent()
            .appendingPathComponent("ghostty", isDirectory: false)
        try """
        #!/usr/bin/env python3
        import os
        import sys
        import time

        deadline = time.time() + 2.0
        last_error = ""
        while time.time() < deadline:
            try:
                if os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp():
                    sys.exit(0)
                last_error = f"pgrp={os.getpgrp()} tpgid={os.tcgetpgrp(0)}"
            except OSError as error:
                last_error = str(error)
            time.sleep(0.02)

        sys.stderr.write(f"theme picker was not foregrounded: {last_error}\\n")
        sys.exit(42)
        """.write(to: fakeGhosttyHelperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGhosttyHelperURL.path
        )

        let socketPath = "/tmp/cmux-theme-picker-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "OK")
        defer { responder.stop() }
        let bundleIdentifier = "com.cmuxterm.app.debug.theme-picker.\(UUID().uuidString.lowercased())"
        let reloadExpectation = expectation(description: "bare cmux themes posts final reload notification")
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?)] = []
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cmuxterm.themes.reload-config"),
            object: nil,
            queue: notificationQueue
        ) { notification in
            let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            guard observedBundleIdentifier == bundleIdentifier else { return }
            let observedPhase = notification.userInfo?["phase"] as? String
            notificationLock.lock()
            observedReloads.append((bundleIdentifier: observedBundleIdentifier, phase: observedPhase))
            notificationLock.unlock()
            reloadExpectation.fulfill()
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        let command = [
            "env",
            "-i",
            "HOME=\(shellSingleQuote(root.path))",
            "CFFIXED_USER_HOME=\(shellSingleQuote(root.path))",
            "CMUX_SOCKET_PATH=\(shellSingleQuote(socketPath))",
            "CMUX_BUNDLE_ID=\(shellSingleQuote(bundleIdentifier))",
            "CMUX_CLI_SENTRY_DISABLED=1",
            "PATH=/usr/bin:/bin",
            "/usr/bin/script",
            "-q",
            "/dev/null",
            shellSingleQuote(fakeCLIPath),
            "themes",
        ].joined(separator: " ")
        let result = runShell(command, timeout: 5)

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        wait(for: [reloadExpectation], timeout: 5)
        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, [bundleIdentifier])
        XCTAssertEqual(reloads.map { $0.phase }, ["final"])
        XCTAssertEqual(responder.receivedRequests, [])
    }

    @Test func testBareInteractiveThemesTreatsSigintAsSilentCancel() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-picker-cancel-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "theme-picker-cancel-\(UUID().uuidString.lowercased())"
        )
        let fakeGhosttyHelperURL = URL(fileURLWithPath: fakeCLIPath)
            .deletingLastPathComponent()
            .appendingPathComponent("ghostty", isDirectory: false)
        try """
        #!/usr/bin/env python3
        import os
        import signal
        import sys
        import time

        deadline = time.time() + 2.0
        while time.time() < deadline:
            if os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp():
                signal.signal(signal.SIGINT, signal.SIG_DFL)
                os.kill(os.getpid(), signal.SIGINT)
            time.sleep(0.02)
        sys.exit(42)
        """.write(to: fakeGhosttyHelperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGhosttyHelperURL.path
        )

        let socketPath = "/tmp/cmux-theme-picker-cancel-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "OK")
        defer { responder.stop() }

        let command = [
            "env",
            "-i",
            "HOME=\(shellSingleQuote(root.path))",
            "CFFIXED_USER_HOME=\(shellSingleQuote(root.path))",
            "CMUX_SOCKET_PATH=\(shellSingleQuote(socketPath))",
            "CMUX_CLI_SENTRY_DISABLED=1",
            "PATH=/usr/bin:/bin",
            "/usr/bin/script",
            "-q",
            "/dev/null",
            shellSingleQuote(fakeCLIPath),
            "themes",
        ].joined(separator: " ")
        let result = runShell(command, timeout: 5)

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertFalse(result.stdout.contains("Interactive theme picker exited"), result.stdout)
        XCTAssertEqual(responder.receivedRequests, [])
    }

    @Test func testBrowserDownloadWaitUsesRequestedTimeoutForSocketResponse() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-dw-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"ok":true,"result":{"downloaded":true}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response, responseDelay: 0.4)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "browser",
                UUID().uuidString,
                "download",
                "wait",
                "--timeout-ms",
                "1000",
            ],
            environment: environment,
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
    }

    @Test func testBrowserDownloadWaitDefaultTimeoutMatchesServerDefaultWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-dw-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"ok":true,"result":{"downloaded":true}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response, responseDelay: 10.5)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "browser",
                UUID().uuidString,
                "download",
                "wait",
            ],
            environment: environment,
            timeout: 16
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
    }

    @Test func testDotPathOpenBypassesProtectedSocketForExternalCLI() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-external-open-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        let openEnvLogURL = root.appendingPathComponent("open-env.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-external-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied — only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SOCKET"] = "/tmp/cmux-stale-\(UUID().uuidString.prefix(8)).sock"
        environment["CMUX_SOCKET_PASSWORD"] = "stale-password"
        environment["CMUX_SOCKET_ENABLE"] = "0"
        environment["CMUX_SOCKET_MODE"] = "off"
        environment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        environment["CMUX_WORKSPACE_ID"] = "workspace:stale"
        environment["CMUX_PANEL_ID"] = "panel:stale"
        environment["CMUX_SURFACE_ID"] = "surface:stale"
        environment["CMUX_TAB_ID"] = "tab:stale"
        environment["CMUX_TAG"] = "keepme"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path
        environment["CMUX_TEST_OPEN_ENV_LOG"] = openEnvLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["."],
            environment: environment,
            currentDirectoryURL: workingDirectory,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        XCTAssertEqual(responder.receivedRequests, [])

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertEqual(openArguments.first, "-a")
        XCTAssertEqual(openArguments.last, workingDirectory.standardizedFileURL.path)
        XCTAssertTrue(openArguments.dropFirst().first?.hasSuffix(".app") == true, openArguments.joined(separator: " "))

        let openEnvironment = try readFakeOpenEnvironment(from: openEnvLogURL)
        for strippedKey in [
            "CMUX_ALLOW_SOCKET_OVERRIDE",
            "CMUX_SOCKET",
            "CMUX_SOCKET_ENABLE",
            "CMUX_SOCKET_MODE",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_SOCKET_PATH",
            "CMUX_PANEL_ID",
            "CMUX_SURFACE_ID",
            "CMUX_TAB_ID",
            "CMUX_WORKSPACE_ID",
        ] {
            XCTAssertFalse(
                openEnvironment.contains { $0.hasPrefix("\(strippedKey)=") },
                "\(strippedKey) leaked to LaunchServices open environment: \(openEnvironment)"
            )
        }
        XCTAssertTrue(openEnvironment.contains("CMUX_TAG=keepme"), openEnvironment.joined(separator: "\n"))
    }

    @Test func testBareRelativeDirectoryPathOpenBypassesProtectedSocketForExternalCLI() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-bare-open-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-bare-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied — only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["project"],
            environment: environment,
            currentDirectoryURL: root,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        XCTAssertEqual(responder.receivedRequests, [])

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertEqual(openArguments.last, workingDirectory.standardizedFileURL.path)
    }

    @Test func testKnownCommandStillUsesSocketWhenMatchingBareRelativePathExists() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-command-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ping", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-command-path-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "PONG")
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: environment,
            currentDirectoryURL: root,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "PONG")
        XCTAssertEqual(responder.receivedRequests, ["ping"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: openLogURL.path))
    }

    @Test func testCaseVariantBareRelativeDirectoryPathOpenBypassesProtectedSocket() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-case-path-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-case-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied — only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["Docs"],
            environment: environment,
            currentDirectoryURL: root,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        XCTAssertEqual(responder.receivedRequests, [])

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertEqual(openArguments.last, workingDirectory.standardizedFileURL.path)
    }

    @Test func testExplicitSocketPathOpenUsesRequestedSocket() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-explicit-open-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-explicit-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":true,"result":{"workspace_ref":"workspace:explicit"}}"#
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "."],
            environment: environment,
            currentDirectoryURL: workingDirectory,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK workspace:explicit")

        let request = try XCTUnwrap(responder.receivedRequests.first)
        let requestData = try XCTUnwrap(request.data(using: .utf8))
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
        )
        XCTAssertEqual(requestObject["method"] as? String, "workspace.create")
        let params = try XCTUnwrap(requestObject["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, workingDirectory.standardizedFileURL.path)

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertFalse(openArguments.contains(workingDirectory.standardizedFileURL.path), openArguments.joined(separator: " "))
    }

    func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
    }

    /// A throwaway home directory for hermetic CLI socket-resolution tests.
    ///
    /// The CLI resolves its stable socket under `homeDirectoryForCurrentUser`,
    /// which honors `CFFIXED_USER_HOME`. Tests build the socket path from this home
    /// via the canonical ``CmuxStateDirectory`` and pass the same home to the
    /// spawned CLI via `CFFIXED_USER_HOME`, so they never touch (or bind over) the
    /// developer's real `~/.local/state/cmux` (issue #5146).
    private func makeTemporaryHome() throws -> URL {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let home = URL(fileURLWithPath: "/tmp/cmxh-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func jsonResponse(result: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["ok": true, "result": result],
            options: []
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func restoreResponse(
        result: [String: Any],
        workspaceID: String? = nil,
        surfaceID: String? = nil
    ) throws -> String {
        var result = result
        result["source"] = "pid"
        result["pid_resolution"] = "controlling_tty"
        result["workspace_id"] = workspaceID ?? UUID().uuidString
        result["surface_id"] = surfaceID ?? UUID().uuidString
        return try jsonResponse(result: result)
    }

    private func jsonErrorResponse(code: String, message: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "ok": false,
                "error": [
                    "code": code,
                    "message": message,
                ],
            ],
            options: []
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// The stable control-socket path under an injected (temp) home, resolved via
    /// the canonical ``CmuxStateDirectory`` so the test exercises the real layout.
    private func stableSocketURL(home: URL) throws -> URL {
        let directory = CmuxStateDirectory.url(homeDirectory: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cmux.sock", isDirectory: false)
    }

    private func writeTheme(named name: String, background: String, to directory: URL) throws {
        try """
        background = \(background)
        foreground = #eeeeee
        cursor-color = #ff00ff
        cursor-text = #000000
        """.write(
            to: directory.appendingPathComponent(name, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func managedThemeValue(in configURL: URL) throws -> String {
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        let values = contents.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else {
                return nil
            }
            return parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return try XCTUnwrap(values.last)
    }

    private func fakeTaggedBundledCLIPath(
        sourceCLIPath: String,
        tagSlug: String,
        bundleIdentifier: String? = nil,
        bundleName: String? = nil,
        nestedIdentifierlessApp: Bool = false
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-socket-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("cmux DEV \(tagSlug).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let binURL: URL
        if nestedIdentifierlessApp {
            let nestedContentsURL = contentsURL
                .appendingPathComponent("Resources/NestedTool.app/Contents", isDirectory: true)
            binURL = nestedContentsURL.appendingPathComponent("Resources/bin", isDirectory: true)
            let nestedInfoData = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleName": "NestedTool",
                    "CFBundlePackageType": "APPL"
                ],
                format: .xml,
                options: 0
            )
            try FileManager.default.createDirectory(
                at: nestedContentsURL,
                withIntermediateDirectories: true
            )
            try nestedInfoData.write(to: nestedContentsURL.appendingPathComponent("Info.plist", isDirectory: false))
        } else {
            binURL = contentsURL.appendingPathComponent("Resources/bin", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier ?? "com.cmuxterm.app.debug.\(tagSlug.replacingOccurrences(of: "-", with: "."))",
            "CFBundleName": bundleName ?? "cmux DEV \(tagSlug)",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

        let fakeCLIURL = binURL.appendingPathComponent("cmux", isDirectory: false)
        try FileManager.default.copyItem(atPath: sourceCLIPath, toPath: fakeCLIURL.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCLIURL.path
        )
        return fakeCLIURL.path
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func lstatPathExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private func runShell(_ command: String, timeout: TimeInterval) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval,
        afterLaunch: (() -> Void)? = nil
    ) -> ProcessRunResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }
        afterLaunch?()

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private func fakeOpenScript() -> String {
        """
        #!/bin/sh
        : "${CMUX_TEST_OPEN_LOG:?}"
        : > "$CMUX_TEST_OPEN_LOG"
        printf 'fake open stdout should be suppressed\\n'
        printf 'fake open stderr should be suppressed\\n' >&2
        if [ -n "${CMUX_TEST_OPEN_ENV_LOG:-}" ]; then
          env | LC_ALL=C sort | grep '^CMUX_' > "$CMUX_TEST_OPEN_ENV_LOG" || :
        fi
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "$CMUX_TEST_OPEN_LOG"
        done
        exit 0
        """
    }

    private func readFakeOpenArguments(from url: URL) throws -> [String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return Array(contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast())
    }

    private func readFakeOpenEnvironment(from url: URL) throws -> [String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return Array(contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast())
    }
}

final class UnixSocketResponder {
    let path: String
    private let responses: [String]
    private let responseDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.cmux.tests.unix-socket-responder")
    private let lock = NSLock()
    private var stopped = false
    private var requests: [String] = []
    private var listenerFD: Int32 = -1

    convenience init(path: String, response: String, responseDelay: TimeInterval = 0) throws {
        try self.init(path: path, responses: [response], responseDelay: responseDelay)
    }

    init(path: String, responses: [String], responseDelay: TimeInterval = 0) throws {
        guard !responses.isEmpty else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.validationMissingMandatoryProperty.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "At least one socket response is required"]
            )
        }
        self.path = path
        self.responses = responses
        self.responseDelay = responseDelay

        unlink(path)
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw Self.posixError("socket")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)"]
            )
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let buffer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, pointer, maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(listenerFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = Self.posixError("bind")
            close(listenerFD)
            listenerFD = -1
            throw error
        }
        guard listen(listenerFD, 8) == 0 else {
            let error = Self.posixError("listen")
            close(listenerFD)
            listenerFD = -1
            throw error
        }

        let fd = listenerFD
        queue.async { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
    }

    deinit {
        stop()
    }

    var receivedRequests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()

        if fd >= 0 {
            close(fd)
        }
        unlink(path)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(listenerFD: Int32) {
        while !isStopped {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if isStopped {
                    return
                }
                continue
            }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { pointer in
            setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        while true {
            var request = Data()
            while true {
                var byte: UInt8 = 0
                let count = read(clientFD, &byte, 1)
                if count <= 0 {
                    return
                }
                request.append(byte)
                if byte == 0x0A {
                    break
                }
            }
            var responseIndex = 0
            if let line = String(data: request, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) {
                lock.lock()
                responseIndex = requests.count
                requests.append(line)
                lock.unlock()
            }
            if responseDelay > 0 {
                Thread.sleep(forTimeInterval: responseDelay)
            }
            let response = responses[min(responseIndex, responses.count - 1)]
            let payload = response + "\n"
            payload.withCString { pointer in
                _ = write(clientFD, pointer, strlen(pointer))
            }
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}

final class RelaySocketResponder {
    let endpoint: String
    private let relayID: String
    private let responses: [String]
    private let queue = DispatchQueue(label: "com.cmux.tests.relay-socket-responder")
    private let lock = NSLock()
    private var stopped = false
    private var requests: [String] = []
    private var listenerFD: Int32 = -1

    init(relayID: String, responses: [String]) throws {
        guard !responses.isEmpty else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.validationMissingMandatoryProperty.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "At least one relay response is required"]
            )
        }
        self.relayID = relayID
        self.responses = responses

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError("socket") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            let error = Self.posixError("bind/listen")
            close(fd)
            throw error
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                getsockname(fd, socketPointer, &boundLength)
            }
        }
        guard nameResult == 0 else {
            let error = Self.posixError("getsockname")
            close(fd)
            throw error
        }

        listenerFD = fd
        endpoint = "127.0.0.1:\(UInt16(bigEndian: boundAddress.sin_port))"
        queue.async { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
    }

    deinit {
        stop()
    }

    var receivedRequests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(listenerFD: Int32) {
        while !isStopped {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if isStopped { return }
                continue
            }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var noSigPipe: Int32 = 1
        setsockopt(
            clientFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let challenge = #"{"protocol":"cmux-relay-auth","version":1,"relay_id":"\#(relayID)","nonce":"test-nonce"}"#
        guard writeLine(challenge, to: clientFD), readLine(from: clientFD) != nil else { return }
        guard writeLine(#"{"ok":true}"#, to: clientFD),
              let request = readLine(from: clientFD) else { return }

        lock.lock()
        let responseIndex = requests.count
        requests.append(request)
        lock.unlock()
        _ = writeLine(responses[min(responseIndex, responses.count - 1)], to: clientFD)
    }

    private func readLine(from fd: Int32) -> String? {
        var data = Data()
        while true {
            var byte: UInt8 = 0
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            if byte == 0x0A { return String(data: data, encoding: .utf8) }
            data.append(byte)
        }
    }

    private func writeLine(_ line: String, to fd: Int32) -> Bool {
        let data = Data((line + "\n").utf8)
        return data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = write(fd, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
            return true
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
