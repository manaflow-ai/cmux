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

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["workspace_id"] as? String == workspaceId)
        #expect(session["surface_id"] as? String == surfaceId)
        #expect(session["active_for_workspace"] as? Bool == true)
        #expect(session["active_for_surface"] as? Bool == true)
        #expect(session["codex_indexed"] as? Bool == false)
        #expect(session["codex_transcript_found"] as? Bool == false)
        #expect(session["session_home"] as? String == codexHome.path)
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

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_unavailable_reason"] as? String == "available")
        #expect(session["fork_startup_input_available"] as? Bool == true)
        #expect(session["stored_pid_exists"] as? Bool == false)
        #expect(session["stale_pid_blocks_restore_in_0_64_17"] as? Bool == true)
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

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_unavailable_reason"] as? String == "available")
        #expect(session["fork_startup_input_available"] as? Bool == false)
    }

    @Test func testSessionsListForkStartupInputCountsSelectedEnvironment() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-fork-env-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019ef8fe-3dd6-7111-a356-56d5389db910"
        let workspaceId = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
        let surfaceId = "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8"
        let oversizedCodexHome = root.appendingPathComponent(String(repeating: "codex-home-", count: 100)).path
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
                        "executablePath": "codex",
                        "arguments": ["codex"],
                        "workingDirectory": "/tmp/cmux/debug",
                        "environment": [
                            "CODEX_HOME": oversizedCodexHome,
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

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_unavailable_reason"] as? String == "available")
        #expect(session["fork_startup_input_available"] as? Bool == false)
    }

    @Test func testSessionsListDoesNotReportLocalOpenCodeForkSupportedWithoutVersionProbe() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-opencode-fork-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        let openCodeConfigDir = root.appendingPathComponent("opencode-config", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openCodeConfigDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "ses_opencode_local_version_gate"
        let workspaceId = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
        let surfaceId = "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8"
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": repoDir.path,
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "opencode",
                        "arguments": ["opencode"],
                        "workingDirectory": repoDir.path,
                        "environment": [
                            "OPENCODE_CONFIG_DIR": openCodeConfigDir.path,
                        ],
                        "source": "environment",
                    ],
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("opencode-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "opencode", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["fork_command_available"] as? Bool == true)
        #expect(session["fork_supported"] as? Bool == false)
        #expect(session["fork_unavailable_reason"] as? String == "opencode_version_unverified")
        #expect(session["fork_startup_input_available"] as? Bool == true)
    }

    @Test func testSessionsListTreatsTranscriptBackedClaudeRecordAsRestorable() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-claude-transcript-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        let transcriptURL = root.appendingPathComponent("claude-session.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "claude-transcript-backed-session"
        let workspaceId = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
        let surfaceId = "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8"
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": repoDir.path,
                    "transcriptPath": transcriptURL.path,
                    "isRestorable": false,
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0,
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "/usr/local/bin/claude",
                        "arguments": ["/usr/local/bin/claude"],
                        "workingDirectory": repoDir.path,
                        "source": "environment",
                    ],
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "claude", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["hook_record_restorable"] as? Bool == true)
        #expect(session["fork_command_available"] as? Bool == true)
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_unavailable_reason"] as? String == "available")
    }

    @Test func testSessionsListFindsClaudeTranscriptWhenRecordPathMissing() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-claude-lookup-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let repoDir = root.appendingPathComponent("repo.with.dot", isDirectory: true)
        let claudeConfigDir = root.appendingPathComponent("claude-config", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "claude-config-lookup-session"
        let projectDirName = repoDir.path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let projectDir = claudeConfigDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "{}\n".write(
            to: projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let workspaceId = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
        let surfaceId = "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8"
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": repoDir.path,
                    "isRestorable": false,
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0,
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "/usr/local/bin/claude",
                        "arguments": ["/usr/local/bin/claude"],
                        "workingDirectory": repoDir.path,
                        "environment": [
                            "CLAUDE_CONFIG_DIR": claudeConfigDir.path,
                        ],
                        "source": "environment",
                    ],
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "claude", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["hook_record_restorable"] as? Bool == true)
        #expect(session["fork_command_available"] as? Bool == true)
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_unavailable_reason"] as? String == "available")
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

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["stored_pid_exists"] is NSNull)
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
                    "pid": 987_654_321,
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

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["fork_supported"] as? Bool == false)
        #expect(session["fork_unavailable_reason"] as? String == "agent_has_no_fork_command")
        #expect(session["fork_startup_input_available"] as? Bool == false)
        #expect(session["stale_pid_blocks_restore_in_0_64_17"] as? Bool == true)
    }
}
