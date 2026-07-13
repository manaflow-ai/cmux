import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func inheritedForkMetadataCannotPromoteAManagedChild() {
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "child-session",
            pid: nil,
            environment: [
                "CMUX_AGENT_MANAGED_SUBAGENT": "1",
                "CMUX_AGENT_RELATIONSHIP": "forked",
                "CMUX_AGENT_PARENT_SESSION_ID": "root-session",
            ]
        )

        #expect(lineage.relationship == .spawned)
        #expect(lineage.restoreAuthority == false)
    }

    @Test func unresolvedProcessAncestryCannotGrantRestoreAuthority() {
        let authority = AgentHookSessionAuthorityPolicy().classify(
            managedChild: false,
            explicitRelationship: nil,
            processIdentityAvailable: true,
            hasAgentAncestor: false,
            ancestryProvenAbsent: false
        )

        #expect(authority.relationship == .spawned)
        #expect(authority.restoreAuthority == false)
    }

    @Test func lateHookFromCompletedProcessCannotReactivateSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-late-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let environment = ["CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path]
        let pid = Int(getpid())
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "completed-session",
            pid: pid,
            environment: environment
        )
        let processStartedAt = try #require(lineage.processStartedAt)
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "completed-session": [
                    "sessionId": "completed-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "pid": pid,
                    "runId": lineage.runId,
                    "restoreAuthority": false,
                    "sessionState": "ended",
                    "completedAt": now,
                    "startedAt": now - 10,
                    "updatedAt": now,
                    "runs": [[
                        "runId": lineage.runId,
                        "pid": pid,
                        "processStartedAt": processStartedAt,
                        "restoreAuthority": false,
                        "startedAt": now - 10,
                        "updatedAt": now,
                        "endedAt": now,
                    ]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)

        let sessionStore = ClaudeHookSessionStore(
            processEnv: environment,
            fileManager: .default,
            agentName: "codex"
        )
        try sessionStore.upsert(
            sessionId: "completed-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: nil,
            pid: pid,
            markActive: true
        )

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions["completed-session"] as? [String: Any])
        #expect(record["completedAt"] as? Double == now)
        #expect(record["sessionState"] as? String == "ended")
        #expect(record["restoreAuthority"] as? Bool == false)
        let activeBySurface = saved["activeSessionsBySurface"] as? [String: Any]
        #expect(activeBySurface?["surface-a"] == nil)
    }

    @Test func processStateRequiresMatchingLiveProcessGeneration() throws {
        let pid = Int(getpid())
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "live-session",
            pid: pid,
            environment: [:]
        )
        let processStartedAt = try #require(lineage.processStartedAt)
        let now = Date().timeIntervalSince1970
        let recordData = try JSONSerialization.data(withJSONObject: [
            "sessionId": "live-session",
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "startedAt": now - 10,
            "updatedAt": now,
        ])
        let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordData)
        let liveRun = AgentSessionRunRecord(
            runId: lineage.runId,
            pid: pid,
            processStartedAt: processStartedAt,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: now - 10,
            updatedAt: now,
            endedAt: nil
        )
        var staleRun = liveRun
        staleRun.processStartedAt = processStartedAt - 1

        #expect(AgentSessionStateProjection(record: record, run: liveRun).process == .alive)
        #expect(AgentSessionStateProjection(record: record, run: staleRun).process == .exited)
    }

    @Test func exitedProcessCannotRemainEffectivelyWorking() throws {
        let now = Date().timeIntervalSince1970
        let recordData = try JSONSerialization.data(withJSONObject: [
            "sessionId": "stale-working-session",
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "runtimeStatus": "running",
            "startedAt": now - 10,
            "updatedAt": now,
        ])
        let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordData)
        let staleRun = AgentSessionRunRecord(
            runId: "stale-working-run",
            pid: Int(getpid()),
            processStartedAt: 0,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: now - 10,
            updatedAt: now,
            endedAt: nil
        )

        let projection = AgentSessionStateProjection(record: record, run: staleRun)

        #expect(projection.process == .exited)
        #expect(projection.effective == .ended)
    }

    @Test func workloadHistoryAppliesHardCapWhenEveryRecordIsActive() {
        let incoming = (0..<300).map { index in
            AgentWorkloadRecord(
                id: "monitor-\(index)",
                kind: .monitor,
                phase: .watching,
                keepsSessionBusy: true,
                startedAt: Double(index),
                updatedAt: Double(index),
                endedAt: nil,
                endReason: nil
            )
        }

        let reconciled = AgentSessionWorkloadReconciler().replacingActiveWorkloads(
            [],
            with: incoming,
            now: 300
        )

        #expect(reconciled.count == 256)
        #expect(reconciled.allSatisfy { $0.phase.isActive })
        #expect(reconciled.map(\.id).contains("monitor-299"))
    }

    @Test func childRunCannotGainRestoreAuthorityWhenAncestorEvidenceDisappears() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-child-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let environment = ["CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path]
        let pid = Int(getpid())
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "child-session",
            pid: pid,
            environment: environment
        )
        let processStartedAt = try #require(lineage.processStartedAt)
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "child-session": [
                    "sessionId": "child-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "pid": pid,
                    "runId": lineage.runId,
                    "activeRunId": lineage.runId,
                    "relationship": "spawned",
                    "restoreAuthority": false,
                    "startedAt": now - 10,
                    "updatedAt": now,
                    "runs": [[
                        "runId": lineage.runId,
                        "pid": pid,
                        "processStartedAt": processStartedAt,
                        "relationship": "spawned",
                        "restoreAuthority": false,
                        "startedAt": now - 10,
                        "updatedAt": now,
                    ]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)

        let sessionStore = ClaudeHookSessionStore(
            processEnv: environment,
            fileManager: .default,
            agentName: "codex"
        )
        try sessionStore.upsert(
            sessionId: "child-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: nil,
            pid: pid
        )

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions["child-session"] as? [String: Any])
        #expect(record["restoreAuthority"] as? Bool == false)
        #expect(record["relationship"] as? String == "spawned")
        let runs = try #require(record["runs"] as? [[String: Any]])
        #expect(runs.first?["restoreAuthority"] as? Bool == false)
    }

    @Test func childRunCannotGainRestoreAuthorityAfterProcessGenerationChanges() throws {
        let existing = AgentSessionRunRecord(
            runId: "stable-child-run",
            pid: 101,
            processStartedAt: 100,
            parentRunId: "root-run",
            parentSessionId: "root-session",
            relationship: .spawned,
            restoreAuthority: false,
            startedAt: 100,
            updatedAt: 110,
            endedAt: nil
        )
        let replacement = AgentHookSessionLineage(
            runId: "stable-child-run",
            pid: 202,
            processStartedAt: 200,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        let runs = AgentSessionRunReconciler(maximumRecords: 128).reconciling(
            [existing],
            activeRunId: existing.runId,
            lineage: replacement,
            now: 210
        )
        let run = try #require(runs.first)

        #expect(run.processStartedAt == 200)
        #expect(run.relationship == .spawned)
        #expect(run.restoreAuthority == false)
    }

    @Test func agentsTreeReportsMalformedProviderStore() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{not-json".utf8)
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

        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(result.stderr.contains("codex-hook-sessions.json"))
    }
}
