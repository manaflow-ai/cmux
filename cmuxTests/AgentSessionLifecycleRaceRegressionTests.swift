import CMUXAgentLaunch
import CmuxFoundation
import Darwin
import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func canonicalRunChildEvidenceCannotRetainRestoreAuthority() throws {
        let childEvidence: [AgentSessionAuthorityEvidence] = [
            .managedChild,
            .explicitSpawnedChild,
            .verifiedAncestorChild,
            .provisionalAmbiguousChild,
            .legacyChild,
        ]
        let canonicalizer = AgentSessionRunCanonicalizer()

        func projectedRun(
            relationship: AgentSessionRelationship? = nil,
            authorityEvidence: AgentSessionAuthorityEvidence? = nil
        ) -> AgentSessionRunRecord {
            let run = AgentSessionRunRecord(
                runId: "run",
                pid: nil,
                processStartedAt: nil,
                parentRunId: nil,
                parentSessionId: nil,
                relationship: relationship,
                restoreAuthority: true,
                authorityEvidence: authorityEvidence,
                startedAt: 100,
                updatedAt: 200,
                endedAt: nil
            )
            return canonicalizer.projectedRun(
                record: ClaudeHookSessionRecord(
                    sessionId: "session",
                    workspaceId: "workspace",
                    surfaceId: "surface",
                    startedAt: 100,
                    updatedAt: 200,
                    runs: [run],
                    activeRunId: run.runId
                ),
                provider: "codex"
            )
        }

        #expect(projectedRun(relationship: .spawned).restoreAuthority == false)
        for evidence in childEvidence {
            #expect(
                projectedRun(authorityEvidence: evidence).restoreAuthority == false,
                Comment(rawValue: evidence.rawValue)
            )
        }
        #expect(
            projectedRun(
                relationship: .forked,
                authorityEvidence: .verifiedForkRoot
            ).restoreAuthority
        )
    }

    @Test func projectedRestoreAuthorityIgnoresStaleCompatibilityFieldInEitherDuplicateOrder() throws {
        func readAuthorities(
            recordRestoreAuthority: Bool,
            rawRuns: [AgentSessionRunRecord],
            suffix: String
        ) throws -> (raw: Bool?, projected: Bool?) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "cmux-canonical-child-observer-\(suffix)-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let sessionID = "canonical-child-observer"
            let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
            let environment = [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": root
                    .appendingPathComponent(CmuxAgentSessionRegistry.filename).path,
            ]
            var state = ClaudeHookSessionStoreFile()
            state.sessions[sessionID] = ClaudeHookSessionRecord(
                sessionId: sessionID,
                workspaceId: "workspace",
                surfaceId: "surface",
                pid: nil,
                runtimeStatus: .idle,
                startedAt: 10,
                updatedAt: 20,
                foregroundState: .idle,
                attentionState: AgentAttentionState.none,
                sessionState: .active,
                runs: rawRuns,
                activeRunId: rawRuns[0].runId,
                runId: rawRuns[0].runId,
                restoreAuthority: recordRestoreAuthority
            )
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)

            let store = ClaudeHookSessionStore(processEnv: environment, agentName: "claude")
            return (
                try store.lookup(sessionId: sessionID)?.restoreAuthority,
                try store.projectedRestoreAuthority(sessionId: sessionID)
            )
        }

        let runID = "session:claude:canonical-child-observer"
        let authoritative = AgentSessionRunRecord(
            runId: runID,
            pid: nil,
            processStartedAt: nil,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: 10,
            updatedAt: 20,
            endedAt: nil
        )
        var verifiedFork = authoritative
        verifiedFork.relationship = .forked
        verifiedFork.authorityEvidence = .verifiedForkRoot

        for (index, rawRuns) in [
            [authoritative, verifiedFork],
            [verifiedFork, authoritative],
        ].enumerated() {
            let authority = try readAuthorities(
                recordRestoreAuthority: false,
                rawRuns: rawRuns,
                suffix: "owner-\(index)"
            )
            #expect(authority.raw == false, Comment(rawValue: "owner order \(index)"))
            #expect(authority.projected == true, Comment(rawValue: "owner order \(index)"))
        }

        var spawnedChild = authoritative
        spawnedChild.relationship = .spawned
        spawnedChild.restoreAuthority = false
        spawnedChild.authorityEvidence = .managedChild
        for (index, rawRuns) in [
            [authoritative, spawnedChild],
            [spawnedChild, authoritative],
        ].enumerated() {
            let authority = try readAuthorities(
                recordRestoreAuthority: true,
                rawRuns: rawRuns,
                suffix: "child-\(index)"
            )
            #expect(authority.raw == true, Comment(rawValue: "child order \(index)"))
            #expect(authority.projected == false, Comment(rawValue: "child order \(index)"))
        }
    }

    @Test func canonicalRunConflictsCannotAuthorizeResumeOrStopMutations() throws {
        let attemptID = UUID()
        let authoritative = AgentSessionRunRecord(
            runId: "shared-run", pid: 42, processStartedAt: 100,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true,
            cmuxHibernationResumeAttemptId: attemptID.uuidString,
            startedAt: 100, updatedAt: 200, endedAt: nil
        )
        var conflictingProof = authoritative
        conflictingProof.cmuxHibernationResumeAttemptId = UUID().uuidString
        var conflictingIdentity = authoritative
        conflictingIdentity.pid = 84
        conflictingIdentity.processStartedAt = 101
        let resumeLineage = AgentHookSessionLineage(
            runId: authoritative.runId,
            pid: authoritative.pid,
            processStartedAt: authoritative.processStartedAt,
            processDescribesAgent: true,
            processLaunchMode: .unknown,
            hibernationResumeAttemptId: attemptID,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        for conflict in [conflictingProof, conflictingIdentity] {
            for rawRuns in [[authoritative, conflict], [conflict, authoritative]] {
                var record = ClaudeHookSessionRecord(
                    sessionId: "resume-session",
                    workspaceId: "workspace",
                    surfaceId: "surface",
                    pid: authoritative.pid,
                    startedAt: 100,
                    updatedAt: 200,
                    sessionState: .active,
                    runs: rawRuns,
                    activeRunId: authoritative.runId,
                    runId: authoritative.runId,
                    restoreAuthority: true
                )
                record.runs = AgentSessionRunCanonicalizer().runs(
                    record: record,
                    provider: "local-agent"
                )

                #expect(
                    AgentHookSessionActivationPolicy().decision(
                        record: record,
                        lineage: resumeLineage,
                        hasIncomingPID: true
                    ) == .reject
                )
            }
        }

        var ended = authoritative
        ended.restoreAuthority = false
        ended.cmuxHibernationResumeAttemptId = nil
        ended.endedAt = 250
        for rawRuns in [[authoritative, ended], [ended, authoritative]] {
            var record = ClaudeHookSessionRecord(
                sessionId: "stop-session",
                workspaceId: "workspace",
                surfaceId: "surface",
                pid: authoritative.pid,
                startedAt: 100,
                updatedAt: 200,
                sessionState: .active,
                runs: rawRuns,
                activeRunId: authoritative.runId,
                runId: authoritative.runId,
                restoreAuthority: true
            )
            record.runs = AgentSessionRunCanonicalizer().runs(
                record: record,
                provider: "local-agent"
            )
            var stopLineage = resumeLineage
            stopLineage.hibernationResumeAttemptId = nil

            #expect(
                AgentPromptStopLineagePolicy().decision(
                    record: record,
                    lineage: stopLineage,
                    incomingPID: authoritative.pid
                ) == .rejectStaleGeneration
            )
        }
    }

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

    @MainActor
    @Test func repeatedRestoredHibernationAdoptionIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-idempotent-adoption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "idempotent-adoption-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let sessionID = "idempotent-adoption-session"
        let previousWorkspaceID = UUID()
        let previousSurfaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let slot: [String: Any] = ["sessionId": sessionID, "updatedAt": 10.0]
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: [
                "sessionId": sessionID,
                "workspaceId": previousWorkspaceID.uuidString,
                "surfaceId": previousSurfaceID.uuidString,
                "sessionState": "hibernated",
                "restoreAuthority": true,
                "startedAt": 1.0,
                "updatedAt": 10.0,
            ]],
            "activeSessionsByWorkspace": [previousWorkspaceID.uuidString: slot],
            "activeSessionsBySurface": [previousSurfaceID.uuidString: slot],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_SH | LOCK_NB) == 0)
        defer { _ = flock(descriptor, LOCK_UN) }
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: root.path,
            launchCommand: nil
        )

        let firstAdoption = AgentHookSessionStateWriter.recordRestoredHibernation(
            agent: agent,
            previousWorkspaceId: previousWorkspaceID,
            previousSurfaceId: previousSurfaceID,
            workspaceId: targetWorkspaceID,
            surfaceId: targetSurfaceID
        )
        let repeatedAdoption = AgentHookSessionStateWriter.recordRestoredHibernation(
            agent: agent,
            previousWorkspaceId: previousWorkspaceID,
            previousSurfaceId: previousSurfaceID,
            workspaceId: targetWorkspaceID,
            surfaceId: targetSurfaceID
        )

        #expect(firstAdoption)
        #expect(repeatedAdoption)
        let snapshot = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "codex")
        let record = try #require(snapshot.records.first { $0.sessionID == sessionID })
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == targetWorkspaceID.uuidString)
        #expect(object["surfaceId"] as? String == targetSurfaceID.uuidString)
        #expect(snapshot.activeSlots.count == 2)
        #expect(snapshot.activeSlots.first {
            $0.scope == .workspace && $0.scopeID == targetWorkspaceID.uuidString
        }?.sessionID == sessionID)
        #expect(snapshot.activeSlots.first {
            $0.scope == .surface && $0.scopeID == targetSurfaceID.uuidString
        }?.sessionID == sessionID)
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

    @Test func hibernatedAndRestoringRowsRequireANewerProcessGenerationToActivate() {
        let savedRun = AgentSessionRunRecord(
            runId: "stable-run", pid: 123, processStartedAt: 100,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, startedAt: 100, updatedAt: 200, endedAt: nil
        )
        let sameGeneration = AgentHookSessionLineage(
            runId: savedRun.runId, pid: savedRun.pid,
            processStartedAt: savedRun.processStartedAt,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true
        )
        let resumedGeneration = AgentHookSessionLineage(
            runId: savedRun.runId, pid: 456, processStartedAt: 300,
            processDescribesAgent: true, processLaunchMode: .interactive,
            parentRunId: nil, parentSessionId: nil, relationship: .resumed,
            restoreAuthority: true
        )

        for state in [AgentSessionLifecycleState.hibernated, .restoring] {
            let record = ClaudeHookSessionRecord(
                sessionId: "protected-session", workspaceId: "workspace", surfaceId: "surface",
                pid: savedRun.pid, startedAt: 100, updatedAt: 200, sessionState: state,
                runs: [savedRun], activeRunId: savedRun.runId
            )
            #expect(!AgentHookSessionActivationPolicy().canActivate(
                record: record, lineage: sameGeneration, hasIncomingPID: true
            ))
            #expect(AgentHookSessionActivationPolicy().canActivate(
                record: record, lineage: resumedGeneration, hasIncomingPID: true
            ))
        }
    }

    @Test func hibernatedAndRestoringRowsRejectNonInteractiveNewerProcessGenerations() {
        let savedRun = AgentSessionRunRecord(
            runId: "stable-run", pid: 123, processStartedAt: 100,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, startedAt: 100, updatedAt: 200, endedAt: nil
        )
        let nonInteractiveGenerations = [
            AgentHookSessionLineage(
                runId: savedRun.runId, pid: 456, processStartedAt: 300,
                processDescribesAgent: true, processLaunchMode: .oneShot,
                parentRunId: nil, parentSessionId: nil, relationship: .resumed,
                restoreAuthority: true
            ),
            AgentHookSessionLineage(
                runId: savedRun.runId, pid: 457, processStartedAt: 301,
                processDescribesAgent: true, processLaunchMode: .nonSession,
                parentRunId: nil, parentSessionId: nil, relationship: .resumed,
                restoreAuthority: true
            ),
            AgentHookSessionLineage(
                runId: savedRun.runId, pid: 458, processStartedAt: 302,
                processDescribesAgent: true, processLaunchMode: .unknown,
                parentRunId: nil, parentSessionId: nil, relationship: .resumed,
                restoreAuthority: true
            ),
        ]

        for state in [AgentSessionLifecycleState.hibernated, .restoring] {
            let record = ClaudeHookSessionRecord(
                sessionId: "protected-session", workspaceId: "workspace", surfaceId: "surface",
                pid: savedRun.pid, startedAt: 100, updatedAt: 200, sessionState: state,
                runs: [savedRun], activeRunId: savedRun.runId
            )
            for lineage in nonInteractiveGenerations {
                #expect(!AgentHookSessionActivationPolicy().canActivate(
                    record: record, lineage: lineage, hasIncomingPID: true
                ))
            }
        }
    }

    @Test func protectedLifecycleRequiresInteractiveOrExactRootCustomResumeEvidence() {
        let savedRun = AgentSessionRunRecord(
            runId: "stable-run", pid: 123, processStartedAt: 100,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, startedAt: 100, updatedAt: 200, endedAt: nil
        )
        let attemptID = UUID()
        let matchingCustomResume = AgentHookSessionLineage(
            runId: savedRun.runId, pid: 456, processStartedAt: 300,
            processDescribesAgent: true, processLaunchMode: .unknown,
            hibernationResumeAttemptId: attemptID,
            parentRunId: nil, parentSessionId: nil, relationship: .resumed,
            restoreAuthority: true
        )
        var mismatchedCustomResume = matchingCustomResume
        mismatchedCustomResume.hibernationResumeAttemptId = UUID()
        var nestedCustomResume = matchingCustomResume
        nestedCustomResume.relationship = .spawned
        nestedCustomResume.restoreAuthority = false
        var unrecognizedCustomResume = matchingCustomResume
        unrecognizedCustomResume.processDescribesAgent = false
        var oneShotCustomResume = matchingCustomResume
        oneShotCustomResume.processLaunchMode = .oneShot
        var nonSessionCustomResume = matchingCustomResume
        nonSessionCustomResume.processLaunchMode = .nonSession
        var nestedInteractiveResume = matchingCustomResume
        nestedInteractiveResume.processLaunchMode = .interactive
        nestedInteractiveResume.relationship = .spawned
        nestedInteractiveResume.restoreAuthority = false
        let rejected = [
            mismatchedCustomResume,
            nestedCustomResume,
            unrecognizedCustomResume,
            oneShotCustomResume,
            nonSessionCustomResume,
            nestedInteractiveResume,
        ]

        for state in [AgentSessionLifecycleState.hibernated, .restoring] {
            let record = ClaudeHookSessionRecord(
                sessionId: "protected-session", workspaceId: "workspace", surfaceId: "surface",
                pid: savedRun.pid, startedAt: 100, updatedAt: 200, sessionState: state,
                runs: [savedRun], activeRunId: savedRun.runId,
                cmuxHibernationResumeAttemptId: attemptID.uuidString
            )
            #expect(AgentHookSessionActivationPolicy().canActivate(
                record: record, lineage: matchingCustomResume, hasIncomingPID: true
            ))
            for lineage in rejected {
                #expect(!AgentHookSessionActivationPolicy().canActivate(
                    record: record, lineage: lineage, hasIncomingPID: true
                ))
            }
        }
    }

    @Test func exactCustomResumeActivationRetainsFutureRestoreAuthorityThroughStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-custom-resume-authority-\(UUID().uuidString)", isDirectory: true)
        let customAgent = root.appendingPathComponent("local-agent")
        let fakeCmux = root.appendingPathComponent("cmux")
        let pidFile = root.appendingPathComponent("agent-pid")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: customAgent.path)
        try FileManager.default.copyItem(atPath: "/bin/sh", toPath: fakeCmux.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let terminalHost = Process()
        terminalHost.executableURL = fakeCmux
        terminalHost.arguments = [
            "-c",
            "\(customAgent.path) 30 & echo $! > \(pidFile.path); wait",
        ]
        try terminalHost.run()
        defer {
            if terminalHost.isRunning { terminalHost.terminate() }
            terminalHost.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(2)
        var agentPID: Int?
        repeat {
            if let contents = try? String(contentsOf: pidFile, encoding: .utf8) {
                agentPID = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if agentPID != nil { break }
            usleep(10_000)
        } while Date() < deadline
        let resumedPID = try #require(agentPID)
        defer { kill(pid_t(resumedPID), SIGTERM) }

        let sessionID = "custom-resumed-session"
        let mismatchedSessionID = "custom-mismatched-session"
        let resumeAttemptID = UUID()
        let mismatchedAttemptID = UUID()
        let stateURL = root.appendingPathComponent("local-agent-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                sessionID: [
                    "sessionId": sessionID,
                    "workspaceId": "workspace-before",
                    "surfaceId": "surface-before",
                    "pid": 123,
                    "runId": "saved-run",
                    "activeRunId": "saved-run",
                    "sessionState": "restoring",
                    "restoreAuthority": true,
                    "cmuxHibernationResumeAttemptId": resumeAttemptID.uuidString,
                    "cmuxHibernationResumeStartedAt": 20.0,
                    "startedAt": 10.0,
                    "updatedAt": 20.0,
                    "runs": [[
                        "runId": "saved-run",
                        "pid": 123,
                        "processStartedAt": 10.0,
                        "restoreAuthority": true,
                        "startedAt": 10.0,
                        "updatedAt": 20.0,
                    ]],
                ],
                mismatchedSessionID: [
                    "sessionId": mismatchedSessionID,
                    "workspaceId": "mismatch-workspace-before",
                    "surfaceId": "mismatch-surface-before",
                    "sessionState": "restoring",
                    "restoreAuthority": true,
                    "cmuxHibernationResumeAttemptId": mismatchedAttemptID.uuidString,
                    "cmuxHibernationResumeStartedAt": 20.0,
                    "startedAt": 10.0,
                    "updatedAt": 20.0,
                ],
            ],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
            AgentHibernationResumeEvidence.environmentKey: resumeAttemptID.uuidString,
        ], agentName: "local-agent")

        #expect(try store.upsert(
            sessionId: sessionID,
            workspaceId: "workspace-after",
            surfaceId: "surface-after",
            cwd: root.path,
            pid: resumedPID,
            markActive: true
        ))

        let activated = try #require(try store.lookup(sessionId: sessionID))
        let activeRunID = try #require(activated.activeRunId)
        let activeRun = try #require(activated.runs?.first { $0.runId == activeRunID })
        #expect(activated.sessionState == .active)
        #expect(activated.cmuxHibernationResumeAttemptId == nil)
        #expect(activated.restoreAuthority == true)
        #expect(activeRun.restoreAuthority)
        #expect(activeRun.cmuxHibernationResumeAttemptId == resumeAttemptID.uuidString)

        #expect(try store.upsert(
            sessionId: sessionID,
            workspaceId: "workspace-after",
            surfaceId: "surface-after",
            cwd: root.path,
            pid: resumedPID,
            markActive: true
        ))
        let afterDuplicateHook = try #require(try store.lookup(sessionId: sessionID))
        #expect(afterDuplicateHook.activeRunId == activeRunID)
        #expect(afterDuplicateHook.restoreAuthority == true)
        #expect(afterDuplicateHook.runs?.first { $0.runId == activeRunID }?.restoreAuthority == true)
        #expect(
            afterDuplicateHook.runs?.first { $0.runId == activeRunID }?.cmuxHibernationResumeAttemptId
                == resumeAttemptID.uuidString
        )

        #expect(!(try store.upsert(
            sessionId: mismatchedSessionID,
            workspaceId: "mismatch-workspace-after",
            surfaceId: "mismatch-surface-after",
            cwd: root.path,
            pid: resumedPID,
            markActive: true
        )))
        let rejected = try #require(try store.lookup(sessionId: mismatchedSessionID))
        #expect(rejected.sessionState == .restoring)
        #expect(rejected.cmuxHibernationResumeAttemptId == mismatchedAttemptID.uuidString)
        #expect(rejected.restoreAuthority == true)
        #expect(rejected.activeRunId == nil)
        #expect((rejected.runs ?? []).isEmpty)
        #expect(store.snapshot().activeSessionsByWorkspace["mismatch-workspace-after"] == nil)
        #expect(store.snapshot().activeSessionsBySurface["mismatch-surface-after"] == nil)
    }

    @Test func lineageResolverReadsValidatedHibernationResumeAttemptEvidence() {
        let attemptID = UUID()
        let valid = AgentHookSessionLineageResolver().resolve(
            agentName: "local-agent",
            sessionId: "custom-session",
            pid: nil,
            environment: [AgentHibernationResumeEvidence.environmentKey: attemptID.uuidString]
        )
        let malformed = AgentHookSessionLineageResolver().resolve(
            agentName: "local-agent",
            sessionId: "custom-session",
            pid: nil,
            environment: [AgentHibernationResumeEvidence.environmentKey: "not-a-uuid"]
        )

        #expect(valid.hibernationResumeAttemptId == attemptID)
        #expect(malformed.hibernationResumeAttemptId == nil)
    }

    @Test func exactLaunchCaptureRecoversCollapsedInterpreterProcessModes() throws {
        let providers = [
            (kind: "pi", title: "pi", processDescribesAgent: true),
            (kind: "omp", title: "omp", processDescribesAgent: true),
            (kind: "kimi", title: "Kimi Code", processDescribesAgent: false),
        ]
        for provider in providers {
            try withCollapsedInterpreterProcess(
                title: provider.title,
                hostExecutableName: "cmux.app/Contents/MacOS/cmux"
            ) { pid, root in
                let unassisted = AgentHookSessionLineageResolver().resolve(
                    agentName: provider.kind,
                    sessionId: "\(provider.kind)-collapsed-unassisted",
                    pid: pid,
                    environment: [:]
                )
                #expect(
                    unassisted.processDescribesAgent == provider.processDescribesAgent,
                    Comment(rawValue: provider.kind)
                )
                #expect(unassisted.processLaunchMode == .unknown, Comment(rawValue: provider.kind))

                var environment = exactAgentLaunchEnvironment(
                    kind: provider.kind,
                    arguments: [provider.kind]
                )
                environment["CMUX_CLAUDE_HOOK_STATE_PATH"] = root
                    .appendingPathComponent("\(provider.kind)-hook-sessions.json").path
                environment["CMUX_AGENT_SESSION_REGISTRY_PATH"] = root
                    .appendingPathComponent("\(provider.kind)-sessions.sqlite3").path
                environment["CMUX_RUNTIME_ID"] = "\(provider.kind)-collapsed-runtime"

                let recovered = AgentHookSessionLineageResolver().resolve(
                    agentName: provider.kind,
                    sessionId: "\(provider.kind)-collapsed-recovered",
                    pid: pid,
                    environment: environment
                )
                #expect(recovered.processLaunchMode == .interactive, Comment(rawValue: provider.kind))
                #expect(recovered.restoreAuthority, Comment(rawValue: provider.kind))
                #expect(recovered.relationship == nil, Comment(rawValue: provider.kind))

                let store = ClaudeHookSessionStore(processEnv: environment, agentName: provider.kind)
                let sessionID = "\(provider.kind)-collapsed-store"
                #expect(try store.upsert(
                    sessionId: sessionID,
                    workspaceId: "workspace-\(provider.kind)",
                    surfaceId: "surface-\(provider.kind)",
                    cwd: root.path,
                    pid: pid,
                    isRestorable: true,
                    markActive: true
                ))
                let record = try #require(try store.lookup(sessionId: sessionID))
                let activeRunID = try #require(record.activeRunId)
                #expect(record.restoreAuthority == true, Comment(rawValue: provider.kind))
                #expect(
                    record.runs?.first { $0.runId == activeRunID }?.restoreAuthority == true,
                    Comment(rawValue: provider.kind)
                )
            }
        }
    }

    @Test func inheritedCrossProviderCaptureCannotRecoverCollapsedProcessMode() throws {
        try withCollapsedInterpreterProcess(
            title: "pi",
            hostExecutableName: "cmux.app/Contents/MacOS/cmux"
        ) { pid, _ in
            let lineage = AgentHookSessionLineageResolver().resolve(
                agentName: "pi",
                sessionId: "pi-cross-provider-capture",
                pid: pid,
                environment: exactAgentLaunchEnvironment(
                    kind: "claude",
                    arguments: ["claude", "--model", "sonnet"]
                )
            )

            #expect(lineage.processDescribesAgent)
            #expect(lineage.processLaunchMode == .unknown)
        }
    }

    @Test func exactOneShotCaptureCannotGainAuthorityFromCollapsedProcessTitle() throws {
        try withCollapsedInterpreterProcess(
            title: "pi",
            hostExecutableName: "cmux.app/Contents/MacOS/cmux"
        ) { pid, root in
            var environment = exactAgentLaunchEnvironment(
                kind: "pi",
                arguments: ["pi", "--print", "reply once"]
            )
            environment["CMUX_CLAUDE_HOOK_STATE_PATH"] = root
                .appendingPathComponent("pi-one-shot-hook-sessions.json").path
            environment["CMUX_AGENT_SESSION_REGISTRY_PATH"] = root
                .appendingPathComponent("pi-one-shot-sessions.sqlite3").path

            let lineage = AgentHookSessionLineageResolver().resolve(
                agentName: "pi",
                sessionId: "pi-collapsed-one-shot",
                pid: pid,
                environment: environment
            )
            #expect(lineage.processLaunchMode == .oneShot)

            let store = ClaudeHookSessionStore(processEnv: environment, agentName: "pi")
            #expect(try store.upsert(
                sessionId: "pi-collapsed-one-shot",
                workspaceId: "workspace-pi-one-shot",
                surfaceId: "surface-pi-one-shot",
                cwd: root.path,
                pid: pid,
                isRestorable: true,
                markActive: true
            ))
            let record = try #require(try store.lookup(sessionId: "pi-collapsed-one-shot"))
            let activeRunID = try #require(record.activeRunId)
            #expect(record.restoreAuthority == false)
            #expect(record.runs?.first { $0.runId == activeRunID }?.restoreAuthority == false)
        }
    }

    @Test func exactLaunchCaptureNeverOverridesNestedAgentAuthority() throws {
        try withCollapsedInterpreterProcess(title: "pi", hostExecutableName: "codex") { pid, _ in
            let lineage = AgentHookSessionLineageResolver().resolve(
                agentName: "pi",
                sessionId: "nested-pi-collapsed-title",
                pid: pid,
                environment: exactAgentLaunchEnvironment(
                    kind: "pi",
                    arguments: ["pi"]
                )
            )

            #expect(lineage.processLaunchMode == .interactive)
            #expect(lineage.relationship == .spawned)
            #expect(!lineage.restoreAuthority)
            #expect(lineage.parentRunId != nil)
        }
    }

    @MainActor
    @Test func staleResumeRollbackCannotRevokeNewerAttempt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-stale-resume-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeID = "stale-resume-rollback-runtime"
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root
                .appendingPathComponent(CmuxAgentSessionRegistry.filename).path,
            "CMUX_RUNTIME_ID": runtimeID,
        ]
        let previousEnvironment = overrides.keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let staleAttemptID = UUID()
        let currentAttemptID = UUID()
        let fixture = try installProtectedLifecycleAuthority(
            root: root,
            runtimeID: runtimeID,
            sessionID: "stale-resume-rollback-session",
            lifecycle: .restoring,
            hibernationAttemptID: UUID(),
            resumeAttemptID: currentAttemptID
        )

        AgentHookSessionStateWriter.releaseFailedHibernatedResumeAuthority(
            .init(
                agent: fixture.agent,
                workspaceId: fixture.workspaceID,
                surfaceId: fixture.surfaceID,
                attemptId: staleAttemptID
            ),
            now: 40
        )

        let snapshot = try fixture.registry.snapshot(provider: "codex")
        let record = try #require(snapshot.records.first)
        let object = try #require(
            JSONSerialization.jsonObject(with: record.json) as? [String: Any]
        )
        #expect(object["sessionState"] as? String == "restoring")
        #expect(object["cmuxHibernationResumeAttemptId"] as? String == currentAttemptID.uuidString)
        #expect(object["cmuxHibernationResumeStartedAt"] as? TimeInterval == 30)
        #expect(snapshot.activeSlots.count == 2)
    }

    @MainActor
    @Test func stalePortalCloseCompensationCannotDetachNewerHibernationAttempt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-stale-portal-compensation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeID = "stale-portal-compensation-runtime"
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root
                .appendingPathComponent(CmuxAgentSessionRegistry.filename).path,
            "CMUX_RUNTIME_ID": runtimeID,
        ]
        let previousEnvironment = overrides.keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let staleAttemptID = UUID()
        let currentAttemptID = UUID()
        let fixture = try installProtectedLifecycleAuthority(
            root: root,
            runtimeID: runtimeID,
            sessionID: "stale-portal-compensation-session",
            lifecycle: .hibernated,
            hibernationAttemptID: currentAttemptID
        )

        await AgentHookSessionStateWriter.releaseFailedHibernationAuthority(
            agent: fixture.agent,
            workspaceId: fixture.workspaceID,
            surfaceId: fixture.surfaceID,
            attemptId: staleAttemptID,
            now: 40
        )

        let snapshot = try fixture.registry.snapshot(provider: "codex")
        let record = try #require(snapshot.records.first)
        let object = try #require(
            JSONSerialization.jsonObject(with: record.json) as? [String: Any]
        )
        #expect(object["sessionState"] as? String == "hibernated")
        #expect(object["cmuxHibernationAttemptId"] as? String == currentAttemptID.uuidString)
        #expect(object["cmuxHibernationDetached"] == nil)
        #expect(snapshot.activeSlots.count == 2)
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

    @Test func nestedCustomAgentCannotClaimRootRestoreAuthority() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-custom-agent-ancestry-\(UUID().uuidString)", isDirectory: true)
        let customAgent = root.appendingPathComponent("local-agent")
        let pidFile = root.appendingPathComponent("child-pid")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sh", toPath: customAgent.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = Process()
        parent.executableURL = customAgent
        parent.arguments = [
            "-c",
            "\(customAgent.path) -c 'sleep 30 & wait' & echo $! > \(pidFile.path); wait",
        ]
        try parent.run()
        defer {
            if parent.isRunning { parent.terminate() }
            parent.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(2)
        var childPID: Int?
        repeat {
            if let contents = try? String(contentsOf: pidFile, encoding: .utf8) {
                childPID = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if childPID != nil { break }
            usleep(10_000)
        } while Date() < deadline
        let resolvedChildPID = try #require(childPID)
        defer { kill(pid_t(resolvedChildPID), SIGTERM) }

        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "local-agent",
            sessionId: "nested-custom-session",
            pid: resolvedChildPID,
            environment: [:]
        )

        #expect(lineage.processDescribesAgent)
        #expect(lineage.processLaunchMode == .unknown)
        #expect(!lineage.restoreAuthority)
        #expect(lineage.relationship == .spawned)
    }

    private func installProtectedLifecycleAuthority(
        root: URL,
        runtimeID: String,
        sessionID: String,
        lifecycle: AgentSessionLifecycleState,
        hibernationAttemptID: UUID,
        resumeAttemptID: UUID? = nil
    ) throws -> (
        agent: SessionRestorableAgentSnapshot,
        workspaceID: UUID,
        surfaceID: UUID,
        registry: CmuxAgentSessionRegistry
    ) {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        var record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": surfaceID.uuidString,
            "sessionState": lifecycle.rawValue,
            "restoreAuthority": true,
            "cmuxHibernationAttemptId": hibernationAttemptID.uuidString,
            "cmuxRuntime": ["id": runtimeID],
            "startedAt": 10.0,
            "updatedAt": 30.0,
        ]
        if let resumeAttemptID {
            record["cmuxHibernationResumeAttemptId"] = resumeAttemptID.uuidString
            record["cmuxHibernationResumeStartedAt"] = 30.0
            record["cmuxHibernationResumeFromAttemptId"] = hibernationAttemptID.uuidString
        }
        let slot: [String: Any] = ["sessionId": sessionID, "updatedAt": 30.0]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: record],
            "activeSessionsByWorkspace": [workspaceID.uuidString: slot],
            "activeSessionsBySurface": [surfaceID.uuidString: slot],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)

        let recordJSON = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let slotJSON = try JSONSerialization.data(withJSONObject: slot, options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(
            provider: "codex",
            records: [.init(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 30,
                json: recordJSON
            )],
            activeSlots: [
                .init(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: workspaceID.uuidString,
                    sessionID: sessionID,
                    updatedAt: 30,
                    json: slotJSON
                ),
                .init(
                    provider: "codex",
                    scope: .surface,
                    scopeID: surfaceID.uuidString,
                    sessionID: sessionID,
                    updatedAt: 30,
                    json: slotJSON
                ),
            ]
        )
        return (
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionID,
                workingDirectory: root.path,
                launchCommand: nil
            ),
            workspaceID,
            surfaceID,
            registry
        )
    }

    private func exactAgentLaunchEnvironment(
        kind: String,
        arguments: [String]
    ) -> [String: String] {
        var bytes = Data()
        for argument in arguments {
            bytes.append(contentsOf: argument.utf8)
            bytes.append(0)
        }
        return [
            "CMUX_AGENT_LAUNCH_KIND": kind,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": arguments.first ?? kind,
            "CMUX_AGENT_LAUNCH_ARGV_B64": bytes.base64EncodedString(),
        ]
    }

    private func withCollapsedInterpreterProcess(
        title: String,
        hostExecutableName: String,
        body: (Int, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-collapsed-agent-title-\(UUID().uuidString)", isDirectory: true)
        let host = root.appendingPathComponent(hostExecutableName)
        try FileManager.default.createDirectory(
            at: host.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(atPath: "/bin/bash", toPath: host.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = Process()
        let readyPipe = Pipe()
        launcher.executableURL = host
        launcher.arguments = [
            "-c",
            "exec -a \(title) /usr/bin/ruby -e 'sleep 30' & child=$!; printf '%s\\n' \"$child\"; wait \"$child\"",
        ]
        launcher.standardOutput = readyPipe
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()
        var childPID: Int?
        defer {
            if let childPID {
                kill(pid_t(childPID), SIGTERM)
            } else if launcher.isRunning {
                launcher.terminate()
            }
            launcher.waitUntilExit()
            try? readyPipe.fileHandleForReading.close()
        }

        var pidBytes = Data()
        while let byte = try readyPipe.fileHandleForReading.read(upToCount: 1)?.first,
              byte != UInt8(ascii: "\n") {
            pidBytes.append(byte)
        }
        let resolvedPID = try #require(
            Int(String(decoding: pidBytes, as: UTF8.self))
        )
        childPID = resolvedPID

        try body(resolvedPID, root)
    }
}
