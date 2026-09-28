@testable import CmuxFoundation
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SharedLiveAgentIndexAgentLivenessTests {
    @Test
    func processScopeFingerprintTracksUnscopedTTYAndGroupMembers() {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 0x123
        let processGroupID = 500
        let makeProcess: (Int, Int, UUID?, UUID?, Int) -> CmuxTopProcessInfo = {
            pid, parentPID, cmuxWorkspaceID, cmuxSurfaceID, processGroupID in
            CmuxTopProcessInfo(
                pid: pid,
                parentPID: parentPID,
                name: "test-\(pid)",
                path: "/usr/bin/test-\(pid)",
                ttyDevice: ttyDevice,
                cmuxWorkspaceID: cmuxWorkspaceID,
                cmuxSurfaceID: cmuxSurfaceID,
                cmuxAttributionReason: cmuxWorkspaceID == nil ? nil : "cmux-test",
                processGroupID: processGroupID,
                terminalProcessGroupID: processGroupID,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )
        }
        let baseProcesses = [
            makeProcess(500, 1, nil, nil, processGroupID),
            makeProcess(501, 500, workspaceId, panelId, processGroupID),
            makeProcess(502, 501, workspaceId, panelId, processGroupID),
        ]
        let base = CmuxTopProcessSnapshot(
            processes: baseProcesses,
            sampledAt: Date(timeIntervalSince1970: 42),
            includesProcessDetails: true
        )
        let withUnscopedSibling = CmuxTopProcessSnapshot(
            processes: baseProcesses + [makeProcess(503, 500, nil, nil, processGroupID + 1)],
            sampledAt: Date(timeIntervalSince1970: 43),
            includesProcessDetails: true
        )

        let baseScope = base.agentHibernationProcessScope(
            panelProcessIDs: [501, 502],
            agentProcessIDs: [501]
        )
        let changedScope = withUnscopedSibling.agentHibernationProcessScope(
            panelProcessIDs: [501, 502],
            agentProcessIDs: [501]
        )
        #expect(baseScope.containsUnrelatedProcess == false)
        #expect(changedScope.containsUnrelatedProcess)
        #expect(
            SharedLiveAgentIndexLoader.processScopeFingerprint(
                from: base,
                hibernationProcessScopes: [
                    RestorableAgentSessionIndex.PanelKey(
                        workspaceId: workspaceId,
                        panelId: panelId
                    ): baseScope,
                ]
            ) !=
                SharedLiveAgentIndexLoader.processScopeFingerprint(
                    from: withUnscopedSibling,
                    hibernationProcessScopes: [
                        RestorableAgentSessionIndex.PanelKey(
                            workspaceId: workspaceId,
                            panelId: panelId
                        ): changedScope,
                    ]
                )
        )
    }

    @Test
    func loaderPreservesCompleteHibernationScopeForWrappedAgentProcess() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-scope-loader-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let workspaceId = UUID()
        let panelId = UUID()
        let agentId = "scope-aware-agent"
        let sessionId = "scope-aware-session"
        let shellPID = 7_600
        let agentPID = 7_601
        let childPID = 7_602
        let ttyDevice: Int64 = 0x123
        let processGroupID = shellPID
        let executable = "/usr/local/bin/\(agentId)"
        let registration = CmuxVaultAgentRegistration(
            id: agentId,
            name: "Scope Aware Agent",
            detect: CmuxVaultAgentDetectRule(processNames: [agentId]),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}",
            forkCommand: "{{executable}} --session {{sessionId}} --fork"
        )
        let registry = CmuxVaultAgentRegistry(registrations: [registration])
        let processInfo: (Int, Int, String, String?) -> CmuxTopProcessInfo = {
            pid, parentPID, name, path in
            CmuxTopProcessInfo(
                pid: pid,
                parentPID: parentPID,
                name: name,
                path: path,
                ttyDevice: ttyDevice,
                cmuxWorkspaceID: workspaceId,
                cmuxSurfaceID: panelId,
                cmuxAttributionReason: "cmux-test",
                processGroupID: processGroupID,
                terminalProcessGroupID: processGroupID,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )
        }
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                processInfo(shellPID, 1, "zsh", "/bin/zsh"),
                processInfo(agentPID, shellPID, agentId, executable),
                processInfo(childPID, agentPID, "agent-child", "/bin/true"),
            ],
            sampledAt: Date(timeIntervalSince1970: 42),
            includesProcessDetails: true
        )
        let identities = [
            shellPID: AgentPIDProcessIdentity(pid: pid_t(shellPID), startSeconds: 40, startMicroseconds: 1),
            agentPID: AgentPIDProcessIdentity(pid: pid_t(agentPID), startSeconds: 41, startMicroseconds: 2),
            childPID: AgentPIDProcessIdentity(pid: pid_t(childPID), startSeconds: 42, startMicroseconds: 3),
        ]
        let result = SharedLiveAgentIndexLoader(
            homeDirectory: root.path,
            fileManager: fm,
            registry: registry,
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { 42 },
            processArgumentsProvider: { pid in
                guard pid == agentPID else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [executable, "--session", sessionId],
                    environment: [
                        "PWD": root.path,
                        "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                        "CMUX_SURFACE_ID": panelId.uuidString,
                    ]
                )
            },
            processIdentityProvider: { identities[$0] }
        ).loadResultSynchronously()

        let entry = result.index.entry(workspaceId: workspaceId, panelId: panelId)
        #expect(entry?.processIDs == Set([shellPID, agentPID, childPID]))
        #expect(entry?.terminationProcessIDs == Set([shellPID, agentPID, childPID]))
        #expect(entry?.containsUnrelatedProcess == false)
    }

    @Test
    func forkAvailabilityIgnoresDeadUnrelatedPanelChildProcess() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-agent-liveness-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        let agentId = "forkable-liveness-agent"
        let sessionId = "live-session"
        let agentPID = 7_286
        let childPID = 7_287
        let agentIdentity = AgentPIDProcessIdentity(pid: pid_t(agentPID), startSeconds: 42, startMicroseconds: 7)
        let childIdentity = AgentPIDProcessIdentity(pid: pid_t(childPID), startSeconds: 43, startMicroseconds: 8)
        let executable = "/usr/local/bin/\(agentId)"
        let registry = CmuxVaultAgentRegistry(registrations: [
            CmuxVaultAgentRegistration(
                id: agentId,
                name: "Forkable Liveness Agent",
                detect: CmuxVaultAgentDetectRule(processNames: [agentId]),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "{{executable}} --session {{sessionId}}",
                forkCommand: "{{executable}} --session {{sessionId}} --fork"
            ),
        ])
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: agentPID,
                    parentPID: 1,
                    name: agentId,
                    path: executable,
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                ),
                CmuxTopProcessInfo(
                    pid: childPID,
                    parentPID: agentPID,
                    name: "short-lived-child",
                    path: "/bin/true",
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 42),
            includesProcessDetails: true
        )
        let processArguments = OSAllocatedUnfairLock(initialState: CmuxTopProcessArguments(
            arguments: [executable, "--session", sessionId],
            environment: [
                "PWD": cwd.path,
                "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                "CMUX_SURFACE_ID": panelId.uuidString,
            ]
        ))
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: registry,
                    processSnapshotProvider: { processSnapshot },
                    capturedAtProvider: { 42 },
                    processArgumentsProvider: { pid in
                        guard pid == agentPID else { return nil }
                        return processArguments.withLock { $0 }
                    },
                    processIdentityProvider: { pid in
                        [agentPID: agentIdentity, childPID: childIdentity][pid]
                    }
                )
                .loadResultSynchronously()
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)

        #expect(sharedIndex.index?.processIDs(workspaceId: workspaceId, panelId: panelId) == Set([agentPID, childPID]))
        #expect(sharedIndex.index?.processIdentities(
            workspaceId: workspaceId,
            panelId: panelId
        ) == [agentPID: agentIdentity, childPID: childIdentity])
        #expect(sharedIndex.index?.agentProcessIDs(workspaceId: workspaceId, panelId: panelId) == Set([agentPID]))
        #expect(sharedIndex.index?.agentProcessIdentities(workspaceId: workspaceId, panelId: panelId) == [agentPID: agentIdentity])
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId
        )

        processArguments.withLock {
            $0 = CmuxTopProcessArguments(
                arguments: [executable, "--session", sessionId],
                environment: [
                    "PWD": cwd.path,
                    "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                    "CMUX_SURFACE_ID": UUID().uuidString,
                ]
            )
        }
        _ = await sharedIndex.indexRefreshingNow()
        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(
            !sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId),
            "An async validation pass should stop an agent PID that moved to another panel from keeping the old panel forkable."
        )
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil)
    }

    @Test
    func forkAvailabilityReadsUseCachedValidationWithoutProcessInspection() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-agent-read-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let workspaceId = UUID()
        let panelId = UUID()
        let agentId = "forkable-read-cache-agent"
        let sessionId = "read-cache-session"
        let agentPID = 7_388
        let executable = "/usr/local/bin/\(agentId)"
        let identity = AgentPIDProcessIdentity(pid: pid_t(agentPID), startSeconds: 51, startMicroseconds: 9)
        let registry = CmuxVaultAgentRegistry(registrations: [
            CmuxVaultAgentRegistration(
                id: agentId,
                name: "Forkable Read Cache Agent",
                detect: CmuxVaultAgentDetectRule(processNames: [agentId]),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "{{executable}} --session {{sessionId}}",
                forkCommand: "{{executable}} --session {{sessionId}} --fork"
            ),
        ])
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: agentPID,
                    parentPID: 1,
                    name: agentId,
                    path: executable,
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 51),
            includesProcessDetails: true
        )
        let processArgumentReads = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: registry,
                    processSnapshotProvider: { processSnapshot },
                    capturedAtProvider: { 51 },
                    processArgumentsProvider: { pid in
                        guard pid == agentPID else { return nil }
                        processArgumentReads.withLock { $0 += 1 }
                        return CmuxTopProcessArguments(
                            arguments: [executable, "--session", sessionId],
                            environment: [
                                "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                                "CMUX_SURFACE_ID": panelId.uuidString,
                            ]
                        )
                    },
                    processIdentityProvider: { pid in
                        pid == agentPID ? identity : nil
                    }
                )
                .loadResultSynchronously()
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(processArgumentReads.withLock { $0 } > 0)

        processArgumentReads.withLock { $0 = 0 }
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId)
        #expect(
            processArgumentReads.withLock { $0 } == 0,
            "Fork availability reads should use the cached off-main validation result."
        )
    }

    @Test
    func forkAvailabilityValidationUsesPanelFallbackAfterWorkspaceMove() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-agent-panel-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let originalWorkspaceId = UUID()
        let movedWorkspaceId = UUID()
        let panelId = UUID()
        let agentId = "forkable-panel-fallback-agent"
        let sessionId = "panel-fallback-session"
        let agentPID = 7_489
        let executable = "/usr/local/bin/\(agentId)"
        let identity = AgentPIDProcessIdentity(pid: pid_t(agentPID), startSeconds: 61, startMicroseconds: 4)
        let registry = CmuxVaultAgentRegistry(registrations: [
            CmuxVaultAgentRegistration(
                id: agentId,
                name: "Forkable Panel Fallback Agent",
                detect: CmuxVaultAgentDetectRule(processNames: [agentId]),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "{{executable}} --session {{sessionId}}",
                forkCommand: "{{executable}} --session {{sessionId}} --fork"
            ),
        ])
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: agentPID,
                    parentPID: 1,
                    name: agentId,
                    path: executable,
                    ttyDevice: nil,
                    cmuxWorkspaceID: originalWorkspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 61),
            includesProcessDetails: true
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: registry,
                    processSnapshotProvider: { processSnapshot },
                    capturedAtProvider: { 61 },
                    processArgumentsProvider: { pid in
                        guard pid == agentPID else { return nil }
                        return CmuxTopProcessArguments(
                            arguments: [executable, "--session", sessionId],
                            environment: [
                                "CMUX_WORKSPACE_ID": originalWorkspaceId.uuidString,
                                "CMUX_SURFACE_ID": panelId.uuidString,
                            ]
                        )
                    },
                    processIdentityProvider: { pid in
                        pid == agentPID ? identity : nil
                    }
                )
                .loadResultSynchronously()
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: originalWorkspaceId, panelId: panelId)

        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: movedWorkspaceId, panelId: panelId))
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: movedWorkspaceId, panelId: panelId)?.sessionId
                == sessionId
        )
    }

    @Test
    func cachedAgentProcessIdentityRejectsInheritedScopeAndDifferentSession() {
        let agentId = "forkable-identity-agent"
        let sessionId = "expected-session"
        let executable = "/usr/local/bin/\(agentId)"
        let registration = CmuxVaultAgentRegistration(
            id: agentId,
            name: "Forkable Identity Agent",
            detect: CmuxVaultAgentDetectRule(processNames: [agentId]),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}",
            forkCommand: "{{executable}} --session {{sessionId}} --fork"
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom(agentId),
            sessionId: sessionId,
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: agentId,
                executablePath: executable,
                arguments: [executable, "--session", sessionId],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "process"
            ),
            registration: registration
        )
        let validator = CachedAgentProcessIdentityValidator()

        #expect(
            validator.currentProcess(
                CmuxTopProcessArguments(
                    arguments: [executable, "--session", sessionId],
                    environment: ["CMUX_AGENT_LAUNCH_KIND": agentId]
                ),
                matches: snapshot
            )
        )
        #expect(
            !validator.currentProcess(
                CmuxTopProcessArguments(
                    arguments: ["/bin/zsh"],
                    environment: ["CMUX_AGENT_LAUNCH_KIND": agentId]
                ),
                matches: snapshot
            ),
            "Inherited cmux agent scope is not enough when argv no longer identifies the cached agent."
        )
        #expect(
            !validator.currentProcess(
                CmuxTopProcessArguments(
                    arguments: [executable, "--session", "different-session"],
                    environment: ["CMUX_AGENT_LAUNCH_KIND": agentId]
                ),
                matches: snapshot
            ),
            "A reused PID running the same agent binary for another session must refresh instead of forking stale state."
        )
    }
}

