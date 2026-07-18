import CmuxFoundation
import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @MainActor
    @Test func supersededPreviousSurfaceRejectsRestoredHibernationAdoption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-superseded-surface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "superseded-surface-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let sessionID = "superseded-surface-restored"
        let occupantSessionID = "superseded-surface-occupant"
        let previousWorkspaceID = UUID()
        let previousSurfaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let restoredSlot: [String: Any] = ["sessionId": sessionID, "updatedAt": 10.0]
        let occupantSlot: [String: Any] = ["sessionId": occupantSessionID, "updatedAt": 30.0]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                sessionID: [
                    "sessionId": sessionID,
                    "workspaceId": previousWorkspaceID.uuidString,
                    "surfaceId": previousSurfaceID.uuidString,
                    "sessionState": "hibernated",
                    "restoreAuthority": true,
                    "startedAt": 1.0,
                    "updatedAt": 10.0,
                ],
                occupantSessionID: [
                    "sessionId": occupantSessionID,
                    "workspaceId": previousWorkspaceID.uuidString,
                    "surfaceId": previousSurfaceID.uuidString,
                    "sessionState": "active",
                    "restoreAuthority": true,
                    "startedAt": 25.0,
                    "updatedAt": 30.0,
                ],
            ],
            "activeSessionsByWorkspace": [previousWorkspaceID.uuidString: restoredSlot],
            "activeSessionsBySurface": [previousSurfaceID.uuidString: occupantSlot],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: root.path,
            launchCommand: nil
        )

        let adopted = AgentHookSessionStateWriter.recordRestoredHibernation(
            agent: agent,
            previousWorkspaceId: previousWorkspaceID,
            previousSurfaceId: previousSurfaceID,
            workspaceId: targetWorkspaceID,
            surfaceId: targetSurfaceID
        )

        #expect(!adopted)
        let snapshot = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "codex")
        let restoredRecord = try #require(snapshot.records.first { $0.sessionID == sessionID })
        let restoredObject = try #require(
            JSONSerialization.jsonObject(with: restoredRecord.json) as? [String: Any]
        )
        #expect(restoredObject["workspaceId"] as? String == previousWorkspaceID.uuidString)
        #expect(restoredObject["surfaceId"] as? String == previousSurfaceID.uuidString)
        #expect(snapshot.activeSlots.first {
            $0.scope == .workspace && $0.scopeID == previousWorkspaceID.uuidString
        }?.sessionID == sessionID)
        #expect(snapshot.activeSlots.first {
            $0.scope == .surface && $0.scopeID == previousSurfaceID.uuidString
        }?.sessionID == occupantSessionID)
        #expect(!snapshot.activeSlots.contains {
            $0.scopeID == targetWorkspaceID.uuidString || $0.scopeID == targetSurfaceID.uuidString
        })
    }

    @Test func hibernationAndRestoreOwnLateTeardownHooks() throws {
        for lifecycle in ["hibernated", "restoring"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-agent-late-teardown-\(lifecycle)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
            let sessionID = "\(lifecycle)-session"
            try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "sessions": [sessionID: [
                    "sessionId": sessionID,
                    "workspaceId": "workspace",
                    "surfaceId": "surface",
                    "sessionState": lifecycle,
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
            ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
            let store = ClaudeHookSessionStore(
                processEnv: [
                    "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                    "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
                ],
                agentName: "codex"
            )

            #expect(try store.consume(
                sessionId: sessionID,
                workspaceId: "workspace",
                surfaceId: "surface"
            ) == nil)
            #expect(try store.lookup(sessionId: sessionID)?.sessionState?.rawValue == lifecycle)
        }
    }

    @Test func completedRunWithoutPriorStartAcceptsVerifiedNewProcess() {
        let prior = AgentSessionRunRecord(
            runId: "stable-run", pid: nil, processStartedAt: nil,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: false, startedAt: 100, updatedAt: 200, endedAt: 200
        )
        let record = ClaudeHookSessionRecord(
            sessionId: "resumed-session", workspaceId: "workspace", surfaceId: "surface",
            startedAt: 100, updatedAt: 200, sessionState: .ended,
            runs: [prior], completedAt: 200
        )
        let replacement = AgentHookSessionLineage(
            runId: prior.runId, pid: 202, processStartedAt: 300,
            parentRunId: nil, parentSessionId: nil, relationship: nil, restoreAuthority: true
        )

        #expect(AgentHookSessionActivationPolicy().canActivate(
            record: record, lineage: replacement, hasIncomingPID: true
        ))
    }

    @Test func completedLegacyRecordRejectsHooksFromItsOriginalProcessGeneration() {
        let record = ClaudeHookSessionRecord(
            sessionId: "legacy-completed",
            workspaceId: "workspace",
            surfaceId: "surface",
            startedAt: 100,
            updatedAt: 200,
            runs: nil,
            completedAt: 200
        )
        let originalProcess = AgentHookSessionLineage(
            runId: "pid:123@100",
            pid: 123,
            processStartedAt: 100,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        #expect(!AgentHookSessionActivationPolicy().canActivate(
            record: record,
            lineage: originalProcess,
            hasIncomingPID: true
        ))
    }

    @Test func pidlessEventCannotBorrowVerifiedActiveProcessGeneration() {
        let activeRun = AgentSessionRunRecord(
            runId: "resumed-run", pid: 202, processStartedAt: 200,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, startedAt: 200, updatedAt: 210, endedAt: nil
        )
        let record = ClaudeHookSessionRecord(
            sessionId: "session", workspaceId: "workspace", surfaceId: "surface",
            pid: 202, startedAt: 100, updatedAt: 210,
            runs: [activeRun], activeRunId: activeRun.runId
        )
        let borrowedLineage = AgentHookSessionLineage(
            runId: activeRun.runId, pid: activeRun.pid,
            processStartedAt: activeRun.processStartedAt,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true
        )

        #expect(!AgentHookSessionActivationPolicy().canActivate(
            record: record,
            lineage: borrowedLineage,
            hasIncomingPID: false
        ))
    }

    @Test func liveHookMovesSurvivingRunIntoConnectedCmuxRuntime() throws {
        let oldRuntime = AgentCmuxRuntimeIdentity(
            id: "old-runtime", socketPath: "/tmp/old.sock", bundleIdentifier: "com.cmuxterm.old"
        )
        let currentRuntime = AgentCmuxRuntimeIdentity(
            id: "current-runtime", socketPath: "/tmp/current.sock", bundleIdentifier: "com.cmuxterm.current"
        )
        let stored = AgentSessionRunRecord(
            runId: "surviving-run", pid: 123, processStartedAt: 100, cmuxRuntime: oldRuntime,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, startedAt: 100, updatedAt: 110, endedAt: nil
        )
        let liveHook = AgentHookSessionLineage(
            runId: "surviving-run", pid: 123, processStartedAt: 100, cmuxRuntime: currentRuntime,
            parentRunId: nil, parentSessionId: nil, relationship: nil, restoreAuthority: true
        )

        let updated = AgentSessionRunReconciler(maximumRecords: 128).reconciling(
            [stored], activeRunId: stored.runId, lineage: liveHook, now: 120
        )

        #expect(try #require(updated.first).cmuxRuntime == currentRuntime)
    }

    @Test func completedGenerationRejectsApprovalResponseVisibleMutations() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "ended-approval")
        defer { context.cleanup() }
        let stateURL = context.root.appendingPathComponent("hermes-agent-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": ["completed-session": [
                "sessionId": "completed-session",
                "workspaceId": context.workspaceId,
                "surfaceId": context.surfaceId,
                "completedAt": 200.0, "sessionState": "ended", "startedAt": 100.0, "updatedAt": 200.0,
                "runs": [[
                    "runId": "completed-run", "restoreAuthority": false,
                    "startedAt": 100.0, "updatedAt": 200.0, "endedAt": 200.0,
                ]],
            ]],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let ttyName = "ttys-ended-approval"
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: ttyName,
            ttySurfaceId: context.surfaceId
        )
        var environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: ttyName,
            storeURL: stateURL
        )
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path

        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "hermes-agent", "approval-response"],
            environment: environment,
            standardInput: #"{"session_id":"completed-session","hook_event_name":"post_approval_response"}"#,
            timeout: 5
        )

        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        let commands = context.state.snapshot()
        #expect(!commands.contains { command in
            command.contains("set_status hermes-agent ")
                || command.contains("set_agent_pid hermes-agent ")
                || command.contains("clear_notifications")
                || command.contains(#""method":"surface.resume.set""#)
        })
    }

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

    @Test func completedGenerationCannotReactivateThroughSameProcessLineage() {
        let completedRun = AgentSessionRunRecord(
            runId: "completed-run", pid: 123, processStartedAt: 100,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: false, startedAt: 100, updatedAt: 200, endedAt: 200
        )
        let record = ClaudeHookSessionRecord(
            sessionId: "completed-session", workspaceId: "workspace", surfaceId: "surface",
            startedAt: 100, updatedAt: 200, sessionState: .ended,
            runs: [completedRun], completedAt: 200
        )
        let sameProcess = AgentHookSessionLineage(
            runId: completedRun.runId, pid: completedRun.pid,
            processStartedAt: completedRun.processStartedAt,
            parentRunId: nil, parentSessionId: nil, relationship: nil, restoreAuthority: true
        )

        #expect(!AgentHookSessionActivationPolicy().canActivate(
            record: record, lineage: sameProcess, hasIncomingPID: true
        ))
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

    @Test func agentLauncherAboveCmuxHostCannotDemoteRootSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-host-boundary-\(UUID().uuidString)", isDirectory: true)
        let fakeAgent = root.appendingPathComponent("codex")
        let fakeCmux = root.appendingPathComponent("cmux.app/Contents/MacOS/cmux")
        let pidFile = root.appendingPathComponent("pids")
        try FileManager.default.createDirectory(
            at: fakeCmux.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(atPath: "/bin/sh", toPath: fakeAgent.path)
        try FileManager.default.copyItem(atPath: "/bin/sh", toPath: fakeCmux.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = Process()
        launcher.executableURL = fakeAgent
        launcher.arguments = [
            "-c",
            "\(fakeCmux.path) -c 'sleep 30 & echo $$ $! > \(pidFile.path); wait'",
        ]
        try launcher.run()
        defer { if launcher.isRunning { launcher.terminate() } }

        let deadline = Date().addingTimeInterval(2)
        var processIDs: [Int] = []
        repeat {
            if let contents = try? String(contentsOf: pidFile, encoding: .utf8) {
                processIDs = contents.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            }
            if processIDs.count == 2 { break }
            usleep(10_000)
        } while Date() < deadline
        let cmuxPID = try #require(processIDs.first)
        let rootAgentPID = try #require(processIDs.last)
        defer {
            kill(pid_t(rootAgentPID), SIGTERM)
            kill(pid_t(cmuxPID), SIGTERM)
        }

        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "root-session",
            pid: rootAgentPID,
            environment: [:]
        )

        #expect(lineage.restoreAuthority)
        #expect(lineage.relationship == nil)
        #expect(lineage.parentRunId == nil)
    }
}
