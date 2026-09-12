import Darwin
import Foundation
import Testing

// Restore startup fixtures share the suite's serialized subprocess/socket harness.
extension CMUXCLIErrorOutputRegressionTests {
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
        ], workspaceID: workspaceID, surfaceID: surfaceID)
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
        if [ "$1" = "--profile" ]; then shift 2; fi
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
        // Darwin leaves a connect to a bound, non-listening TCP socket pending.
        // Bound only this fixture's initial attempt so it reaches the startup
        // waiter while retaining exclusive ownership of the ephemeral port.
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "1"

        var reachedStartupWait = false
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["restore", "pi", checkpointID],
            environment: environment,
            timeout: 5,
            afterLaunch: {
                reachedStartupWait = self.waitForFileContentsUsingKqueue(
                    URL(fileURLWithPath: debugLogPath),
                    containing: "socket.connect.wait.entered",
                    timeout: 3
                )
                guard reachedStartupWait else {
                    return
                }
                // The startup waiter has its own deadline; a real relay handshake
                // and restore request must succeed after the listener comes up.
                responder.startListening()
            }
        )

        let debugLog = (try? String(contentsOfFile: debugLogPath, encoding: .utf8)) ?? "<no CLI log>"
        #expect(reachedStartupWait, Comment(rawValue: debugLog))
        XCTAssertFalse(result.timedOut, result.diagnostics + "\n" + debugLog)
        XCTAssertEqual(result.status, 0, result.diagnostics + "\n" + debugLog)
        let requests = try responder.receivedRequests.map { request in
            let data = try #require(request.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "agent.resolve_delivery_target",
            "surface.resume.get",
        ])
    }
}