/// A Claude session that is still running when cmux saves its session must be
/// indexed as running, or quit and update-relaunch saves record it as exited
/// and restore skips its automatic resume.
@MainActor
@Suite(.serialized)
struct ClaudeHookSessionLivenessTests {
    private struct Fixture {
        let root: URL
        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = UUID().uuidString.lowercased()
        var transcriptPath: URL { root.appendingPathComponent("\(sessionId).jsonl") }
        var executablePath: String { root.appendingPathComponent("bin/claude").path }
    }

    @Test("A live native Claude hook session is indexed as running")
    func liveNativeClaudeHookSessionIsIndexedAsRunning() throws {
        let fixture = try makeFixture(prefix: "cmux-claude-hook-liveness")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shellPID = 7_700
        let agentPID = 7_701
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                processInfo(fixture: fixture, pid: shellPID, parentPID: 1, name: "zsh", path: "/bin/zsh"),
                processInfo(
                    fixture: fixture,
                    pid: agentPID,
                    parentPID: shellPID,
                    name: "claude",
                    path: fixture.executablePath
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 1_790_627_600),
            includesProcessDetails: true
        )

        let index = SharedLiveAgentIndexLoader(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { 1_790_627_600 },
            processArgumentsProvider: { pid in
                guard pid == agentPID else { return nil }
                return CmuxTopProcessArguments(
                    arguments: liveArguments(fixture: fixture),
                    environment: liveEnvironment(fixture: fixture)
                )
            },
            processIdentityProvider: { pid in pid == agentPID ? identity : nil }
        ).loadSynchronously()

        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.snapshot.kind == .claude)
        #expect(entry.snapshot.sessionId == fixture.sessionId)
        #expect(entry.processLiveness == .running)
    }

    /// A busy Mac always has some process exiting between the PID listing and
    /// the per-process reads. That process is gone, not unreadable, so the census
    /// must stay complete and the live Claude session must stay running.
    @Test("An unrelated process exiting mid-census keeps a live Claude session running")
    func unrelatedProcessExitingMidCensusKeepsClaudeRunning() throws {
        let fixture = try makeFixture(prefix: "cmux-claude-census-churn")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shellPID = 7_800
        let agentPID = 7_801
        let exitedPID = 7_802
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        let reader = ExitingProcessCensusReader(
            processes: [
                .init(pid: shellPID, parentPID: 1, startSeconds: 1_790_627_000, scoped: true),
                .init(
                    pid: agentPID,
                    parentPID: shellPID,
                    startSeconds: identity.startSeconds,
                    startMicroseconds: identity.startMicroseconds,
                    scoped: true
                ),
                .init(pid: exitedPID, parentPID: 1, startSeconds: 1_790_627_100, scoped: false),
            ],
            exitedPID: exitedPID,
            workspaceId: fixture.workspaceId,
            panelId: fixture.panelId
        )
        let sampler = CmuxTopProcessSampler(reader: reader)
        let processSnapshot = try sampler.enrich(sampler.capture(), fields: [.details, .scope]).snapshot
        #expect(processSnapshot.enumerationIsComplete)
        #expect(processSnapshot.process(pid: exitedPID) == nil)

        let index = SharedLiveAgentIndexLoader(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { processSnapshot.sampledAt.timeIntervalSince1970 },
            processArgumentsProvider: { pid in
                guard pid == agentPID, processSnapshot.process(pid: pid) != nil else { return nil }
                return CmuxTopProcessArguments(
                    arguments: liveArguments(fixture: fixture),
                    environment: liveEnvironment(fixture: fixture)
                )
            },
            processIdentityProvider: { pid in pid == agentPID ? identity : nil }
        ).loadSynchronously()

        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.snapshot.sessionId == fixture.sessionId)
        #expect(entry.processLiveness == .running)
    }

    private func makeFixture(prefix: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        let fixture = Fixture(root: root)
        try """
        {"type":"user","sessionId":"\(fixture.sessionId)","cwd":"\(root.path)","message":{"role":"user","content":"hello"}}

        """.write(to: fixture.transcriptPath, atomically: true, encoding: .utf8)
        return fixture
    }

    /// The argv a cmux-wrapped native Claude install runs with.
    private func liveArguments(fixture: Fixture) -> [String] {
        [fixture.executablePath, "--session-id", fixture.sessionId, "--settings", "{}"]
    }

    private func liveEnvironment(fixture: Fixture) -> [String: String] {
        [
            "CMUX_WORKSPACE_ID": fixture.workspaceId.uuidString,
            "CMUX_TAB_ID": fixture.workspaceId.uuidString,
            "CMUX_SURFACE_ID": fixture.panelId.uuidString,
            "CMUX_PANEL_ID": fixture.panelId.uuidString,
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": fixture.executablePath,
            "CLAUDE_CONFIG_DIR": fixture.root.path,
            "PWD": fixture.root.path,
        ]
    }

    /// Mirrors what `cmux claude-hook` records for a running session.
    private func writeHookRecord(fixture: Fixture, identity: AgentPIDProcessIdentity) throws {
        let now = Date().timeIntervalSince1970
        let record: [String: Any] = [
            "sessionId": fixture.sessionId,
            "workspaceId": fixture.workspaceId.uuidString,
            "surfaceId": fixture.panelId.uuidString,
            "cwd": fixture.root.path,
            "transcriptPath": fixture.transcriptPath.path,
            "pid": Int(identity.pid),
            "pidStartSeconds": identity.startSeconds,
            "pidStartMicroseconds": identity.startMicroseconds,
            "hookEventName": "PreToolUse",
            "agentLifecycle": "running",
            "isRestorable": true,
            "lastPermissionMode": "auto",
            "startedAt": now,
            "updatedAt": now,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": fixture.executablePath,
                "arguments": [fixture.executablePath],
                "workingDirectory": fixture.root.path,
                "environment": ["CLAUDE_CONFIG_DIR": fixture.root.path],
                "capturedAt": now,
                "source": "environment",
            ],
        ]
        let stateDirectory = fixture.root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let store: [String: Any] = ["version": 1, "sessions": [fixture.sessionId: record]]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateDirectory.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)
    }

    private func processInfo(
        fixture: Fixture,
        pid: Int,
        parentPID: Int,
        name: String,
        path: String
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: name,
            path: path,
            ttyDevice: 0x123,
            cmuxWorkspaceID: fixture.workspaceId,
            cmuxSurfaceID: fixture.panelId,
            cmuxAttributionReason: "cmux-test",
            processGroupID: parentPID == 1 ? pid : parentPID,
            terminalProcessGroupID: parentPID == 1 ? pid : parentPID,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }
}

