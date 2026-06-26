import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testSessionsListReportsCodexIdsMissingFromCodexStore() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019ee74a-3c84-7de3-84f1-ece32f4ecfbb"
        let workspaceId = "workspace-debug"
        let surfaceId = "surface-debug"
        let store: [String: Any] = [
            "version": 1,
            "activeSessionsByWorkspace": [
                workspaceId: [
                    "sessionId": sessionId,
                    "updatedAt": 1_781_996_867.0
                ]
            ],
            "activeSessionsBySurface": [
                surfaceId: [
                    "sessionId": sessionId,
                    "updatedAt": 1_781_996_867.0
                ]
            ],
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": "/tmp/cmux/debug",
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        let outputData = try XCTUnwrap(result.stdout.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        XCTAssertEqual(object["total_matches"] as? Int, 1)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session["session_id"] as? String, sessionId)
        XCTAssertEqual(session["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(session["surface_id"] as? String, surfaceId)
        XCTAssertEqual(session["active_for_workspace"] as? Bool, true)
        XCTAssertEqual(session["active_for_surface"] as? Bool, true)
        XCTAssertEqual(session["codex_indexed"] as? Bool, false)
        XCTAssertEqual(session["codex_transcript_found"] as? Bool, false)
        XCTAssertEqual(session["session_home"] as? String, codexHome.path)
    }

    @Test func testSessionsListReportsForkDiagnosticsAndAcceptsWorkspaceRefs() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-fork-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019edd1b-47af-7c32-a220-4c391a7f836b"
        let workspaceId = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
        let surfaceId = "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8"
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": "/tmp/cmux/debug",
                    "pid": 987_654_321,
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0,
                    "launchCommand": [
                        "launcher": "codex",
                        "arguments": [],
                        "workingDirectory": "/tmp/cmux/debug",
                        "environment": [
                            "CODEX_HOME": codexHome.path,
                        ],
                        "source": "environment",
                    ],
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "sessions", "list",
                "--agent", "codex",
                "--workspace", "workspace:1:\(workspaceId)",
                "--surface", "surface:9:\(surfaceId)",
                "--json",
            ],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        let outputData = try XCTUnwrap(result.stdout.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        XCTAssertEqual(object["total_matches"] as? Int, 1)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session["session_id"] as? String, sessionId)
        XCTAssertEqual(session["fork_supported"] as? Bool, true)
        XCTAssertEqual(session["fork_unavailable_reason"] as? String, "available")
        XCTAssertEqual(session["fork_startup_input_available"] as? Bool, true)
        XCTAssertEqual(session["stored_pid_alive"] as? Bool, false)
        XCTAssertEqual(session["stale_pid_blocks_restore_in_0_64_17"] as? Bool, true)
    }

    @Test func testSessionsListForkStartupInputAvailabilityCanDifferFromForkSupport() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-fork-startup-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019ef275-74e3-7777-9773-9dcb118ed5ab"
        let workspaceId = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
        let surfaceId = "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8"
        let longModelName = "model-" + String(repeating: "x", count: 950)
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": "/tmp/cmux/debug",
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--model", longModelName],
                        "workingDirectory": "/tmp/cmux/debug",
                        "environment": [
                            "CODEX_HOME": codexHome.path,
                        ],
                        "source": "environment",
                    ],
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        let outputData = try XCTUnwrap(result.stdout.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        XCTAssertEqual(object["total_matches"] as? Int, 1)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session["session_id"] as? String, sessionId)
        XCTAssertEqual(session["fork_supported"] as? Bool, true)
        XCTAssertEqual(session["fork_unavailable_reason"] as? String, "available")
        XCTAssertEqual(session["fork_startup_input_available"] as? Bool, false)
    }

    @Test func testSessionsListIgnoresOutOfRangeStoredPID() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-pid-range-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019ef275-74e3-7777-9773-9dcb118ed5ac"
        let workspaceId = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
        let surfaceId = "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8"
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": "/tmp/cmux/debug",
                    "pid": Int64(Int32.max) + 1,
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": "/tmp/cmux/debug",
                        "environment": [
                            "CODEX_HOME": codexHome.path,
                        ],
                        "source": "environment",
                    ],
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        let outputData = try XCTUnwrap(result.stdout.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        XCTAssertEqual(object["total_matches"] as? Int, 1)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session["session_id"] as? String, sessionId)
        XCTAssertEqual(session["fork_supported"] as? Bool, true)
        XCTAssertTrue(session["stored_pid_alive"] is NSNull)
    }

    @Test func testSessionsListForkDiagnosticsUseForkCommandBuilder() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-fork-builder-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019ee74a-3c84-7de3-84f1-ece32f4ecfbb"
        let workspaceId = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
        let surfaceId = "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8"
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": "/tmp/cmux/debug",
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "exec", "make", "test"],
                        "workingDirectory": "/tmp/cmux/debug",
                        "environment": [
                            "CODEX_HOME": codexHome.path,
                        ],
                        "source": "environment",
                    ],
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        let outputData = try XCTUnwrap(result.stdout.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        XCTAssertEqual(object["total_matches"] as? Int, 1)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session["session_id"] as? String, sessionId)
        XCTAssertEqual(session["fork_supported"] as? Bool, false)
        XCTAssertEqual(session["fork_unavailable_reason"] as? String, "agent_has_no_fork_command")
        XCTAssertEqual(session["fork_startup_input_available"] as? Bool, false)
        XCTAssertEqual(session["stale_pid_blocks_restore_in_0_64_17"] as? Bool, false)
    }
}
