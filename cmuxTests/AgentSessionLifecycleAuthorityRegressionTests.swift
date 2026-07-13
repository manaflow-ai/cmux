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
        let pid = Int(getpid())
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "completed-session",
            pid: pid,
            environment: [:]
        )
        let processStartedAt = try #require(lineage.processStartedAt)
        let now = Date().timeIntervalSince1970
        let recordData = try JSONSerialization.data(withJSONObject: [
            "sessionId": "completed-session",
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
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
        ])
        let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordData)

        #expect(!AgentHookSessionActivationPolicy().canActivate(
            record: record,
            lineage: lineage,
            hasIncomingPID: true
        ))
        #expect(!AgentSessionSemanticUpdatePolicy().canUpdate(record: record))
    }

    @Test func verifiedReplacementRootRegainsRestoreAuthority() throws {
        let completedRoot = AgentSessionRunRecord(
            runId: "stable-root-run",
            pid: 101,
            processStartedAt: 100,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: false,
            startedAt: 100,
            updatedAt: 110,
            endedAt: 110
        )
        let replacement = AgentHookSessionLineage(
            runId: "stable-root-run",
            pid: 202,
            processStartedAt: 200,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        let runs = AgentSessionRunReconciler(maximumRecords: 128).reconciling(
            [completedRoot],
            activeRunId: completedRoot.runId,
            lineage: replacement,
            now: 210
        )
        let run = try #require(runs.first)

        #expect(run.restoreAuthority)
        #expect(run.relationship == nil)
        #expect(run.endedAt == nil)
    }

    @Test func replacingActiveRunCreatesResumedEdge() throws {
        let previous = AgentSessionRunRecord(
            runId: "previous-root-run",
            pid: 101,
            processStartedAt: 100,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: 100,
            updatedAt: 110,
            endedAt: nil
        )
        let resumed = AgentHookSessionLineage(
            runId: "resumed-root-run",
            pid: 202,
            processStartedAt: 200,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        let runs = AgentSessionRunReconciler(maximumRecords: 128).reconciling(
            [previous],
            activeRunId: previous.runId,
            lineage: resumed,
            now: 210
        )
        let previousRun = try #require(runs.first { $0.runId == previous.runId })
        let resumedRun = try #require(runs.first { $0.runId == resumed.runId })

        #expect(previousRun.endedAt == 210)
        #expect(previousRun.restoreAuthority == false)
        #expect(resumedRun.parentRunId == previous.runId)
        #expect(resumedRun.relationship == .resumed)
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

    @Test func missingActivityEvidenceRemainsUnknown() throws {
        let now = Date().timeIntervalSince1970
        let recordData = try JSONSerialization.data(withJSONObject: [
            "sessionId": "legacy-session",
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "startedAt": now - 10,
            "updatedAt": now,
        ])
        let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordData)
        let run = AgentSessionRunRecord(
            runId: "legacy-run",
            pid: nil,
            processStartedAt: nil,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: now - 10,
            updatedAt: now,
            endedAt: nil
        )

        let projection = AgentSessionStateProjection(record: record, run: run)

        #expect(projection.activity.state == .unknown)
        #expect(!projection.activity.busy)
        #expect(projection.effective == .unknown)
    }

    @Test func queuedRootExitCannotCompleteNewerRecordGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-completion-fence-\(UUID().uuidString)", isDirectory: true)
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
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                    "runs": [[
                        "runId": "replacement-run",
                        "restoreAuthority": true,
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
            environment: ["CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path]
        )

        writer.completeSynchronously(
            kind: .codex,
            sessionId: "replacement-session",
            expectedRecordUpdatedAt: 150,
            now: 210
        )

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions["replacement-session"] as? [String: Any])
        #expect(record["completedAt"] == nil)
        #expect(record["sessionState"] as? String == "active")
        #expect(record["activeRunId"] as? String == "replacement-run")
        #expect(record["restoreAuthority"] as? Bool == true)
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
        let missingEvidence = AgentHookSessionLineage(
            runId: "stable-child-run",
            pid: 101,
            processStartedAt: 100,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        let runs = AgentSessionRunReconciler(maximumRecords: 128).reconciling(
            [existing],
            activeRunId: existing.runId,
            lineage: missingEvidence,
            now: 120
        )
        let run = try #require(runs.first)

        #expect(run.restoreAuthority == false)
        #expect(run.relationship == .spawned)
        #expect(run.parentRunId == "root-run")
        #expect(run.parentSessionId == "root-session")
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
        #expect(result.stdout.contains("codex-hook-sessions.json"))
    }
}
