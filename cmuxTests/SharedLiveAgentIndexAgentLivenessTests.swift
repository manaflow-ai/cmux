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
        let isAgentScopedToPanel = OSAllocatedUnfairLock(initialState: true)
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
                        return CmuxTopProcessArguments(
                            arguments: [executable, "--session", sessionId],
                            environment: ["PWD": cwd.path]
                        )
                    }
                )
                .loadResultSynchronously()
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            processIsRunningProvider: {
                $0 == agentPID
            },
            processMatchesCachedAgentProvider: { pid, scopedWorkspaceId, scopedPanelId, snapshot in
                isAgentScopedToPanel.withLock { isScoped in
                    isScoped
                        && pid == agentPID
                        && scopedWorkspaceId == workspaceId
                        && scopedPanelId == panelId
                        && snapshot.sessionId == sessionId
                }
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)

        #expect(sharedIndex.index?.processIDs(workspaceId: workspaceId, panelId: panelId) == Set([agentPID, childPID]))
        #expect(sharedIndex.index?.agentProcessIDs(workspaceId: workspaceId, panelId: panelId) == Set([agentPID]))
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId
        )

        isAgentScopedToPanel.withLock { $0 = false }
        #expect(
            !sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId),
            "An alive agent PID that moved to another panel must not keep the old panel forkable."
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