/// A census in which one listed process exits before enrichment reads it.
private struct ExitingProcessCensusReader: CmuxTopProcessReading {
    struct ListedProcess {
        let pid: Int
        let parentPID: Int
        let startSeconds: Int64
        var startMicroseconds: Int64 = 0
        let scoped: Bool
    }

    let processes: [ListedProcess]
    let exitedPID: Int
    let workspaceId: UUID
    let panelId: UUID

    func enumerate() -> DarwinProcessListing {
        DarwinProcessListing(
            processes: processes.map { process in
                var info = proc_bsdinfo()
                info.pbi_pid = UInt32(process.pid)
                info.pbi_ppid = UInt32(process.parentPID)
                info.pbi_pgid = UInt32(process.pid)
                info.pbi_start_tvsec = UInt64(process.startSeconds)
                info.pbi_start_tvusec = UInt64(process.startMicroseconds)
                return info
            },
            isComplete: true,
            missingProcessCount: 0
        )
    }

    func taskInfo(for pid: Int) -> proc_taskinfo? { nil }
    func resourceUsage(for pid: Int) -> rusage_info_v4? { nil }
    func processName(pid: Int, fallback: String) -> String { fallback }
    func processPath(pid: Int) -> String? { nil }

    func scope(for pid: Int, key: CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScope? {
        guard pid != exitedPID, processes.first(where: { $0.pid == pid })?.scoped == true else { return nil }
        return CmuxTopProcessScope(workspaceID: workspaceId, surfaceID: panelId, attributionReason: "cmux-test")
    }

    func matches(pid: Int, key: CmuxTopProcessScopeCacheKey) -> Bool { pid != exitedPID }
    func processHasExited(pid: Int) -> Bool { pid == exitedPID }
}
