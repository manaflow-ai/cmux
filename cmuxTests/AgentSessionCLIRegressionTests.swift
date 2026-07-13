import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func providerStopAdapterDistinguishesInterruptionsFromCompletion() throws {
        let adapter = AgentStopStateAdapter()
        let kimiInterrupt = ClaudeHookParsedInput(
            rawObject: ["hook_event_name": "Interrupt"],
            object: ["hook_event_name": "Interrupt"],
            rawFallback: nil,
            sessionId: "kimi-session",
            turnId: "kimi-turn",
            cwd: nil,
            transcriptPath: nil
        )
        #expect(adapter.isInterrupted(provider: "kimi", input: kimiInterrupt))

        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-interrupted-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        try #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"codex-turn"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let codexInterrupt = ClaudeHookParsedInput(
            rawObject: nil,
            object: nil,
            rawFallback: nil,
            sessionId: "codex-session",
            turnId: "codex-turn",
            cwd: nil,
            transcriptPath: transcript.path
        )
        #expect(adapter.isInterrupted(provider: "codex", input: codexInterrupt))

        let normalStop = ClaudeHookParsedInput(
            rawObject: ["hook_event_name": "Stop"],
            object: ["hook_event_name": "Stop"],
            rawFallback: nil,
            sessionId: "session",
            turnId: "turn",
            cwd: nil,
            transcriptPath: nil
        )
        #expect(!adapter.isInterrupted(provider: "claude", input: normalStop))
    }

    @Test func agentsTreeReportsWorkloadsSpawnAndForkRelationshipsWithoutGrantingChildrenRestoreAuthority() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "root-session": [
                    "sessionId": "root-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "runId": "root-run",
                    "restoreAuthority": true,
                    "foregroundState": "completed",
                    "workloads": [[
                        "id": "monitor-1",
                        "kind": "monitor",
                        "phase": "watching",
                        "keepsSessionBusy": true,
                        "startedAt": 105.0,
                        "updatedAt": 130.0,
                    ]],
                    "startedAt": 100.0,
                    "updatedAt": 130.0,
                ],
                "child-session": [
                    "sessionId": "child-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "runId": "child-run",
                    "parentRunId": "root-run",
                    "parentSessionId": "root-session",
                    "relationship": "spawned",
                    "restoreAuthority": false,
                    "startedAt": 110.0,
                    "updatedAt": 120.0,
                ],
                "fork-session": [
                    "sessionId": "fork-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-b",
                    "runId": "fork-run",
                    "parentSessionId": "root-session",
                    "relationship": "forked",
                    "restoreAuthority": true,
                    "startedAt": 115.0,
                    "updatedAt": 125.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let output = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(output["schema_version"] as? Int == 1)
        let nodes = try #require(output["nodes"] as? [[String: Any]])
        let edges = try #require(output["edges"] as? [[String: Any]])
        #expect(nodes.count == 3)
        let rootNode = try #require(nodes.first { $0["run_id"] as? String == "root-run" })
        #expect(rootNode["restore_authority"] as? Bool == true)
        #expect(rootNode["effective_state"] as? String == "monitoring")
        let activity = try #require(rootNode["activity"] as? [String: Any])
        #expect(activity["busy"] as? Bool == true)
        #expect(activity["modes"] as? [String] == ["monitoring"])
        let counts = try #require(activity["counts"] as? [String: Any])
        #expect(counts["monitor"] as? Int == 1)
        let subtree = try #require(rootNode["subtree_activity"] as? [String: Any])
        #expect(subtree["total_descendants"] as? Int == 1)
        #expect(subtree["busy_descendants"] as? Int == 0)
        #expect(subtree["restore_owners"] as? Int == 0)
        #expect(nodes.first { $0["run_id"] as? String == "child-run" }?["restore_authority"] as? Bool == false)
        #expect(edges.contains {
            $0["from_run_id"] as? String == "root-run"
                && $0["to_run_id"] as? String == "child-run"
                && $0["relationship"] as? String == "spawned"
        })
        #expect(edges.contains {
            $0["from_session_id"] as? String == "root-session"
                && $0["to_run_id"] as? String == "fork-run"
                && $0["relationship"] as? String == "forked"
        })

        let monitoring = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--all", "--activity", "busy", "--work-kind", "monitor", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!monitoring.timedOut, Comment(rawValue: monitoring.stderr))
        #expect(monitoring.status == 0, Comment(rawValue: monitoring.stderr))
        let monitoringOutput = try #require(
            JSONSerialization.jsonObject(with: Data(monitoring.stdout.utf8)) as? [String: Any]
        )
        #expect(monitoringOutput["total_matches"] as? Int == 1)
        let monitoringSessions = try #require(monitoringOutput["sessions"] as? [[String: Any]])
        #expect(monitoringSessions.first?["session_id"] as? String == "root-session")
    }

    @Test func rootExitCancelsEveryOwnedWorkloadAndRetainsHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-root-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "root-session": [
                    "sessionId": "root-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "runId": "root-run",
                    "activeRunId": "root-run",
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 110.0,
                    "runs": [[
                        "runId": "root-run",
                        "restoreAuthority": true,
                        "startedAt": 100.0,
                        "updatedAt": 110.0,
                    ]],
                    "workloads": [
                        [
                            "id": "terminal-1",
                            "kind": "background_terminal",
                            "phase": "running",
                            "keepsSessionBusy": true,
                            "startedAt": 101.0,
                            "updatedAt": 110.0,
                        ],
                        [
                            "id": "monitor-1",
                            "kind": "monitor",
                            "phase": "watching",
                            "keepsSessionBusy": true,
                            "startedAt": 102.0,
                            "updatedAt": 110.0,
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)

        let sessionStore = ClaudeHookSessionStore(
            processEnv: ["CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path],
            fileManager: .default,
            agentName: "claude"
        )
        _ = try sessionStore.consume(sessionId: "root-session", workspaceId: nil, surfaceId: nil)

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions["root-session"] as? [String: Any])
        #expect(record["completedAt"] as? Double != nil)
        #expect(record["restoreAuthority"] as? Bool == false)
        #expect(record["activeRunId"] == nil)
        let runs = try #require(record["runs"] as? [[String: Any]])
        #expect(runs.first?["restoreAuthority"] as? Bool == false)
        #expect(runs.first?["endedAt"] as? Double != nil)
        let workloads = try #require(record["workloads"] as? [[String: Any]])
        #expect(workloads.count == 2)
        #expect(workloads.allSatisfy { $0["phase"] as? String == "cancelled" })
        #expect(workloads.allSatisfy { $0["endReason"] as? String == "root_exited" })
        #expect(workloads.allSatisfy { $0["endedAt"] as? Double != nil })
    }

    @Test func agentsTreeScansTenThousandSavedSessionsWithinTheCLITimeout() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var sessions: [String: Any] = [:]
        sessions.reserveCapacity(10_000)
        for index in 0..<10_000 {
            let id = "session-\(index)"
            sessions[id] = [
                "sessionId": id,
                "workspaceId": "workspace-\(index % 100)",
                "surfaceId": "surface-\(index)",
                "runId": "run-\(index)",
                "foregroundState": "completed",
                "restoreAuthority": true,
                "startedAt": Double(index),
                "updatedAt": Double(index),
            ]
        }
        try JSONSerialization.data(
            withJSONObject: ["version": 2, "sessions": sessions],
            options: []
        ).write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--state", "monitoring", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, "The graph reader must stay bounded at the 10,000-record retention limit")
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let output = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect((output["nodes"] as? [Any])?.isEmpty == true)
    }

}
