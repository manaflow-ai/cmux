import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
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
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
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

    @Test func testSessionsListIgnoresUntrustedLaunchCaptureForStartupInput() throws {
        let hugeCodexHome = "/tmp/" + String(repeating: "codex-home-", count: 100)
        let session = try sessionsListDiagnosticSession(
            launcher: "claudeTeams",
            executablePath: "/usr/local/bin/cmux",
            arguments: ["/usr/local/bin/cmux", "claude-teams"],
            environment: ["CODEX_HOME": hugeCodexHome]
        )
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_startup_input_available"] as? Bool == true)
    }

    @Test func testSessionsListPreservesSameKindShellWrapperLaunchEnvironmentForStartupInput() throws {
        let hugeCodexHome = "/tmp/" + String(repeating: "codex-home-", count: 100)
        let session = try sessionsListDiagnosticSession(
            launcher: "codex",
            executablePath: "/bin/bash",
            arguments: ["/bin/bash", "--noprofile", "--norc"],
            environment: ["CODEX_HOME": hugeCodexHome]
        )
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_startup_input_available"] as? Bool == false)
    }

    @Test func testSessionsListCountsCodexWrapperRenderingForStartupInput() throws {
        let session = try sessionsListDiagnosticSession(
            launcher: "codex",
            executablePath: "codex",
            arguments: ["codex", "--model", String(repeating: "x", count: 810)]
        )
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_startup_input_available"] as? Bool == false)
    }

    @Test func testSessionsListDoesNotReportLiveMatchingPIDAsStaleRestoreBlocker() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-live-pid-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceId = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
        let surfaceId = "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8"
        let liveProcess = Process()
        liveProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        liveProcess.arguments = ["30"]
        try liveProcess.run()
        let hookTimestamp = Date().timeIntervalSince1970
        defer {
            liveProcess.terminate()
            liveProcess.waitUntilExit()
        }

        let sessionId = "019ef275-74e3-7777-9773-9dcb118ed5aa"
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": "/tmp/cmux/debug",
                    "pid": Int(liveProcess.processIdentifier),
                    "startedAt": hookTimestamp,
                    "updatedAt": hookTimestamp,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/bin/sleep",
                        "arguments": ["/bin/sleep"],
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
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["stored_pid_exists"] as? Bool == true)
        #expect(session["stale_pid_blocks_restore_in_0_64_17"] as? Bool == false)
    }

    func sessionsListDiagnosticSession(
        agent: String = "codex", launcher: String, executablePath: String, arguments: [String],
        environment: [String: String] = [:], workingDirectory: String = "/tmp/cmux/debug", pid: Int? = nil,
        transcriptPath: String? = nil
    ) throws -> [String: Any] {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-codex-diag-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "019ef275-74e3-7777-9773-9dcb118ed5aa"
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": "33B0D372-292E-42BF-97B6-E37CCA79AB84",
            "surfaceId": "A2AECAA9-EE1C-4999-B7A9-EE4BB4CDA5D8",
            "cwd": workingDirectory,
            "startedAt": 1_781_996_800.0,
            "updatedAt": 1_781_996_867.0,
            "launchCommand": [
                "launcher": launcher,
                "executablePath": executablePath,
                "arguments": arguments,
                "workingDirectory": workingDirectory,
                "environment": environment,
                "source": "environment",
            ],
        ]
        if let pid { record["pid"] = pid }
        if let transcriptPath { record["transcriptPath"] = transcriptPath }
        let store: [String: Any] = [
            "version": 1,
            "sessions": [sessionId: record],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("\(agent)-hook-sessions.json"), options: .atomic)
        var processEnvironment = ProcessInfo.processInfo.environment
        for key in Array(processEnvironment.keys) where key.hasPrefix("CMUX_") { processEnvironment.removeValue(forKey: key) }
        processEnvironment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        processEnvironment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        let result = runProcess(executablePath: cliPath, arguments: ["sessions", "list", "--agent", agent, "--session", sessionId, "--json"], environment: processEnvironment, timeout: 5)
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        return try #require(sessions.first)
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

    @Test func testSessionsListDoesNotExecuteCapturedOpenCodeProbeCommand() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-opencode-probe-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let openCodeShim = binDir.appendingPathComponent("opencode", isDirectory: false)
        let markerFile = root.appendingPathComponent("probe-executed", isDirectory: false)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch \"\(markerFile.path)\"\nprintf 'opencode 1.14.50\\n'\n"
            .write(to: openCodeShim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openCodeShim.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "ses_opencode_local_version_probe_rejected"
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
                            "PATH": binDir.path,
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
        #expect(!FileManager.default.fileExists(atPath: markerFile.path))
    }
}
