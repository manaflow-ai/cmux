import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func codexTeamsThreadIdentityDoesNotLeakAcrossProviders() {
        let inheritedEnvironment = [
            "CMUX_CODEX_TEAMS_THREAD_ID": "codex-thread",
            "CMUX_CODEX_TEAMS_PARENT_THREAD_ID": "codex-parent",
        ]
        let resolver = AgentHookSessionLineageResolver()

        let claude = resolver.resolve(
            agentName: "claude",
            sessionId: "claude-session",
            pid: nil,
            environment: inheritedEnvironment
        )
        #expect(claude.runId == "session:claude:claude-session")
        #expect(claude.parentRunId == nil)

        let codex = resolver.resolve(
            agentName: "codex",
            sessionId: "codex-session",
            pid: nil,
            environment: inheritedEnvironment
        )
        #expect(codex.runId == "codex-thread")
        #expect(codex.parentRunId == "codex-parent")
    }

    @Test func olderProcessGenerationCannotReplaceActiveRun() {
        let currentRun = AgentSessionRunRecord(
            runId: "current-run", pid: 202, processStartedAt: 200,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, startedAt: 200, updatedAt: 210, endedAt: nil
        )
        let record = ClaudeHookSessionRecord(
            sessionId: "session", workspaceId: "workspace", surfaceId: "surface",
            startedAt: 100, updatedAt: 210, runs: [currentRun], activeRunId: currentRun.runId
        )
        let staleLineage = AgentHookSessionLineage(
            runId: "old-run", pid: 101, processStartedAt: 100,
            parentRunId: nil, parentSessionId: nil, relationship: nil, restoreAuthority: true
        )

        #expect(!AgentHookSessionActivationPolicy().canActivate(
            record: record, lineage: staleLineage, hasIncomingPID: true
        ))
    }

    @Test func rejectedCompletedGenerationIsReportedByStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rejected-upsert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let pid = Int(getpid())
        let environment = ["CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path]
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex", sessionId: "completed-session", pid: pid, environment: environment
        )
        let processStartedAt = try #require(lineage.processStartedAt)
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": ["completed-session": [
                "sessionId": "completed-session", "workspaceId": "workspace", "surfaceId": "surface",
                "completedAt": 200.0, "sessionState": "ended", "startedAt": 100.0, "updatedAt": 200.0,
                "runs": [[
                    "runId": lineage.runId, "pid": pid, "processStartedAt": processStartedAt,
                    "restoreAuthority": false, "startedAt": 100.0, "updatedAt": 200.0, "endedAt": 200.0,
                ]],
            ]],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let store = ClaudeHookSessionStore(processEnv: environment, agentName: "codex")

        let accepted = try store.upsert(
            sessionId: "completed-session", workspaceId: "workspace", surfaceId: "surface",
            cwd: root.path, pid: pid
        )

        #expect(!accepted)
        let saved = try #require(store.lookup(sessionId: "completed-session"))
        #expect(saved.completedAt == 200)
        #expect(saved.sessionState == .ended)
        #expect(saved.activeRunId == nil)
    }

    @Test func queuedLifecycleCannotOverwriteNewerRecordGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-lifecycle-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "replacement-session": [
                    "sessionId": "replacement-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "activeRunId": "replacement-run",
                    "restoreAuthority": true,
                    "sessionState": "active",
                    "cmuxRuntime": ["id": "replacement-runtime"],
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                    "runs": [[
                        "runId": "replacement-run",
                        "restoreAuthority": true,
                        "cmuxRuntime": ["id": "replacement-runtime"],
                        "startedAt": 200.0,
                        "updatedAt": 200.0,
                    ]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        let writer = AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_RUNTIME_ID": "stale-runtime",
            ]
        )

        writer.setLifecycleSynchronously(
            kind: .codex,
            sessionId: "replacement-session",
            state: .restoring,
            now: 150
        )

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions["replacement-session"] as? [String: Any])
        #expect(record["sessionState"] as? String == "active")
        #expect(record["updatedAt"] as? TimeInterval == 200)
        let runtime = try #require(record["cmuxRuntime"] as? [String: Any])
        #expect(runtime["id"] as? String == "replacement-runtime")
    }

    @Test func agentsTreeDoesNotAttachCurrentWorkloadsToHistoricalRuns() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-historical-workloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "resumed-session": [
                    "sessionId": "resumed-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "activeRunId": "current-run",
                    "restoreAuthority": true,
                    "foregroundState": "working",
                    "attentionState": "none",
                    "sessionState": "active",
                    "startedAt": 100.0,
                    "updatedAt": 300.0,
                    "runs": [
                        [
                            "runId": "historical-run",
                            "restoreAuthority": false,
                            "startedAt": 100.0,
                            "updatedAt": 200.0,
                            "endedAt": 200.0,
                        ],
                        [
                            "runId": "current-run",
                            "restoreAuthority": true,
                            "startedAt": 200.0,
                            "updatedAt": 300.0,
                        ],
                    ],
                    "workloads": [[
                        "id": "live-monitor",
                        "kind": "monitor",
                        "phase": "watching",
                        "keepsSessionBusy": true,
                        "startedAt": 250.0,
                        "updatedAt": 300.0,
                    ]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let output = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let nodes = try #require(output["nodes"] as? [[String: Any]])
        let historical = try #require(nodes.first { $0["run_id"] as? String == "historical-run" })
        let current = try #require(nodes.first { $0["run_id"] as? String == "current-run" })
        let historicalActivity = try #require(historical["activity"] as? [String: Any])
        let currentActivity = try #require(current["activity"] as? [String: Any])
        #expect(historicalActivity["busy"] as? Bool == false)
        #expect((historical["workloads"] as? [[String: Any]])?.isEmpty == true)
        #expect(currentActivity["busy"] as? Bool == true)
        #expect((current["workloads"] as? [[String: Any]])?.count == 1)

        let filtered = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--work-kind", "monitor", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!filtered.timedOut, Comment(rawValue: filtered.stdout))
        #expect(filtered.status == 0, Comment(rawValue: filtered.stdout))
        let filteredOutput = try #require(
            JSONSerialization.jsonObject(with: Data(filtered.stdout.utf8)) as? [String: Any]
        )
        let filteredNodes = try #require(filteredOutput["nodes"] as? [[String: Any]])
        #expect(filteredNodes.compactMap { $0["run_id"] as? String } == ["current-run"])
    }

    @Test func verifiedForkRootRecoversOnlyFromProvisionalChildEvidence() throws {
        func storedRun(evidence: String, processStartedAt: TimeInterval) throws -> AgentSessionRunRecord {
            let data = try JSONSerialization.data(withJSONObject: [
                "runId": "fork-run",
                "pid": 101,
                "processStartedAt": processStartedAt,
                "parentRunId": "parent-run",
                "parentSessionId": "parent-session",
                "relationship": "spawned",
                "restoreAuthority": false,
                "authorityEvidence": evidence,
                "startedAt": 100.0,
                "updatedAt": 110.0,
            ])
            return try JSONDecoder().decode(AgentSessionRunRecord.self, from: data)
        }

        let verifiedFork = AgentHookSessionLineage(
            runId: "fork-run",
            pid: 202,
            processStartedAt: 200,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: .forked,
            restoreAuthority: true
        )
        let reconciler = AgentSessionRunReconciler(maximumRecords: 128)
        for processStartedAt in [100.0, 200.0] {
            let provisional = try storedRun(
                evidence: "provisional_ambiguous_child",
                processStartedAt: processStartedAt
            )
            let recovered = reconciler.reconciling(
                [provisional],
                activeRunId: provisional.runId,
                lineage: verifiedFork,
                now: 210
            )
            let recoveredRun = try #require(recovered.first)
            #expect(recoveredRun.relationship == .forked)
            #expect(recoveredRun.restoreAuthority)
            #expect(recoveredRun.parentRunId == "parent-run")
            #expect(recoveredRun.parentSessionId == "parent-session")
        }

        for evidence in ["managed_child", "explicit_spawned_child", "verified_ancestor_child"] {
            let durable = try storedRun(evidence: evidence, processStartedAt: 100)
            let runs = reconciler.reconciling(
                [durable],
                activeRunId: durable.runId,
                lineage: verifiedFork,
                now: 210
            )
            let run = try #require(runs.first)
            #expect(run.relationship == .spawned, Comment(rawValue: evidence))
            #expect(!run.restoreAuthority, Comment(rawValue: evidence))
        }
    }
}
