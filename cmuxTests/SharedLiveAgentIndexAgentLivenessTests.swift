import Dispatch
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
    func hookStoreWatcherIgnoresUnrelatedDirectoryWrites() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-hook-store-filter-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let hookStoreURL = root.appendingPathComponent("claude-hook-sessions.json")
        try Data("{\"sessions\":{}}".utf8).write(to: hookStoreURL, options: .atomic)

        let loadStarted = DispatchSemaphore(value: 0)
        let loadCompleted = DispatchSemaphore(value: 0)
        var now = Date(timeIntervalSince1970: 100)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadStarted.signal()
                return Self.loadResult(index: .empty)
            },
            hookStoreDirectoryProvider: { root.path },
            dateProvider: { now }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .sharedLiveAgentIndexDidChange,
            object: sharedIndex,
            queue: nil
        ) { _ in
            loadCompleted.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sharedIndex.scheduleRefreshIfStale()
        #expect(await Self.wait(for: loadStarted))
        #expect(await Self.wait(for: loadCompleted))

        now.addTimeInterval(10)
        try Data("event\n".utf8).write(
            to: root.appendingPathComponent("events.jsonl"),
            options: .atomic
        )

        let unrelatedWriteStartedLoad = await Self.wait(for: loadStarted, timeout: 0.5)
        #expect(
            !unrelatedWriteStartedLoad,
            "Writes outside *-hook-sessions.json must not reload the expensive live-agent index."
        )
        guard !unrelatedWriteStartedLoad else { return }

        try Data("{\"sessions\":{},\"revision\":1}".utf8).write(
            to: hookStoreURL,
            options: .atomic
        )
        #expect(await Self.wait(for: loadStarted))
        #expect(await Self.wait(for: loadCompleted))
    }

    @Test
    func hookStoreReloadCadenceScalesWithIndexedHistory() async throws {
        let index = Self.index(entryCount: 270)
        try await Self.expectNoHookStoreReload(
            within: 10,
            for: index,
            fixtureName: "indexed-history"
        )
    }

    @Test
    func hookStoreReloadCadenceScalesWithDistinctLiveAgentProcesses() async throws {
        let index = Self.index(liveAgentProcessIDs: Set(1...64))
        try await Self.expectNoHookStoreReload(
            within: 10,
            for: index,
            fixtureName: "live-processes"
        )
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

    private static func expectNoHookStoreReload(
        within elapsed: TimeInterval,
        for index: RestorableAgentSessionIndex,
        fixtureName: String
    ) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-hook-cadence-\(fixtureName)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let hookStoreURL = root.appendingPathComponent("claude-hook-sessions.json")
        try Data("{\"sessions\":{}}".utf8).write(to: hookStoreURL, options: .atomic)

        let loadStarted = DispatchSemaphore(value: 0)
        let loadCompleted = DispatchSemaphore(value: 0)
        var now = Date(timeIntervalSince1970: 100)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadStarted.signal()
                return Self.loadResult(index: index)
            },
            hookStoreDirectoryProvider: { root.path },
            dateProvider: { now }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .sharedLiveAgentIndexDidChange,
            object: sharedIndex,
            queue: nil
        ) { _ in
            loadCompleted.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sharedIndex.scheduleRefreshIfStale()
        #expect(await Self.wait(for: loadStarted))
        #expect(await Self.wait(for: loadCompleted))

        now.addTimeInterval(elapsed)
        try Data("{\"sessions\":{},\"revision\":1}".utf8).write(
            to: hookStoreURL,
            options: .atomic
        )

        #expect(
            !(await Self.wait(for: loadStarted, timeout: 0.5)),
            "Large hook-store workloads must use the 30-second reload cadence."
        )
    }

    nonisolated private static func loadResult(
        index: RestorableAgentSessionIndex
    ) -> SharedLiveAgentIndexLoader.LoadResult {
        (
            index: index,
            liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
    }

    nonisolated private static func index(entryCount: Int) -> RestorableAgentSessionIndex {
        var detected: [
            RestorableAgentSessionIndex.PanelKey:
                RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry
        ] = [:]
        for ordinal in 0..<entryCount {
            detected[
                RestorableAgentSessionIndex.PanelKey(
                    workspaceId: UUID(),
                    panelId: UUID()
                )
            ] = (
                snapshot: SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: "indexed-history-\(ordinal)",
                    workingDirectory: "/tmp/cmux-indexed-history",
                    launchCommand: nil
                ),
                updatedAt: TimeInterval(ordinal),
                processIDs: [],
                agentProcessIDs: [],
                sessionIDSource: .explicit
            )
        }
        return Self.index(detectedSnapshots: detected)
    }

    nonisolated private static func index(
        liveAgentProcessIDs: Set<Int>
    ) -> RestorableAgentSessionIndex {
        let key = RestorableAgentSessionIndex.PanelKey(
            workspaceId: UUID(),
            panelId: UUID()
        )
        return Self.index(detectedSnapshots: [
            key: (
                snapshot: SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: "live-process-workload",
                    workingDirectory: "/tmp/cmux-live-process-workload",
                    launchCommand: nil
                ),
                updatedAt: 1,
                processIDs: liveAgentProcessIDs,
                agentProcessIDs: liveAgentProcessIDs,
                sessionIDSource: .explicit
            ),
        ])
    }

    nonisolated private static func index(
        detectedSnapshots: [
            RestorableAgentSessionIndex.PanelKey:
                RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry
        ]
    ) -> RestorableAgentSessionIndex {
        RestorableAgentSessionIndex.load(
            homeDirectory: "/tmp/cmux-hook-cadence-missing-home",
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { _ in nil }
        )
    }

    nonisolated private static func wait(
        for semaphore: DispatchSemaphore,
        timeout: TimeInterval = 2
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            semaphore.wait(timeout: .now() + timeout) == .success
        }.value
    }
}
