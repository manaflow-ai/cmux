import CMUXAgentLaunch
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
                    fileManager: .default,
                    registry: registry,
                    processSnapshotProvider: { processSnapshot },
                    capturedAtProvider: { 42 },
                    processArgumentsProvider: { pid in
                        guard pid == agentPID else { return nil }
                        return processArguments.withLock { $0 }
                    },
                    processIdentityProvider: { pid in
                        pid == agentPID ? agentIdentity : nil
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
                    fileManager: .default,
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
                    fileManager: .default,
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
