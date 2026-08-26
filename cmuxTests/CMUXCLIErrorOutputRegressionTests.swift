import CmuxSettings
import Darwin
import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct CMUXCLIErrorOutputRegressionTests: Sendable {
    struct ProcessRunResult: @unchecked Sendable {
        let status: Int32
        let stdout: String
        /// Captured on its own pipe, not merged into `stdout`.
        ///
        /// Roughly thirty tests here parse stdout as JSON or compare it to an exact
        /// reply. While both streams shared one pipe, a single unrelated diagnostic line
        /// from the runtime landed in the middle of that payload and failed the content
        /// check instead of naming itself.
        let stderr: String
        let timedOut: Bool
        /// Defaulted so existing call sites are unaffected. A process killed by a signal reports
        /// `.uncaughtSignal`, and its `terminationStatus` is the signal number — indistinguishable
        /// from an ordinary non-zero exit if you only look at the status.
        var terminationReason: Process.TerminationReason = .exit

        var diedFromSignal: Bool { terminationReason == .uncaughtSignal }

        /// Both streams together, for a check that cares whether the CLI said something
        /// at all rather than which stream carried it.
        var combinedOutput: String { stdout + stderr }

        var diagnostics: String {
            "status=\(status) reason=\(diedFromSignal ? "uncaughtSignal" : "exit") "
                + "timedOut=\(timedOut) stdout=\(stdout.isEmpty ? "<empty>" : stdout) "
                + "stderr=\(stderr.isEmpty ? "<empty>" : stderr)"
        }
    }

    @Test func testCLIErrorPathDoesNotCrashWhenStderrIsClosed() throws {
        let cliPath = try bundledCLIPath()
        // Pin the socket and the home directory. Without CMUX_SOCKET_PATH the CLI's resolution can
        // fall back to a machine-global marker file and reach whatever app happens to be running,
        // which would make this test's exit code depend on the machine rather than on the CLI.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-stderr-closed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let socketPath = home.appendingPathComponent("cmux.sock").path

        // `exec` so the process we wait on is the CLI itself. Without it the shell is the child, and
        // a shell reports a signalled child as an ordinary exit with status 128+signal — which would
        // hide the very crash this test exists to catch.
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 "
                + "CMUX_SOCKET_PATH=\(shellSingleQuote(socketPath)) "
                + "CFFIXED_USER_HOME=\(shellSingleQuote(home.path)) "
                + "HOME=\(shellSingleQuote(home.path)) "
                + "exec \(shellSingleQuote(cliPath)) definitely-not-a-command 2>&-",
            // The assignments above are what the CLI sees; this is the shell's own
            // environment, kept bare so no `CMUX_*` the test host was launched with
            // leaks through to the child.
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 5
        )

        // What is guarded here is a crash, not an exit code. cc4a6109d8 replaced
        // FileHandle.standardError.write — which raises, and aborts the process, when stderr is
        // closed — with a raw Darwin.write that returns -1 on EBADF. So the oracle is that the CLI
        // exited on its own terms rather than dying from a signal.
        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertFalse(result.diedFromSignal, result.diagnostics)
        // 1, measured, and deterministic for this fixture: the pinned socket has no listener, so the
        // CLI fails at connect and the top-level handler exits 1 before the unknown-command arm (which
        // would exit 2) is ever reached. That ordering is what makes this a good exercise of the guard
        // rather than a weaker one — the connect error is written to the stderr this test has closed.
        // Asserting the exact code rather than merely non-zero keeps the test from passing when the CLI
        // fails for some unrelated reason. Nothing is asserted about stdout: every message on this path
        // goes to the closed stderr.
        XCTAssertEqual(result.status, 1, result.diagnostics)
    }

    @Test func testAgentTeamsHelpForwardsToExternalAgentCLI() throws {
        let cliPath = try bundledCLIPath()
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binURL = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let launchMarker = home.appendingPathComponent("external-agent-launched", isDirectory: false)
        for executableName in ["claude", "codex"] {
            let executableURL = binURL.appendingPathComponent(executableName, isDirectory: false)
            try """
            #!/bin/sh
            {
              printf 'provider=%s\n' "${0##*/}"
              for argument in "$@"; do
                printf 'arg=%s\n' "$argument"
              done
            } > "$CMUX_TEST_AGENT_LAUNCH_MARKER"
            printf 'fake provider help\n'
            exit 0
            """.write(to: executableURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executableURL.path
            )
        }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_AGENT_LAUNCH_MARKER"] = launchMarker.path
        environment["PATH"] = "\(binURL.path):/usr/bin:/bin"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        // Pin this no-socket command to a per-run path so the fixture cannot use
        // any ambient discovery marker from the host machine.
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-agent-teams-help-\(UUID().uuidString.prefix(8)).sock"

        for (command, provider) in [("claude-teams", "claude"), ("codex-teams", "codex")] {
            try? FileManager.default.removeItem(at: launchMarker)
            let result = runProcess(
                executablePath: cliPath,
                arguments: [command, "--help"],
                environment: environment
            )

            XCTAssertFalse(result.timedOut, result.diagnostics)
            XCTAssertEqual(result.status, 0, result.diagnostics)
            XCTAssertTrue(result.stdout.contains("fake provider help"), result.diagnostics)
            let launch = try String(contentsOf: launchMarker, encoding: .utf8)
            let launchLines = launch.components(separatedBy: .newlines)
            XCTAssertTrue(launchLines.contains("provider=\(provider)"), result.diagnostics)
            XCTAssertTrue(launchLines.contains("arg=--help"), result.diagnostics)
        }
    }

    @Test func testSurfaceResumeSetCLIRejectsUnknownFlagWithoutReplacingBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-resume-flag-\(UUID().uuidString.prefix(8)).sock"
        let approvedCommand = "codex resume approved-session"
        let approvedResponse = try resumeBindingResponse(command: approvedCommand)
        // The third response is only consumed by the buggy path: show, invalid set, show.
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [
                approvedResponse,
                approvedResponse,
                try resumeBindingResponse(command: "--bad-flag"),
            ]
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let before = runProcess(
            executablePath: cliPath,
            arguments: ["surface", "resume", "show", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!before.timedOut, Comment(rawValue: before.diagnostics))
        #expect(before.status == 0, Comment(rawValue: before.diagnostics))
        let commandBefore = try resumeBindingCommand(from: before.stdout)
        #expect(commandBefore == approvedCommand)

        let rejected = runProcess(
            executablePath: cliPath,
            arguments: ["surface", "resume", "set", "--bad-flag"],
            environment: environment,
            timeout: 5
        )
        #expect(!rejected.timedOut, Comment(rawValue: rejected.diagnostics))
        #expect(rejected.status != 0, Comment(rawValue: rejected.diagnostics))
        #expect(rejected.stdout.isEmpty, Comment(rawValue: rejected.diagnostics))
        #expect(
            rejected.stderr.contains("surface resume set: unknown flag '--bad-flag'"),
            Comment(rawValue: rejected.diagnostics)
        )
        let knownFlags = [
            "--checkpoint", "--checkpoint-id", "--cwd", "--kind", "--name",
            "--shell", "--source", "--surface", "--window", "--workspace",
        ].joined(separator: ", ")
        #expect(
            rejected.stderr.contains("Known flags: \(knownFlags)."),
            Comment(rawValue: rejected.diagnostics)
        )

        let after = runProcess(
            executablePath: cliPath,
            arguments: ["surface", "resume", "show", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!after.timedOut, Comment(rawValue: after.diagnostics))
        #expect(after.status == 0, Comment(rawValue: after.diagnostics))
        let commandAfter = try resumeBindingCommand(from: after.stdout)
        #expect(commandAfter == commandBefore)

        let methods = try responder.receivedRequests.map { request in
            let data = Data(request.utf8)
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(payload["method"] as? String)
        }
        #expect(
            methods == ["surface.resume.get", "surface.resume.get"],
            "An unknown flag must be rejected before a binding mutation request is sent: \(methods)"
        )
    }

    @Test func testIOSContextFromTerminalFallsBackToWorkspaceSimulator() throws {
        let cliPath = try bundledCLIPath()
        let workspaceID = UUID().uuidString.lowercased()
        let surfaceID = UUID().uuidString.lowercased()
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
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_SURFACE_ID"] = surfaceID

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "ios", "context", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        let requests = responder.receivedRequests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let data = try #require(request.data(using: String.Encoding.utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["method"] as? String == "simulator.context")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == workspaceID)
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
        environment["CMUX_CLI_TTY_NAME"] = "ttys9258"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "--surface"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertNotEqual(result.status, 0, result.diagnostics)
        XCTAssertTrue(result.stdout.contains("pwd=\(workingDirectory.path)\n"), result.diagnostics)
        XCTAssertTrue(result.stdout.contains("env=値 with spaces\n"), result.diagnostics)
        for argument in arguments.dropFirst() {
            XCTAssertTrue(result.stdout.contains("arg=\(argument)\n"), result.diagnostics)
        }
        let methods = try responder.receivedRequests.map { request in
            let data = try XCTUnwrap(request.data(using: .utf8))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            return try XCTUnwrap(object["method"] as? String)
        }
        XCTAssertEqual(methods, ["system.identify", "surface.resume.get"])
    }

    @Test func testRestoreDoesNotExecuteMissingCodexCheckpointAndGuardsStaleBindingClear() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux restore codex missing \(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("saved cwd", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let attemptedURL = root.appendingPathComponent("codex-attempted", isDirectory: false)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try createEmptyCodexStateDatabase(at: codexHome.appendingPathComponent("state_5.sqlite"))
        try """
        #!/bin/sh
        touch \(shellSingleQuote(attemptedURL.path))
        printf 'ERROR: No saved session found with ID %s\\n' "$3" >&2
        exit 42
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let checkpointID = "01a03bc1-7649-7ec3-bdf7-03acf979e086"
        let surfaceID = UUID().uuidString.lowercased()
        let workspaceID = UUID().uuidString.lowercased()
        let response = try restoreResponse(
            result: [
                "restore_record": [
                    "mode": "resumeAgent",
                    "kind": "codex",
                    "checkpoint_id": checkpointID,
                    "source": "session-snapshot",
                    "working_directory": workingDirectory.path,
                    "environment": ["CODEX_HOME": codexHome.path],
                    // Exercise the older prepared-argv-only shape: the
                    // checkpoint still needs validation even without launch
                    // capture metadata.
                    "prepared_arguments": ["codex", "resume", checkpointID],
                ],
                // This binding models a pre-#10100 snapshot: it has no durable
                // provenance, but it still claims the stale Codex checkpoint.
                "resume_binding": [
                    "name": "Codex",
                    "kind": "codex",
                    "command": "codex resume \(checkpointID)",
                    "cwd": workingDirectory.path,
                    "checkpoint_id": checkpointID,
                    "source": "agent-hook",
                    "auto_resume": true,
                ],
            ],
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let clearResponse = try jsonResponse(result: [
            "cleared": true,
            "resume_binding": NSNull(),
        ])
        let socketPath = "/tmp/cmux-restore-codex-missing-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [response, clearResponse]
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["HOME"] = root.path
        environment["CODEX_HOME"] = codexHome.path
        environment["PATH"] = "\(root.path):/usr/bin:/bin"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "--surface", surfaceID, "codex", checkpointID],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: attemptedURL.path),
            "a missing Codex checkpoint must never reach codex resume"
        )
        XCTAssertTrue(
            result.stderr.contains("saved agent session is unavailable"),
            result.diagnostics
        )

        let requests = try responder.receivedRequests.map { request in
            let data = try XCTUnwrap(request.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["surface.resume.get", "surface.resume.clear"]
        )
        let clearParams = try XCTUnwrap(requests.last?["params"] as? [String: Any])
        XCTAssertEqual(clearParams["checkpoint_id"] as? String, checkpointID)
        XCTAssertEqual(clearParams["source"] as? String, "agent-hook")
        XCTAssertEqual(clearParams["agent_session_ended"] as? Bool, true)
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

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 1, result.diagnostics)
        XCTAssertTrue(
            result.stderr.contains(
                "restore: the saved agent command is unavailable. "
                    + "Make sure the agent is installed, then retry."
            ),
            result.diagnostics
        )
        let userFacingErrors = result.stderr
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("Error: ") }
        XCTAssertEqual(userFacingErrors.count, 1, result.diagnostics)
        XCTAssertFalse(userFacingErrors.joined().contains(executableName), result.diagnostics)
        XCTAssertFalse(userFacingErrors.joined().contains(root.path), result.diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testRestoreRepairsTransientHermesTUITransportCheckpoint() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux hermes restore recovery \(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fake-hermes", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        for argument in "$@"; do
          printf 'arg=%s\\n' "$argument"
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let transportID = "96dd0dcc"
        let realSessionID = "20260808_155500_real-hermes-session"
        let commonRecord: [String: Any] = [
            "workspaceId": workspaceID,
            "surfaceId": surfaceID,
            "pid": 12_345,
            "pidStartSeconds": 678,
            "pidStartMicroseconds": 901,
            "startedAt": 100.0,
        ]
        var realRecord = commonRecord
        realRecord["sessionId"] = realSessionID
        realRecord["updatedAt"] = 200.0
        realRecord["launchCommand"] = [
            "launcher": "hermes-agent",
            "arguments": [executable.path],
            "executablePath": executable.path,
            "workingDirectory": root.path,
        ]
        var corruptRecord = commonRecord
        corruptRecord["sessionId"] = transportID
        corruptRecord["updatedAt"] = 201.0
        let stateData = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    realSessionID: realRecord,
                    transportID: corruptRecord,
                ],
            ],
            options: [.sortedKeys]
        )
        try stateData.write(
            to: root.appendingPathComponent("hermes-agent-hook-sessions.json", isDirectory: false)
        )

        let response = try restoreResponse(result: [
            "restore_record": [
                "mode": "resumeAgent",
                "kind": "hermes-agent",
                "checkpoint_id": transportID,
                "working_directory": root.path,
                "environment": [:],
                "launch_command": [
                    "launcher": "hermes-agent",
                    "arguments": [executable.path],
                    "executable_path": executable.path,
                    "working_directory": root.path,
                ],
            ],
        ])
        let socketPath = "/tmp/cmux-hermes-restore-recovery-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = surfaceID
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["HOME"] = root.path
        try writeHermesStateDatabase(
            homeDirectory: root,
            sessionID: realSessionID,
            cwd: root.path,
            startedAt: 110
        )

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "hermes-agent", transportID],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertTrue(result.stdout.contains("arg=--resume\n"), result.diagnostics)
        XCTAssertTrue(result.stdout.contains("arg=\(realSessionID)\n"), result.diagnostics)
        XCTAssertFalse(result.stdout.contains("arg=\(transportID)\n"), result.diagnostics)
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

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 1, result.diagnostics)
        XCTAssertTrue(
            result.stderr.contains(
                "restore: provider setup took too long. "
                    + "Check the provider connection, then retry."
            ),
            result.diagnostics
        )
        XCTAssertFalse(result.combinedOutput.contains("fake hermes"), result.diagnostics)
        XCTAssertFalse(result.combinedOutput.contains("model.provider"), result.diagnostics)
        XCTAssertFalse(result.combinedOutput.contains("preflight stdout chatter"), result.diagnostics)
        XCTAssertFalse(result.combinedOutput.contains("preflight stderr chatter"), result.diagnostics)
        XCTAssertFalse(result.combinedOutput.contains("unexpected agent launch"), result.diagnostics)
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

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        let outputLines = result.stdout.components(separatedBy: .newlines)
        let observedPWD = try XCTUnwrap(outputLines.first(where: { $0.hasPrefix("pwd=") }))
            .dropFirst("pwd=".count)
        let observedArguments = outputLines.compactMap { line -> String? in
            guard line.hasPrefix("arg=") else { return nil }
            return String(line.dropFirst("arg=".count))
        }
        let cwdFlagIndex = try XCTUnwrap(observedArguments.firstIndex(of: "--cwd"))
        let sessionFlagIndex = try XCTUnwrap(observedArguments.firstIndex(of: "--session"))
        let observedCwdArgument = try XCTUnwrap(observedArguments.dropFirst(cwdFlagIndex + 1).first)
        let observedSessionID = try XCTUnwrap(observedArguments.dropFirst(sessionFlagIndex + 1).first)
        let canonicalRoot = try XCTUnwrap(canonicalExistingPath(root.path))

        XCTAssertEqual(cwdFlagIndex, 0, result.diagnostics)
        XCTAssertEqual(sessionFlagIndex, 2, result.diagnostics)
        XCTAssertEqual(try XCTUnwrap(canonicalExistingPath(String(observedPWD))), canonicalRoot, result.diagnostics)
        XCTAssertEqual(try XCTUnwrap(canonicalExistingPath(observedCwdArgument)), canonicalRoot, result.diagnostics)
        XCTAssertEqual(observedSessionID, checkpointID, result.diagnostics)
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
                "kind": "command",
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
            arguments: ["restore", "command", checkpointID],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertTrue(result.stdout.contains("legacy=\(root.path)|kept"), result.diagnostics)
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

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertTrue(
            result.stdout.contains("fallback=\(root.path)|structured"),
            result.diagnostics
        )
    }

    @Test func testRestorePositionalFormUsesCallerTTYAcrossSurfaceEnvironmentStates() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "issue-9624-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID().uuidString
        let trueSurfaceID = UUID().uuidString
        let staleSurfaceID = UUID().uuidString
        let identifyResponse = try jsonResponse(result: [
            "caller": [
                "workspace_id": workspaceID,
                "surface_id": trueSurfaceID,
            ],
            "focused": [:],
        ])
        let recordResponse = try jsonResponse(result: [
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
        let surfaceEnvironmentStates: [(label: String, surfaceID: String?)] = [
            ("unset", nil),
            ("correct", trueSurfaceID),
            ("stale-valid", staleSurfaceID),
        ]

        for (index, state) in surfaceEnvironmentStates.enumerated() {
            let socketPath = "/tmp/cmux-r9624-\(UUID().uuidString.prefix(8))-\(index).sock"
            let responder = try UnixSocketResponder(
                path: socketPath,
                responses: [identifyResponse, recordResponse]
            )
            defer { responder.stop() }
            var environment = ProcessInfo.processInfo.environment
            for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
                environment.removeValue(forKey: key)
            }
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_WORKSPACE_ID"] = workspaceID
            environment["CMUX_CLI_TTY_NAME"] = "ttys9624"
            if let surfaceID = state.surfaceID {
                environment["CMUX_SURFACE_ID"] = surfaceID
            }

            let result = runProcess(
                executablePath: cliPath,
                arguments: ["restore", "custom", checkpointID],
                environment: environment,
                timeout: 5
            )

            #expect(
                !result.timedOut,
                Comment(rawValue: "\(state.label): \(result.diagnostics)")
            )
            #expect(
                result.status == 0,
                Comment(rawValue: "\(state.label): \(result.diagnostics)")
            )
            let requests = try responder.receivedRequests.map { request in
                let data = try #require(request.data(using: .utf8))
                return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
            #expect(
                requests.compactMap { $0["method"] as? String } == [
                    "system.identify",
                    "surface.resume.get",
                ],
                Comment(rawValue: "\(state.label): \(requests)")
            )
            let identifyParams = try #require(requests.first?["params"] as? [String: Any])
            #expect(identifyParams["caller_tty"] as? String == "ttys9624")
            #expect(identifyParams["caller"] == nil)
            let restoreParams = try #require(requests.last?["params"] as? [String: Any])
            #expect(restoreParams["surface_id"] as? String == trueSurfaceID)
            #expect(restoreParams["surface_id"] as? String != staleSurfaceID)
        }
    }

    @Test func testRestoreFallsBackToAmbientSurfaceWhenCallerTTYIsUnavailable() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "issue-9624-env-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let identifyResponse = try jsonResponse(result: [
            "caller": [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
            ],
            "focused": [:],
        ])
        let recordResponse = try jsonResponse(result: [
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
        let socketPath = "/tmp/cmux-r9624-env-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [identifyResponse, recordResponse]
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_SURFACE_ID"] = surfaceID

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "custom", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "system.identify",
            "surface.resume.get",
        ])
        let identifyParams = try #require(requests.first?["params"] as? [String: Any])
        let caller = try #require(identifyParams["caller"] as? [String: Any])
        #expect(caller["workspace_id"] as? String == workspaceID)
        #expect(caller["surface_id"] as? String == surfaceID)
        let restoreParams = try #require(requests.last?["params"] as? [String: Any])
        #expect(restoreParams["surface_id"] as? String == surfaceID)
    }

    @Test func testRestoreBareSurfaceFormUsesCallerTTY() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "issue-9624-bare-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID().uuidString
        let callerSurfaceID = UUID().uuidString
        let staleSurfaceID = UUID().uuidString
        let identifyResponse = try jsonResponse(result: [
            "caller": [
                "workspace_id": workspaceID,
                "surface_id": callerSurfaceID,
            ],
            "focused": [:],
        ])
        let recordResponse = try jsonResponse(result: [
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
        let socketPath = "/tmp/cmux-r9624-bare-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [identifyResponse, recordResponse]
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_SURFACE_ID"] = staleSurfaceID
        environment["CMUX_CLI_TTY_NAME"] = "ttys9624"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "--surface"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "system.identify",
            "surface.resume.get",
        ])
        let identifyParams = try #require(requests.first?["params"] as? [String: Any])
        #expect(identifyParams["caller_tty"] as? String == "ttys9624")
        #expect(identifyParams["caller"] == nil)
        let restoreParams = try #require(requests.last?["params"] as? [String: Any])
        #expect(restoreParams["surface_id"] as? String == callerSurfaceID)
        #expect(restoreParams["surface_id"] as? String != staleSurfaceID)
    }

    @Test func testRestorePositionalFormAcceptsExplicitSurfaceFlag() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "issue-9624-explicit-\(UUID().uuidString.lowercased())"
        let surfaceID = UUID().uuidString
        let recordResponse = try jsonResponse(result: [
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
        let argumentOrders = [
            ["custom", checkpointID, "--surface", surfaceID],
            ["--surface", surfaceID, "custom", checkpointID],
            ["--surface=\(surfaceID)", "custom", checkpointID],
        ]

        for (index, restoreArguments) in argumentOrders.enumerated() {
            let socketPath = "/tmp/cmux-r9624-flag-\(UUID().uuidString.prefix(8))-\(index).sock"
            let responder = try UnixSocketResponder(path: socketPath, response: recordResponse)
            defer { responder.stop() }
            var environment = ProcessInfo.processInfo.environment
            for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
                environment.removeValue(forKey: key)
            }
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            environment["CMUX_SOCKET_PATH"] = socketPath

            let result = runProcess(
                executablePath: cliPath,
                arguments: ["restore"] + restoreArguments,
                environment: environment,
                timeout: 5
            )

            #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
            #expect(result.status == 0, Comment(rawValue: result.diagnostics))
            let request = try #require(responder.receivedRequests.first)
            let data = try #require(request.data(using: .utf8))
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(payload["method"] as? String == "surface.resume.get")
            let params = try #require(payload["params"] as? [String: Any])
            #expect(params["surface_id"] as? String == surfaceID)
        }

        var duplicateEnvironment = ProcessInfo.processInfo.environment
        for key in Array(duplicateEnvironment.keys) where key.hasPrefix("CMUX_") {
            duplicateEnvironment.removeValue(forKey: key)
        }
        let duplicateSocketPath = "/tmp/cmux-r9624-dup-\(UUID().uuidString.prefix(8)).sock"
        let duplicateResponder = try UnixSocketResponder(
            path: duplicateSocketPath,
            response: recordResponse
        )
        defer { duplicateResponder.stop() }
        duplicateEnvironment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        duplicateEnvironment["CMUX_SOCKET_PATH"] = duplicateSocketPath
        let duplicateResult = runProcess(
            executablePath: cliPath,
            arguments: [
                "restore",
                "custom",
                checkpointID,
                "--surface",
                surfaceID,
                "--surface=\(surfaceID)",
            ],
            environment: duplicateEnvironment,
            timeout: 5
        )

        #expect(!duplicateResult.timedOut, Comment(rawValue: duplicateResult.diagnostics))
        #expect(duplicateResult.status == 1, Comment(rawValue: duplicateResult.diagnostics))
        #expect(
            duplicateResult.stderr.contains("Usage: cmux restore --surface [id|ref]"),
            Comment(rawValue: duplicateResult.diagnostics)
        )
        #expect(duplicateResponder.receivedRequests.isEmpty)
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

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 1, result.diagnostics)
        XCTAssertTrue(
            result.stderr.contains(
                "restore: the current cmux surface could not be identified. "
                    + "Retry from this terminal or pass --surface <id|ref>."
            ),
            result.diagnostics
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

            XCTAssertFalse(result.timedOut, result.diagnostics)
            XCTAssertEqual(result.status, 1, result.diagnostics)
            XCTAssertTrue(
                result.stderr.contains("Run 'cmux restore --surface'"),
                result.diagnostics
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

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 1, result.diagnostics)
        XCTAssertTrue(
            result.stderr.contains("Socket not found at \(socketPath)"),
            result.diagnostics
        )
        XCTAssertFalse(
            result.combinedOutput.contains(
                "Retry the visible restore command after cmux finishes opening."
            ),
            result.diagnostics
        )
    }

    @Test func testRestoreWaitsForControlSocketDuringAppStartup() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = UUID().uuidString.lowercased()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let currentWorkspaceResponse = try jsonResponse(result: [
            "workspace_id": workspaceID,
        ])
        let identifyResponse = try jsonResponse(result: [
            "caller": [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
            ],
            "focused": [:],
        ])
        let recordResponse = try jsonResponse(result: [
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
        let fixtureDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-restore-startup-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let socketPath = fixtureDirectory.appendingPathComponent("cmux.sock", isDirectory: false).path
        let debugLogPath = fixtureDirectory.appendingPathComponent("cli.log", isDirectory: false).path
        var startupSocketFD = try bindUnavailableUnixSocket(at: socketPath)
        var responder: UnixSocketResponder?
        defer {
            if startupSocketFD >= 0 {
                close(startupSocketFD)
            }
            responder?.stop()
            unlink(socketPath)
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_DEBUG_LOG"] = debugLogPath
        environment["CMUX_SURFACE_ID"] = surfaceID

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
                // The CLI emits this diagnostic at the readiness boundary. Wait
                // for that explicit milestone before making the same socket inode
                // listen; this avoids turning the regression into a wall-clock race.
                guard self.waitForFileContentsUsingKqueue(
                    URL(fileURLWithPath: debugLogPath),
                    containing: "socket.connect.wait.entered",
                    timeout: 3
                ) else {
                    return
                }
                close(startupSocketFD)
                startupSocketFD = -1
                responder = try? UnixSocketResponder(
                    path: socketPath,
                    responses: [currentWorkspaceResponse, identifyResponse, recordResponse]
                )
            }
        )

        let requiredResponder = try #require(responder)
        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        let methods = try requiredResponder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(payload["method"] as? String)
        }
        #expect(methods == [
            "workspace.current",
            "system.identify",
            "surface.resume.get",
        ])
    }

    @Test func testRestoreWaitsForRelayDuringAppStartup() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let relayID = "relay-\(UUID().uuidString.lowercased())"
        let targetResponse = try jsonResponse(result: [
            "terminals": [[
                "tty": "0",
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
            ]],
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
        let fixtureDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-restore-relay-startup-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let debugLogPath = fixtureDirectory.appendingPathComponent("cli.log", isDirectory: false).path
        let responder = try RelaySocketResponder(
            relayID: relayID,
            responses: [targetResponse, recordResponse],
            startListening: false
        )
        defer {
            responder.stop()
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
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
        environment["CMUX_DEBUG_LOG"] = debugLogPath

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5,
            afterLaunch: {
                guard self.waitForFileContentsUsingKqueue(
                    URL(fileURLWithPath: debugLogPath),
                    containing: "socket.connect.wait.entered",
                    timeout: 3
                ) else {
                    return
                }
                // Keep the bound TCP endpoint unavailable through the waiter's
                // first connection attempt. Without relay error classification,
                // that attempt fails permanently instead of reaching a retry.
                usleep(100_000)
                responder.startListening()
            }
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "agent.resolve_delivery_target",
            "surface.resume.get",
        ])
    }

    @Test(arguments: ["pi", "grok"])
    func testRestorePrefersCallerTTYOverStaleAmbientRouting(kind: String) throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "\(kind)-\(UUID().uuidString.lowercased())"
        let staleSurfaceID = UUID().uuidString
        let currentSurfaceID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let callerTargetResponse = try jsonResponse(result: [
            "caller": [
                "workspace_id": workspaceID,
                "surface_id": currentSurfaceID,
            ],
            "focused": [:],
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
        environment["CMUX_CLI_TTY_NAME"] = "ttys9380"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", kind, checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "system.identify",
            "surface.resume.get",
        ])
        let callerTargetRequest = try #require(requests.first)
        let callerTargetParams = try #require(callerTargetRequest["params"] as? [String: Any])
        #expect(callerTargetParams["caller_tty"] as? String == "ttys9380")
        #expect(callerTargetParams["caller"] == nil)
        let restoreRequest = try #require(requests.last)
        let restoreParams = try #require(restoreRequest["params"] as? [String: Any])
        #expect(restoreParams["surface_id"] as? String == currentSurfaceID)
        #expect(restoreParams["surface_id"] as? String != staleSurfaceID)
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

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status != 0, Comment(rawValue: result.diagnostics))
        #expect(
            result.stderr.contains("the current cmux surface could not be identified"),
            Comment(rawValue: result.diagnostics)
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

    @Test func testRestoreFallsBackToAmbientSurfaceWhenCallerTTYIsNotFound() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let callerTargetResponse = try jsonResponse(result: [
            "caller": NSNull(),
            "focused": [:],
        ])
        let ambientResponse = try restoreResponse(
            result: [
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
            ],
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let socketPath = "/tmp/cmux-restore-ambiguous-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [callerTargetResponse, ambientResponse, ambientResponse]
        )
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_SURFACE_ID"] = surfaceID
        environment["CMUX_CLI_TTY_NAME"] = "ttys9380"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "system.identify",
            "system.identify",
            "surface.resume.get",
        ])
        let ttyParams = try #require(requests.first?["params"] as? [String: Any])
        #expect(ttyParams["caller_tty"] as? String == "ttys9380")
        #expect(ttyParams["caller"] == nil)
        let environmentParams = try #require(requests.dropFirst().first?["params"] as? [String: Any])
        let caller = try #require(environmentParams["caller"] as? [String: Any])
        #expect(caller["workspace_id"] as? String == workspaceID)
        #expect(caller["surface_id"] as? String == surfaceID)
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

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "system.identify",
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

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
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

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
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

    @Test func testRestoreRejectsMalformedCallerTTYTargetWithoutFallingBack() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let callerTargetResponse = try jsonResponse(result: [
            "caller": [
                "workspace_id": UUID().uuidString,
                "surface_id": "not-a-surface-id",
            ],
            "focused": [:],
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
        environment["CMUX_CLI_TTY_NAME"] = "ttys9380"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status != 0, Comment(rawValue: result.diagnostics))
        #expect(
            result.stderr.contains("the current cmux surface could not be identified"),
            Comment(rawValue: result.diagnostics)
        )
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "system.identify",
        ])
    }

    @Test func testRestoreDoesNotReuseSocketAfterCallerIdentifyTimeout() throws {
        let cliPath = try bundledCLIPath()
        let checkpointID = "pi-\(UUID().uuidString.lowercased())"
        let currentSurfaceID = UUID().uuidString
        let callerTargetResponse = try jsonResponse(result: [
            "caller": [
                "workspace_id": UUID().uuidString,
                "surface_id": currentSurfaceID,
            ],
            "focused": [:],
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
        environment["CMUX_CLI_TTY_NAME"] = "ttys9380"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status != 0, Comment(rawValue: result.diagnostics))
        #expect(result.stderr.contains("Command timed out"), Comment(rawValue: result.diagnostics))
        #expect(
            !result.combinedOutput.contains("this session has nothing to restore"),
            Comment(rawValue: result.diagnostics)
        )
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "system.identify",
        ])
    }

    @Test func testBundledCLIInTaggedDebugAppPrefersItsOwnSocketWithoutEnvironmentOverride() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-socket-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)

        // The CLI only accepts OK / OK … / PONG / ERROR: … / JSON as a complete single-line
        // reply. A bareword sends it into the multiline drain pass, where reconfiguring the
        // receive timeout on an already-closed socket fails with EINVAL and the CLI reports
        // "Invalid argument" instead of the reply it already has.
        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "OK STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "OK TAGGED")
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
        // No CMUX_SOCKET_PATH on purpose: where the CLI lands with no override is the
        // whole subject. That stays inside the test because the tag slug is unique per
        // run, so the tagged default socket and the marker file the CLI consults are both
        // named after this run. CFFIXED_USER_HOME moves the stable socket into the temp
        // home (it overrides homeDirectoryForCurrentUser).
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK TAGGED",
            result.diagnostics
        )
        // The point of this test: the tagged socket was chosen and the stable one was not. These
        // hold whatever framing the reply uses, so a future reply change cannot make it vacuous.
        XCTAssertEqual(taggedResponder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertEqual(stableResponder.receivedRequests, [], result.diagnostics)
    }

    @Test func testAmbientTaggedCLIFallsBackToLiveStableSocketAfterDeadTagSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-ambient-fallback-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        defer { try? FileManager.default.removeItem(atPath: taggedSocketPath) }

        let stableSocketURL = try stableSocketURL(home: home)
        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "PONG STABLE")
        defer { stableResponder.stop() }

        // Reproduce the reload chain: the tagged listener is gone, but its per-tag
        // marker still advertises the dead socket.
        let markerDirectory = CmuxStateDirectory.url(homeDirectory: home)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        try writeStableSocketMarker(home: home)
        let markerURL = markerDirectory.appendingPathComponent(
            "dev-\(tagSlug)-last-socket-path",
            isDirectory: false
        )
        try "\(taggedSocketPath)\n".write(to: markerURL, atomically: true, encoding: .utf8)

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TAG"] = tagSlug
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "PONG STABLE",
            result.diagnostics
        )
        XCTAssertEqual(stableResponder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertTrue(
            result.stderr.contains(stableSocketURL.path),
            "A cross-instance fallback must identify the resolved socket.\n\(result.diagnostics)"
        )
        XCTAssertTrue(
            result.stderr.contains(taggedSocketPath),
            "The reroute notice should name the unavailable tagged socket.\n\(result.diagnostics)"
        )
    }

    @Test func testAmbientTaggedCLIPrefersStableDefaultBeforeLiveLastSocketMarker() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-stable-before-marker-\(UUID().uuidString.lowercased())"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let stableSocketURL = try stableSocketURL(home: home)
        let markerSocketPath = "/tmp/cmux-marker-live-\(UUID().uuidString.lowercased()).sock"
        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "PONG STABLE")
        defer { stableResponder.stop() }
        let markerResponder = try UnixSocketResponder(path: markerSocketPath, response: "PONG MARKER")
        defer { markerResponder.stop() }

        let markerDirectory = CmuxStateDirectory.url(homeDirectory: home)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        let markerURL = markerDirectory.appendingPathComponent(
            "dev-\(tagSlug)-last-socket-path",
            isDirectory: false
        )
        try "\(markerSocketPath)\n".write(to: markerURL, atomically: true, encoding: .utf8)

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        #expect(stableResponder.receivedRequests == ["ping"])
        #expect(markerResponder.receivedRequests.isEmpty)
    }

    @Test func testAmbientTaggedCLIListsEveryDeadSocketCandidateOnFailure() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-ambient-all-dead-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let markerSocketPath = "/tmp/cmux-marker-\(UUID().uuidString.lowercased()).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        defer {
            try? FileManager.default.removeItem(atPath: taggedSocketPath)
            try? FileManager.default.removeItem(atPath: markerSocketPath)
            try? FileManager.default.removeItem(
                at: CmuxStateDirectory.url(homeDirectory: home)
                    .appendingPathComponent("dev-\(tagSlug)-last-socket-path", isDirectory: false)
            )
        }

        let stableSocketURL = try stableSocketURL(home: home)
        let markerDirectory = CmuxStateDirectory.url(homeDirectory: home)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        try writeStableSocketMarker(home: home)
        let markerURL = markerDirectory.appendingPathComponent(
            "dev-\(tagSlug)-last-socket-path",
            isDirectory: false
        )
        try "\(markerSocketPath)\n".write(to: markerURL, atomically: true, encoding: .utf8)

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TAG"] = tagSlug
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertNotEqual(result.status, 0, result.diagnostics)
        XCTAssertTrue(result.stderr.contains(taggedSocketPath), result.diagnostics)
        XCTAssertTrue(result.stderr.contains(stableSocketURL.path), result.diagnostics)
        XCTAssertTrue(result.stderr.contains(markerSocketPath), result.diagnostics)
        #expect(
            result.stderr.split(separator: "\n", omittingEmptySubsequences: true).count >= 4,
            Comment(rawValue: result.diagnostics)
        )
    }

    @Test func testLaunchCapableCommandsReachTheirDispatchPathWithoutLiveImplicitSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-launch-dispatch-\(UUID().uuidString.lowercased())"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeStableSocketMarker(home: home)

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CFFIXED_USER_HOME"] = home.path

        let cases: [(arguments: [String], expectedError: String)] = [
            (["settings", "invalid-target"], "Unknown settings subcommand 'invalid-target'"),
            (["shortcuts", "--invalid"], "shortcuts: unknown flag '--invalid'"),
            (["open"], "open requires at least one path or URL"),
            (["diff", "one.patch", "two.patch"], "diff accepts at most one patch file"),
            (["restore", "codex", UUID().uuidString.lowercased()], "restore: cmux is still opening."),
            (["restore-session", "--invalid"], "restore-session: unknown flag '--invalid'"),
            (["feedback", "--invalid"], "feedback: unknown flag '--invalid'"),
        ]

        for testCase in cases {
            let result = runProcess(
                executablePath: fakeCLIPath,
                arguments: testCase.arguments,
                environment: environment
            )

            #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
            #expect(result.status != 0, Comment(rawValue: result.diagnostics))
            #expect(
                result.stderr.contains(testCase.expectedError),
                Comment(rawValue: result.diagnostics)
            )
            #expect(
                !result.stderr.contains("No live cmux socket found"),
                Comment(rawValue: result.diagnostics)
            )
        }
    }

    @Test func testImplicitDiscoveryDoesNotConsiderUnmarkedTaggedSockets() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let unrelatedSocketPath = "/tmp/cmux-debug-unrelated-\(UUID().uuidString.lowercased()).sock"
        let responder = try UnixSocketResponder(path: unrelatedSocketPath, response: "PONG UNRELATED")
        defer { responder.stop() }

        let resolver = CLISocketPathResolver(
            environment: [:],
            bundleIdentifier: SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier,
            currentUserID: getuid(),
            socketAcceptsConnections: { $0 == unrelatedSocketPath },
            stateDirectory: CmuxStateDirectory.url(homeDirectory: home)
        )
        let resolution = resolver.resolve(
            requestedPath: "/tmp/cmux-debug.sock",
            source: .implicitDefault
        )

        #expect(!resolution.candidatePaths.contains(unrelatedSocketPath))
        #expect(resolution.selectedPath != unrelatedSocketPath)
        #expect(responder.receivedRequests.isEmpty)
    }

    @Test func testExplicitStableSocketEnvironmentIsNeverReroutedByTaggedCLI() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-explicit-stable-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let stableSocketURL = try stableSocketURL(home: home)
        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "PONG STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "PONG TAGGED")
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
        environment["CMUX_TAG"] = tagSlug
        environment["CMUX_SOCKET_PATH"] = stableSocketURL.path
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "PONG STABLE",
            result.diagnostics
        )
        XCTAssertEqual(stableResponder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertEqual(taggedResponder.receivedRequests, [], result.diagnostics)
        XCTAssertFalse(result.stderr.contains("rerout"), result.diagnostics)
    }

    @Test func testBundledCLIInTaggedDebugAppPreservesExplicitStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-case-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)
        let stableSocketPath = stableSocketURL.path
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
        // An environment override is an explicit pin, even when it names the
        // stable default that implicit discovery would otherwise consider.
        environment["CMUX_SOCKET_PATH"] = stableSocketPath
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK STABLE",
            result.diagnostics
        )
        XCTAssertEqual(stableResponder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertEqual(taggedResponder.receivedRequests, [], result.diagnostics)
    }

    @Test func testBundledCLIInTaggedDebugAppPreservesExplicitStableEnvSocketWhenTaggedSocketIsMissing() throws {
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
        // The tagged socket is absent, but an explicit stable environment path
        // remains pinned and is still used directly.
        environment["CMUX_SOCKET_PATH"] = stableSocketURL.path
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK STABLE", result.diagnostics)
        XCTAssertFalse(result.stderr.contains("rerout"), result.diagnostics)
        XCTAssertEqual(stableResponder.receivedRequests, ["ping"], result.diagnostics)
    }

    @Test func testBundledCLIInTaggedDebugAppPreservesExplicitUserScopedStableEnvSocket() throws {
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
        let aliases = [stableSocketPath]

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
                // A user-scoped stable path supplied in the environment is an
                // explicit pin and remains the target.
                environment["CMUX_SOCKET_PATH"] = alias
                environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

                let result = runProcess(
                    executablePath: fakeCLIPath,
                    arguments: ["ping"],
                    environment: environment
                )

                XCTAssertFalse(result.timedOut, result.diagnostics)
                XCTAssertEqual(result.status, 0, result.diagnostics)
                XCTAssertEqual(
                    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    "OK STABLE",
                    result.diagnostics
                )
                XCTAssertEqual(stableResponder.receivedRequests, ["ping"], "\(alias)\n\(result.diagnostics)")
                XCTAssertEqual(taggedResponder.receivedRequests, [], "\(alias)\n\(result.diagnostics)")
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
        try writeStableSocketMarker(home: fixedHomeURL)

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
        // An environment path is explicit even when it names a known stable
        // alias; discovery must not reinterpret it.
        environment["CMUX_SOCKET_PATH"] = userScopedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK USER",
            result.diagnostics
        )
        XCTAssertEqual(defaultResponder.receivedRequests, [], result.diagnostics)
        XCTAssertEqual(
            userScopedResponder.receivedRequests.count,
            1,
            "\(userScopedResponder.receivedRequests.joined(separator: "\n"))\n\(result.diagnostics)"
        )
        XCTAssertTrue(
            userScopedResponder.receivedRequests.contains { $0.contains("ping") },
            "\(userScopedResponder.receivedRequests.joined(separator: "\n"))\n\(result.diagnostics)"
        )
    }

    @Test func testBundledStableCLIRejectsDeadExplicitUserScopedStableEnvSocket() throws {
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
        try writeStableSocketMarker(home: fixedHomeURL)

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
        // Explicit environment paths stay pinned. A dead path must fail rather
        // than silently selecting the default responder.
        environment["CMUX_SOCKET_PATH"] = userScopedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertNotEqual(result.status, 0, result.diagnostics)
        XCTAssertTrue(result.stderr.contains(userScopedStableSocketPath), result.diagnostics)
        XCTAssertEqual(defaultResponder.receivedRequests, [], result.diagnostics)
    }

    /// An explicit environment path remains pinned even when it is a symlink. The
    /// resolver must not reinterpret that path as permission to choose another
    /// instance merely because the link target has a different spelling.
    @Test func testBundledStableCLIPreservesSymlinkedExplicitEnvSocket() throws {
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
        let symlinkedStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
            .path
        let symlinkTargetSocketPath = "/tmp/cmux-symlink-target-\(UUID().uuidString).sock"
        try writeStableSocketMarker(home: fixedHomeURL)

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
        XCTAssertEqual(symlink(symlinkTargetSocketPath, symlinkedStableSocketPath), 0)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        // The symlink is an explicit environment path, not an implicit alias.
        environment["CMUX_SOCKET_PATH"] = symlinkedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK TARGET",
            result.diagnostics
        )
        XCTAssertEqual(defaultResponder.receivedRequests, [], result.diagnostics)
        XCTAssertEqual(targetResponder.receivedRequests, ["ping"], result.diagnostics)
    }

    @Test func testBundledCLIInTaggedDebugAppPreservesExplicitCustomEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-legacy-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let explicitSocketPath = "/tmp/cmux-explicit-legacy-\(UUID().uuidString.lowercased()).sock"
        let stableResponder = try UnixSocketResponder(path: explicitSocketPath, response: "OK STABLE")
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
        environment["CMUX_SOCKET_PATH"] = explicitSocketPath
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK STABLE",
            result.diagnostics
        )
        XCTAssertEqual(stableResponder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertEqual(taggedResponder.receivedRequests, [], result.diagnostics)
    }

    @Test func testBundledCLISkipsIdentifierlessNestedAppWhenResolvingTaggedSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-nested-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)

        // The CLI only accepts OK / OK … / PONG / ERROR: … / JSON as a complete single-line
        // reply. A bareword sends it into the multiline drain pass, where reconfiguring the
        // receive timeout on an already-closed socket fails with EINVAL and the CLI reports
        // "Invalid argument" instead of the reply it already has.
        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "OK STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "OK TAGGED")
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
        // No CMUX_SOCKET_PATH again: resolution from the bundle layout is the subject. The
        // temp home and the unique tag slug keep that resolution inside the test.
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK TAGGED",
            result.diagnostics
        )
        // The point of this test: the tagged socket was chosen and the stable one was not. These
        // hold whatever framing the reply uses, so a future reply change cannot make it vacuous.
        XCTAssertEqual(taggedResponder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertEqual(stableResponder.receivedRequests, [], result.diagnostics)
    }

    @Test func testTaggedCLIThemesListWorksWithoutLiveSocket() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-list-no-socket-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Offline Theme", background: "#101010", to: themesURL)

        let tagSlug = "themes-no-socket-\(UUID().uuidString.lowercased())"
        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["themes", "list"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertTrue(result.stdout.contains("Offline Theme"), result.diagnostics)
        XCTAssertFalse(result.stderr.contains("No live cmux socket found"), result.diagnostics)
    }

    @Test func testThemesSetReloadsRunningAppAfterEveryThemeWrite() async throws {
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
        // The reload notification travels over DistributedNotificationCenter, which is
        // machine-wide, and the observer below filters only on the bundle identifier. With
        // a fixed identifier a second run of this test on the same machine fulfills this
        // run's expectation and appends to its list, so the identifier carries a per-run
        // suffix. The CLI takes the identifier from CMUX_BUNDLE_ID here because this
        // socket file name has no channel prefix to derive one from.
        let bundleIdentifier = "com.cmuxterm.app.debug.issue-4355-test."
            + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?)] = []

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
        try await confirmation(
            "cmux themes set posts final reload notifications",
            expectedCount: 3
        ) { reloadConfirmed in
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.cmuxterm.themes.reload-config"),
                object: nil,
                queue: notificationQueue
            ) { notification in
                let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
                guard observedBundleIdentifier == bundleIdentifier else { return }
                let observedPhase = notification.userInfo?["phase"] as? String
                notificationLock.withLock {
                    observedReloads.append((bundleIdentifier: observedBundleIdentifier, phase: observedPhase))
                }
                reloadConfirmed()
            }
            defer { DistributedNotificationCenter.default().removeObserver(observer) }

            for themeName in ["Theme A", "Theme B", "Theme C"] {
                let result = await runProcessOffHostThread(
                    executablePath: cliPath,
                    arguments: ["themes", "set", themeName],
                    environment: environment
                )

                XCTAssertFalse(result.timedOut, result.diagnostics)
                XCTAssertEqual(result.status, 0, result.diagnostics)
                observedThemeValues.append(try managedThemeValue(in: configURL))
            }
        }

        XCTAssertEqual(observedThemeValues, [
            "light:Theme A,dark:Theme A",
            "light:Theme B,dark:Theme B",
            "light:Theme C,dark:Theme C",
        ])
        let reloads = notificationLock.withLock { observedReloads }
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

        // The reload target is derived from the socket file name, not from CMUX_BUNDLE_ID:
        // `cmux-debug-<slug>.sock` becomes `com.cmuxterm.app.debug.<slug>`, where every run of
        // non-alphanumerics in the slug collapses to a dot. A raw UUID here would put its dashes
        // into the identifier as dots, so keep the unique part hex-only and the expected
        // identifier stays a plain template rather than a call into the CLI's own helper.
        let uniqueSuffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let socketPath = "/tmp/cmux-debug-active-theme-\(uniqueSuffix).sock"
        let staleBundleIdentifier = "com.cmuxterm.app.debug.stale.theme"
        let targetBundleIdentifier = "com.cmuxterm.app.debug.active.theme.\(uniqueSuffix)"
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
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        wait(for: [reloadExpectation], timeout: 5)

        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, [targetBundleIdentifier])
        XCTAssertEqual(reloads.map { $0.phase }, ["final"])
        XCTAssertEqual(reloads.map { $0.socketPath }, [socketPath])
        // The stale identifier must not show up anywhere the CLI writes, which is why this
        // one reads both streams: the JSON payload is on stdout, and a leak through an
        // error message would land on stderr.
        XCTAssertFalse(result.combinedOutput.contains(staleBundleIdentifier), result.diagnostics)
        XCTAssertTrue(result.stdout.contains(targetBundleIdentifier), result.diagnostics)
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

        // The reload target comes from the socket file name before CMUX_BUNDLE_ID is even
        // consulted: `cmux-nightly-<slug>.sock` becomes `com.cmuxterm.app.nightly.<slug>`.
        // So scoping the identifier means scoping the socket name it is read from, and both
        // take the same hex-only suffix — a raw UUID's dashes would turn into dots in the
        // identifier. Scoping matters because the reload goes out machine-wide: on the
        // plain nightly socket name this test told a real nightly build to re-read its
        // config, and two runs at once shared one identifier.
        let uniqueSuffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let socketPath = "/tmp/cmux-nightly-\(uniqueSuffix).sock"
        let bundleIdentifier = "com.cmuxterm.app.nightly.\(uniqueSuffix)"
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

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "themes", "set", "Theme A"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)

        // Parsed from stdout alone. This is the check that used to break when a stray
        // diagnostic line from the runtime shared the pipe with the payload.
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
            result.diagnostics
        )
        let configPath = try XCTUnwrap(payload["config_path"] as? String, result.diagnostics)
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
        // `env -i` builds the CLI's environment from scratch, so the shell needs only a
        // PATH of its own to find `env` — and nothing the test host was launched with
        // reaches the CLI.
        let result = runShell(command, environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        wait(for: [reloadExpectation], timeout: 5)
        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, [bundleIdentifier])
        XCTAssertEqual(reloads.map { $0.phase }, ["final"])
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)
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
        let result = runShell(command, environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        // `script` hands the CLI a pty for both streams, so a cancel notice arrives on
        // stdout today. Reading both keeps this from going quiet if that changes — the
        // notice is a thrown error, and thrown errors print on stderr.
        XCTAssertFalse(
            result.combinedOutput.contains("Interactive theme picker exited"),
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)
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
            // A deliberate cap, not a hang guard: the responder answers after 0.4s and the
            // request asks for 1000ms, so this run has to finish well inside 3s. Raising it
            // to the suite default would let a CLI that ignored --timeout-ms still pass.
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
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
            // A deliberate cap, and the only upper bound that gives this test meaning: the
            // responder answers after 10.5s, so waiting the server's default window has to
            // land between there and 16s. Under the suite default a CLI that waited a full
            // minute would still pass, and "matches the server default window" would stop
            // being a claim about anything.
            timeout: 16
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
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
            currentDirectoryURL: workingDirectory
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)

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
            currentDirectoryURL: root
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)

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
            currentDirectoryURL: root
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "PONG",
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: openLogURL.path), result.diagnostics)
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
            currentDirectoryURL: root
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)

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
            currentDirectoryURL: workingDirectory
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK workspace:explicit",
            result.diagnostics
        )

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

    private func resumeBindingResponse(command: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": ["resume_binding": ["command": command]],
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func resumeBindingCommand(from output: String) throws -> String {
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        let binding = try #require(payload["resume_binding"] as? [String: Any])
        return try #require(binding["command"] as? String)
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

    private func createEmptyCodexStateDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw NSError(domain: "CodexRestoreFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        let schema = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, source TEXT, thread_source TEXT)"
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexRestoreFixture", code: 2)
        }
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
        result["caller"] = [
            "workspace_id": workspaceID ?? UUID().uuidString,
            "surface_id": surfaceID ?? UUID().uuidString,
        ]
        result["focused"] = [String: Any]()
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

    /// Creates a Unix-domain socket node without listening on it.
    ///
    /// Connecting to this state fails with `ECONNREFUSED`, which is the startup
    /// race `SocketClient` retries. An absent path fails with `ENOENT` and is
    /// deliberately not retried because it normally means cmux is not running.
    private func bindUnavailableUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let destination = UnsafeMutableRawPointer(tuplePointer)
                    .assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, capacity - 1)
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(
                    descriptor,
                    socketPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            let savedErrno = errno
            close(descriptor)
            unlink(path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedErrno))
        }
        return descriptor
    }

    /// Waits for a child-written marker using the directory's vnode events.
    ///
    /// The initial content check handles a write that wins the race with kqueue
    /// registration; subsequent writes wake the event wait without polling or
    /// sleeping the test thread.
    private func waitForFileContentsUsingKqueue(
        _ url: URL,
        containing expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let directoryURL = url.deletingLastPathComponent()
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }

        let directoryFD = open(directoryURL.path, O_EVTONLY)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }

        var event = kevent(
            ident: UInt(directoryFD),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND | NOTE_LINK),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else { return false }

        let deadline = Date.now.addingTimeInterval(max(timeout, 0))
        while true {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               contents.contains(expected) {
                return true
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var timeoutSpec = timespec(
                tv_sec: Int(remaining),
                tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000)
            )
            var triggeredEvent = kevent()
            let result = kevent(queue, nil, 0, &triggeredEvent, 1, &timeoutSpec)
            if result < 0, errno != EINTR {
                return false
            }
        }
    }

    /// Points the stable last-socket-path marker inside `home` at a path of the test's own.
    ///
    /// `CFFIXED_USER_HOME` moves the socket directory but not socket discovery: the CLI
    /// reads the first marker file it can open, and the second candidate is the
    /// machine-wide `/tmp/cmux-last-socket-path`, which on a developer's machine names the
    /// socket of the cmux they are running. Writing the per-home marker keeps the candidate
    /// list inside the test even when the test's own default socket is missing. The path
    /// written is deliberately one that does not exist, so it can never be connected to.
    private func writeStableSocketMarker(home: URL) throws {
        let directory = CmuxStateDirectory.url(homeDirectory: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markerURL = directory.appendingPathComponent(
            SocketPathMarkerFiles.stableMarkerFileName,
            isDirectory: false
        )
        try "/tmp/cmux-marker-\(UUID().uuidString.prefix(8)).sock\n"
            .write(to: markerURL, atomically: true, encoding: .utf8)
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

    /// Resolves an existing path through the kernel-backed filesystem view.
    ///
    /// Foundation's URL normalization spells the `/var` symlink differently across
    /// macOS releases. `realpath` lets a test compare identity without baking either
    /// `/var/folders/...` or `/private/var/folders/...` into its expected output.
    private func canonicalExistingPath(_ path: String) -> String? {
        guard let resolved = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Runs a shell command with its environment spelled out.
    ///
    /// The environment is a required parameter. A child that inherits the test host's
    /// environment also inherits whatever `CMUX_*` variables the host was launched with,
    /// and that is one of the ways a spawned CLI ends up talking to the cmux the
    /// developer is actually running.
    private func runShell(
        _ command: String,
        environment: [String: String],
        timeout: TimeInterval? = nil
    ) -> ProcessRunResult {
        runPOSIXProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: environment,
            currentDirectoryURL: nil,
            timeout: timeout
        )
    }

    func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval? = nil,
        afterLaunch: (() -> Void)? = nil
    ) -> ProcessRunResult {
        runPOSIXProcess(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            timeout: timeout,
            afterLaunch: afterLaunch
        )
    }

    /// Runs a CLI child away from the app host's main thread.
    ///
    /// A themes command posts a distributed notification back to the app-hosted
    /// test process before it exits. Blocking the host thread in `waitUntilExit`
    /// makes that parent/child handshake deadlock. The GCD hop is intentional even
    /// with `@concurrent`: the POSIX runner performs blocking waits that must not
    /// occupy Swift's cooperative executor.
    @concurrent
    private func runProcessOffHostThread(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async -> ProcessRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runProcess(
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment
                ))
            }
        }
    }

    /// Runs a child to completion in its own process group, capturing stdout and stderr separately.
    ///
    /// App-hosted tests cannot reliably use `Foundation.Process` as the lifecycle oracle:
    /// its exit notification can be delayed while another fixture child is alive, even after
    /// the CLI has exited successfully. `posix_spawn` plus one `waitpid` owner makes exit and
    /// timeout state authoritative. The child-led process group also lets a timeout terminate
    /// descendants instead of leaving one holding the capture pipes open.
    ///
    /// - Parameter timeout: This run's deadline. A test that asserts how long the CLI
    ///   waits passes its own; everything else takes ``CMUXCLITestHangGuard/seconds``.
    private func runPOSIXProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval? = nil,
        afterLaunch: (() -> Void)? = nil
    ) -> ProcessRunResult {
        let budget = timeout ?? CMUXCLITestHangGuard.seconds
        func launchFailure(_ detail: String) -> ProcessRunResult {
            // Sibling files share this runner and some legacy assertions still print only
            // stdout, so duplicate setup failures onto both streams.
            let message = "test runner could not spawn \(executablePath): \(detail)"
            return ProcessRunResult(status: -1, stdout: message, stderr: message, timedOut: false)
        }

        var stdoutFDs: [Int32] = [-1, -1]
        var stderrFDs: [Int32] = [-1, -1]
        defer {
            for descriptor in stdoutFDs + stderrFDs where descriptor >= 0 {
                close(descriptor)
            }
        }
        guard pipe(&stdoutFDs) == 0, pipe(&stderrFDs) == 0 else {
            return launchFailure(String(cString: strerror(errno)))
        }
        guard stdoutFDs.allSatisfy({ $0 > STDERR_FILENO }),
              stderrFDs.allSatisfy({ $0 > STDERR_FILENO }) else {
            return launchFailure("capture pipe collided with standard I/O")
        }

        var fileActions: posix_spawn_file_actions_t?
        var setupStatus = posix_spawn_file_actions_init(&fileActions)
        guard setupStatus == 0 else {
            return launchFailure(String(cString: strerror(setupStatus)))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        setupStatus = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, $0, O_RDONLY, 0)
        }
        if setupStatus == 0, let currentDirectoryURL {
            setupStatus = currentDirectoryURL.path.withCString {
                posix_spawn_file_actions_addchdir_np(&fileActions, $0)
            }
        }
        if setupStatus == 0 {
            setupStatus = posix_spawn_file_actions_adddup2(&fileActions, stdoutFDs[1], STDOUT_FILENO)
        }
        if setupStatus == 0 {
            setupStatus = posix_spawn_file_actions_adddup2(&fileActions, stderrFDs[1], STDERR_FILENO)
        }
        for descriptor in stdoutFDs + stderrFDs where setupStatus == 0 {
            setupStatus = posix_spawn_file_actions_addclose(&fileActions, descriptor)
        }
        guard setupStatus == 0 else {
            return launchFailure(String(cString: strerror(setupStatus)))
        }

        var attributes: posix_spawnattr_t?
        setupStatus = posix_spawnattr_init(&attributes)
        guard setupStatus == 0 else {
            return launchFailure(String(cString: strerror(setupStatus)))
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let spawnFlags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        setupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        if setupStatus == 0 {
            setupStatus = posix_spawnattr_setflags(&attributes, spawnFlags)
        }
        guard setupStatus == 0 else {
            return launchFailure(String(cString: strerror(setupStatus)))
        }

        let argumentStrings = [executablePath] + arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        guard (argumentStrings + environmentStrings).allSatisfy({ !$0.utf8.contains(0) }) else {
            return launchFailure("argument or environment contains NUL")
        }
        var argumentPointers = argumentStrings.map { strdup($0) }
        var environmentPointers = environmentStrings.map { strdup($0) }
        defer {
            for pointer in argumentPointers where pointer != nil { free(pointer) }
            for pointer in environmentPointers where pointer != nil { free(pointer) }
        }
        guard argumentPointers.allSatisfy({ $0 != nil }),
              environmentPointers.allSatisfy({ $0 != nil }) else {
            return launchFailure("could not allocate argv or environment")
        }
        argumentPointers.append(nil)
        environmentPointers.append(nil)

        var processIdentifier: pid_t = 0
        let spawnStatus = executablePath.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
                environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                    guard let argumentBase = argumentBuffer.baseAddress,
                          let environmentBase = environmentBuffer.baseAddress else {
                        return Int32(EINVAL)
                    }
                    return posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentBase,
                        environmentBase
                    )
                }
            }
        }
        guard spawnStatus == 0, processIdentifier > 1 else {
            return launchFailure(String(cString: strerror(spawnStatus == 0 ? ECHILD : spawnStatus)))
        }

        close(stdoutFDs[1]); stdoutFDs[1] = -1
        close(stderrFDs[1]); stderrFDs[1] = -1
        let stdoutDrain = PipeDrain(
            FileHandle(fileDescriptor: stdoutFDs[0], closeOnDealloc: true)
        )
        stdoutFDs[0] = -1
        let stderrDrain = PipeDrain(
            FileHandle(fileDescriptor: stderrFDs[0], closeOnDealloc: true)
        )
        stderrFDs[0] = -1
        let waiter = POSIXProcessWaiter(processIdentifier: processIdentifier)
        afterLaunch?()

        var timedOut = false
        if !waiter.wait(timeout: budget) {
            timedOut = true
            _ = kill(-processIdentifier, SIGTERM)
            if !waiter.wait(timeout: 1) {
                _ = kill(-processIdentifier, SIGKILL)
                _ = waiter.wait(timeout: 5)
            }
        }

        // The child is gone by now, so its ends of both pipes are closed and each reader
        // sees EOF. The ceiling covers a grandchild that inherited a write end and
        // outlived its parent: report what was read rather than block the suite on it.
        let stdoutText = stdoutDrain.text(waitingUpTo: 5)
        let stderrText = stderrDrain.text(waitingUpTo: 5)

        guard let outcome = waiter.outcome else {
            let message = "test runner could not reap process group after SIGKILL"
            let diagnostics = stderrText.isEmpty ? message : "\(stderrText)\n\(message)"
            return ProcessRunResult(
                status: -1,
                stdout: stdoutText,
                stderr: diagnostics,
                timedOut: true
            )
        }
        let finalStderr: String
        if let waitError = outcome.waitError {
            let message = "test runner waitpid failed: \(String(cString: strerror(waitError)))"
            finalStderr = stderrText.isEmpty ? message : "\(stderrText)\n\(message)"
        } else {
            finalStderr = stderrText
        }

        return ProcessRunResult(
            status: outcome.status,
            stdout: stdoutText,
            stderr: finalStderr,
            timedOut: timedOut,
            terminationReason: outcome.reason
        )
    }

    private struct POSIXProcessOutcome {
        let status: Int32
        let reason: Process.TerminationReason
        let waitError: Int32?
    }

    /// Owns the only `waitpid` call for a spawned child and publishes one immutable outcome.
    private final class POSIXProcessWaiter: @unchecked Sendable {
        private let processIdentifier: pid_t
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var storedOutcome: POSIXProcessOutcome?

        init(processIdentifier: pid_t) {
            self.processIdentifier = processIdentifier
            let thread = Thread { [self] in reap() }
            thread.name = "cmux-cli-test-process-reaper"
            thread.stackSize = 1 << 20
            thread.start()
        }

        var outcome: POSIXProcessOutcome? {
            lock.lock()
            defer { lock.unlock() }
            return storedOutcome
        }

        func wait(timeout: TimeInterval) -> Bool {
            if outcome != nil { return true }
            if finished.wait(timeout: .now() + timeout) == .success { return true }
            // Do not turn a completion racing the deadline into a timeout.
            return outcome != nil
        }

        private func reap() {
            var rawStatus: Int32 = 0
            var waitResult: pid_t
            repeat {
                waitResult = waitpid(processIdentifier, &rawStatus, 0)
            } while waitResult == -1 && errno == EINTR

            let result: POSIXProcessOutcome
            if waitResult == processIdentifier {
                let terminatingSignal = rawStatus & 0x7f
                if terminatingSignal == 0 {
                    result = POSIXProcessOutcome(
                        status: (rawStatus >> 8) & 0xff,
                        reason: .exit,
                        waitError: nil
                    )
                } else {
                    result = POSIXProcessOutcome(
                        status: terminatingSignal,
                        reason: .uncaughtSignal,
                        waitError: nil
                    )
                }
            } else {
                result = POSIXProcessOutcome(status: -1, reason: .exit, waitError: errno)
            }
            lock.lock()
            storedOutcome = result
            lock.unlock()
            finished.signal()
        }
    }

    /// Reads one pipe on a background queue so a child writing more than a pipe buffer
    /// never blocks while the test is waiting for it to exit.
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let finished = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                store(handle.readDataToEndOfFile())
            }
        }

        private func store(_ read: Data) {
            lock.lock()
            data = read
            lock.unlock()
            finished.signal()
        }

        func text(waitingUpTo timeout: TimeInterval) -> String {
            _ = finished.wait(timeout: .now() + timeout)
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private func writeHermesStateDatabase(
        homeDirectory: URL,
        sessionID: String,
        cwd: String,
        startedAt: Double
    ) throws {
        let hermesHome = homeDirectory.appendingPathComponent(".hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        let databaseURL = hermesHome.appendingPathComponent("state.db", isDirectory: false)
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(
                domain: "CMUXCLIErrorOutputRegressionTests.SQLite",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to open Hermes state database"]
            )
        }
        defer { sqlite3_close(database) }

        let schema = """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          model TEXT,
          started_at REAL NOT NULL,
          ended_at REAL,
          title TEXT,
          cwd TEXT
        );
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "CMUXCLIErrorOutputRegressionTests.SQLite",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create Hermes sessions table"]
            )
        }

        var statement: OpaquePointer?
        let sql = "INSERT INTO sessions (id, source, model, started_at, title, cwd) VALUES (?, 'tui', 'test-model', ?, 'Recovered', ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw NSError(
                domain: "CMUXCLIErrorOutputRegressionTests.SQLite",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to prepare Hermes session insert"]
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, startedAt) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, cwd, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(
                domain: "CMUXCLIErrorOutputRegressionTests.SQLite",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to insert Hermes session"]
            )
        }
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

    init(
        relayID: String,
        responses: [String],
        startListening: Bool = true
    ) throws {
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
        guard bindResult == 0 else {
            let error = Self.posixError("bind")
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
        if startListening {
            self.startListening()
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

    func startListening() {
        lock.lock()
        guard !stopped, listenerFD >= 0 else {
            lock.unlock()
            return
        }
        let fd = listenerFD
        let listenResult = listen(fd, 8)
        lock.unlock()
        guard listenResult == 0 else { return }
        queue.async { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
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
