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
