import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private actor AsyncTestBarrier {
    private let expectedCount: Int
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func wait() async {
        if waitingContinuations.count + 1 == expectedCount {
            let continuations = waitingContinuations
            waitingContinuations.removeAll(keepingCapacity: false)
            for continuation in continuations {
                continuation.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }
}

@MainActor
@Suite(.serialized)
struct WorkspaceForkConversationContextMenuTests {
    @Test
    func panelContextMenuActionUsesClickedPanel() async throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)
        let otherPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: true))
        #expect(workspace.focusedPanelId == otherPanel.id)

        let didForkFromClickedPanel = await workspace.forkAgentConversationFromContextMenu(
            fromPanelId: sourcePanelId,
            destination: .newTab
        )
        #expect(didForkFromClickedPanel)

        #expect(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count == 3,
            "Fork Conversation from the terminal context menu should fork the clicked panel"
        )
        #expect(
            workspace.bonsplitController.allPaneIds.count == 1,
            "New Tab destination should stay in the clicked panel's pane"
        )
    }

    @Test
    func liveAgentIndexLoaderUsesProcessDetectedPanelWhenHookBindingIsStale() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-live-agent-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)

        let agentId = "forkable-test-agent"
        let sessionId = "live-session"
        let staleWorkspaceId = UUID()
        let stalePanelId = UUID()
        let liveWorkspaceId = UUID()
        let livePanelId = UUID()
        let processId = 7_286
        let executable = "/usr/local/bin/\(agentId)"
        let registry = CmuxVaultAgentRegistry(registrations: [
            CmuxVaultAgentRegistration(
                id: agentId,
                name: "Forkable Test Agent",
                detect: CmuxVaultAgentDetectRule(processNames: [agentId]),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "{{executable}} --session {{sessionId}}",
                forkCommand: "{{executable}} --session {{sessionId}} --fork"
            ),
        ])
        try writeCustomAgentHookStore(
            root: root,
            agentId: agentId,
            sessions: [
                sessionId: customAgentHookRecord(
                    agentId: agentId,
                    sessionId: sessionId,
                    workspaceId: staleWorkspaceId,
                    panelId: stalePanelId,
                    cwd: cwd.path,
                    executable: executable,
                    updatedAt: 10
                ),
            ]
        )

        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: processId,
                    parentPID: 1,
                    name: agentId,
                    path: executable,
                    ttyDevice: nil,
                    cmuxWorkspaceID: liveWorkspaceId,
                    cmuxSurfaceID: livePanelId,
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
        let loader = SharedLiveAgentIndexLoader(
            homeDirectory: root.path,
            fileManager: fm,
            registry: registry,
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { 42 },
            processArgumentsProvider: { pid in
                guard pid == processId else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [executable, "--session", sessionId],
                    environment: ["PWD": cwd.path]
                )
            }
        )
        let index = loader.loadSynchronously()
        #expect(index.snapshot(workspaceId: staleWorkspaceId, panelId: stalePanelId) == nil)

        let snapshot = try #require(
            index.snapshot(workspaceId: liveWorkspaceId, panelId: livePanelId),
            "The live process scope should make the current panel forkable even when the hook record still points at an old panel."
        )
        #expect(snapshot.sessionId == sessionId)
        #expect(snapshot.forkCommand != nil)
        #expect(
            ContentView.commandPaletteSnapshotForkAvailability(snapshot) == .supportedWithoutProbe
        )
        #expect(index.processIDs(workspaceId: liveWorkspaceId, panelId: livePanelId) == Set([processId]))
    }

    @Test
    func forkAvailabilitySnapshotRefreshesWhenProcessScopeChanges() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-live-agent-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)

        let agentId = "forkable-cache-agent"
        let sessionId = "live-session"
        let staleWorkspaceId = UUID()
        let stalePanelId = UUID()
        let liveWorkspaceId = UUID()
        let livePanelId = UUID()
        let processId = 7_287
        let processIdentity = AgentPIDProcessIdentity(pid: pid_t(processId), startSeconds: 43, startMicroseconds: 7)
        let executable = "/usr/local/bin/\(agentId)"
        let registry = CmuxVaultAgentRegistry(registrations: [
            CmuxVaultAgentRegistration(
                id: agentId,
                name: "Forkable Cache Agent",
                detect: CmuxVaultAgentDetectRule(processNames: [agentId]),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "{{executable}} --session {{sessionId}}",
                forkCommand: "{{executable}} --session {{sessionId}} --fork"
            ),
        ])
        try writeCustomAgentHookStore(
            root: root,
            agentId: agentId,
            sessions: [
                sessionId: customAgentHookRecord(
                    agentId: agentId,
                    sessionId: sessionId,
                    workspaceId: staleWorkspaceId,
                    panelId: stalePanelId,
                    cwd: cwd.path,
                    executable: executable,
                    updatedAt: 10
                ),
            ]
        )

        let processSnapshotLock = OSAllocatedUnfairLock(initialState: CmuxTopProcessSnapshot(
            processes: [],
            sampledAt: Date(timeIntervalSince1970: 42),
            includesProcessDetails: true
        ))
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let snapshot = processSnapshotLock.withLock { $0 }
                return SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    fileManager: .default,
                    registry: registry,
                    processSnapshotProvider: { snapshot },
                    capturedAtProvider: { snapshot.sampledAt.timeIntervalSince1970 },
                    processArgumentsProvider: { pid in
                        pid == processId
                            ? CmuxTopProcessArguments(arguments: [executable, "--session", sessionId], environment: ["PWD": cwd.path])
                            : nil
                    },
                    processIdentityProvider: { $0 == processId ? processIdentity : nil }
                )
                .loadResultSynchronously()
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: staleWorkspaceId, panelId: stalePanelId)
        #expect(
            sharedIndex.index?.snapshot(
                workspaceId: staleWorkspaceId,
                panelId: stalePanelId
            )?.sessionId == sessionId
        )

        processSnapshotLock.withLock {
            $0 = CmuxTopProcessSnapshot(
                processes: [
                    CmuxTopProcessInfo(
                        pid: processId,
                        parentPID: 1,
                        name: agentId,
                        path: executable,
                        ttyDevice: nil,
                        cmuxWorkspaceID: liveWorkspaceId,
                        cmuxSurfaceID: livePanelId,
                        cmuxAttributionReason: "cmux-test",
                        processGroupID: nil,
                        terminalProcessGroupID: nil,
                        cpuPercent: 0,
                        residentBytes: 0,
                        virtualBytes: 0,
                        threadCount: 1
                    ),
                ],
                sampledAt: Date(timeIntervalSince1970: 43),
                includesProcessDetails: true
            )
        }

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: staleWorkspaceId, panelId: stalePanelId)
        #expect(
            sharedIndex.snapshotForForkAvailability(
                workspaceId: staleWorkspaceId,
                panelId: stalePanelId
            ) == nil
        )
        await sharedIndex.refreshForkAvailabilityNow(workspaceId: liveWorkspaceId, panelId: livePanelId)
        #expect(
            sharedIndex.snapshotForForkAvailability(
                workspaceId: liveWorkspaceId,
                panelId: livePanelId
            )?.sessionId == sessionId
        )
    }

    @Test
    func forkAvailabilityProbeFailsClosedWhileSharedIndexRefreshes() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-live-agent-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)

        let agentId = "forkable-probe-agent"
        let sessionId = "probe-session"
        let workspaceId = UUID()
        let panelId = UUID()
        let executable = "/usr/local/bin/\(agentId)"
        let registry = CmuxVaultAgentRegistry(registrations: [
            CmuxVaultAgentRegistration(
                id: agentId,
                name: "Forkable Probe Agent",
                detect: CmuxVaultAgentDetectRule(processNames: [agentId]),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "{{executable}} --session {{sessionId}}",
                forkCommand: "{{executable}} --session {{sessionId}} --fork"
            ),
        ])
        try writeCustomAgentHookStore(
            root: root,
            agentId: agentId,
            sessions: [
                sessionId: customAgentHookRecord(
                    agentId: agentId,
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    executable: executable,
                    updatedAt: 10
                ),
            ]
        )

        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let sampledAt = now.withLock { $0 }
                return SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: registry,
                    processSnapshotProvider: {
                        CmuxTopProcessSnapshot(
                            processes: [],
                            sampledAt: sampledAt,
                            includesProcessDetails: true
                        )
                    },
                    capturedAtProvider: { sampledAt.timeIntervalSince1970 },
                    processArgumentsProvider: { _ in nil }
                )
                .loadResultSynchronously()
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: {
                now.withLock { $0 }
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId)?.sessionId
                == sessionId
        )

        now.withLock { $0 = Date(timeIntervalSince1970: 1) }
        #expect(
            sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId),
            "A completed fork probe should stay briefly usable without another process scan."
        )

        now.withLock { $0 = Date(timeIntervalSince1970: 16) }
        #expect(
            sharedIndex.snapshotForForkConversationCandidate(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId
        )
        #expect(
            !sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId),
            "Fork availability must fail closed once the panel-specific probe expires."
        )
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil)
    }

    @Test
    func forkAvailabilityProbeRefreshesMissingPanelSnapshotInsideCacheWindow() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-live-agent-missing-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    processSnapshotProvider: {
                        CmuxTopProcessSnapshot(processes: [], sampledAt: now.withLock { $0 }, includesProcessDetails: true)
                    },
                    capturedAtProvider: { now.withLock { $0 }.timeIntervalSince1970 },
                    processArgumentsProvider: { _ in nil }
                )
                .loadResultSynchronously()
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: {
                now.withLock { $0 }
            }
        )

        now.withLock { $0 = Date(timeIntervalSince1970: 30) }
        let missingWorkspaceId = UUID()
        let missingPanelId = UUID()
        await sharedIndex.refreshForkAvailabilityNow(workspaceId: missingWorkspaceId, panelId: missingPanelId)
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: missingWorkspaceId, panelId: missingPanelId))

        let unvalidatedWorkspaceId = UUID()
        let unvalidatedPanelId = UUID()
        #expect(
            !sharedIndex.prepareForkAvailabilityProbe(workspaceId: unvalidatedWorkspaceId, panelId: unvalidatedPanelId),
            "A missing panel snapshot should trigger an off-main refresh even inside the cache window."
        )
    }

    @Test
    func contextMenuAvailabilityReportsHiddenReasons() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        #expect(
            workspace.forkAgentConversationContextMenuAvailability(forPanelId: panelId) == .noAgentSnapshot
        )
        #expect(
            workspace.forkAgentConversationContextMenuAvailability(forPanelId: UUID()) == .notTerminalPanel
        )

        workspace.setRestoredAgentSnapshotForTesting(makeProbeRequiredOpenCodeSnapshot(), panelId: panelId)
        #expect(
            workspace.forkAgentConversationContextMenuAvailability(forPanelId: panelId) == .requiresProbe
        )
        #expect(!workspace.canForkAgentConversationFromPanel(panelId))
        #expect(WorkspaceForkAgentConversationAvailability.agentIndexRefreshing.diagnosticReason == "agent_index_refreshing")
    }

    @Test
    func nativePiSnapshotRequiresCapabilityProbeFromPanelContextMenu() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let sessionId = "pi-session-123"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: sessionId,
            workingDirectory: "/tmp/pi repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "/opt/homebrew/bin/pi",
                arguments: ["/opt/homebrew/bin/pi", "--session", sessionId],
                workingDirectory: "/tmp/pi repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelId)

        #expect(snapshot.forkCommand != nil)
        #expect(
            workspace.forkAgentConversationContextMenuAvailability(forPanelId: panelId) == .requiresProbe
        )
        #expect(!workspace.canForkAgentConversationFromPanel(panelId))
        #expect(
            ContentView.commandPaletteSnapshotForkAvailability(snapshot, isRemoteTerminal: true)
                == .unsupported
        )
    }

    @Test
    func piFamilyCapabilityProbeUsesCoreVersionThresholds() {
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("0.60.0", agentID: "pi"))
        #expect(AgentForkSupport.piFamilyVersionSupportsFork("0.60.0", agentID: "pi", acceptsBareVersionOutput: true))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("0.59.9", agentID: "pi", acceptsBareVersionOutput: true))
        #expect(AgentForkSupport.piFamilyVersionSupportsFork("pi 0.60.0", agentID: "pi"))
        #expect(AgentForkSupport.piFamilyVersionSupportsFork("pi:v0.60.0", agentID: "pi"))
        #expect(AgentForkSupport.piFamilyVersionSupportsFork("omp/13.15.0", agentID: "omp"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("0.60.0-beta.1", agentID: "pi", acceptsBareVersionOutput: true))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("pi 0.60.0-beta.1", agentID: "pi"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("omp/13.15.0-rc.1", agentID: "omp"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("omp/13.14.2", agentID: "omp"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("v22.1.0", agentID: "pi"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("warning: pi requires node v22.1.0\n0.59.9", agentID: "pi"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("warning: node v22.1.0; pi 0.59.9", agentID: "pi"))
        #expect(AgentForkSupport.piFamilyVersionSupportsFork("warning: node v22.1.0; pi 0.60.0", agentID: "pi"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("node v22.1.0\npi 0.59.9", agentID: "pi"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("node v22.1.0; omp/13.14.2", agentID: "omp"))
        #expect(AgentForkSupport.piFamilyVersionSupportsFork("node v22.1.0; omp/13.15.0", agentID: "omp"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("node v22.1.0\nomp/13.14.2", agentID: "omp"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("16.5.2", agentID: "unknown"))
    }

    @Test
    func forkTimeoutResumeGateResumesOnlyFirstClaim() async {
        let value: String = await withCheckedContinuation { continuation in
            let gate = AgentForkTimeoutResumeGate(continuation)

            #expect(gate.resume(returning: "timeout"))
            #expect(!gate.resume(returning: "task"))
        }

        #expect(value == "timeout")
    }

    @Test
    func commandPaletteForkSnapshotFingerprintChangesWithLaunchEnvironment() {
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "pi",
            executablePath: "/usr/local/bin/pi",
            arguments: ["/usr/local/bin/pi", "--session", "pi-session"],
            workingDirectory: "/tmp/repo",
            environment: ["PI_CONFIG_DIR": "supported"],
            capturedAt: 123,
            source: "process"
        )
        let first = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-session",
            workingDirectory: "/tmp/repo",
            launchCommand: launchCommand
        )
        var second = first
        second.launchCommand?.environment = ["PI_CONFIG_DIR": "unsupported"]

        #expect(
            ContentView.commandPaletteForkSnapshotFingerprint(first)
                != ContentView.commandPaletteForkSnapshotFingerprint(second)
        )
    }

    @Test
    func commandPaletteForkAvailabilitySnapshotSourcePrefersLiveIndexOverRestoredFallback() throws {
        let liveSnapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: "/tmp/live-pi-repo",
            executablePath: "/usr/local/bin/pi"
        )
        let staleFallback = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "stale-opencode-session",
            workingDirectory: "/tmp/stale-opencode-repo",
            executablePath: "/usr/local/bin/opencode"
        )
        let liveFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(liveSnapshot)
        let fallbackFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(staleFallback)
        #expect(liveFingerprint != fallbackFingerprint)

        let liveSource = try #require(
            ContentView.commandPaletteForkAvailabilitySnapshotSource(
                liveIndexSnapshot: liveSnapshot,
                fallbackSnapshot: staleFallback
            )
        )
        #expect(liveSource.snapshot.sessionId == liveSnapshot.sessionId)
        #expect(liveSource.snapshot.launchCommand?.launcher == "pi")
        #expect(liveSource.snapshotFingerprint == liveFingerprint)
        #expect(liveSource.validationFallbackSnapshot == nil)
        #expect(liveSource.validationFallbackFingerprint == nil)
        #expect(!liveSource.resultHadFallback)

        let fallbackSource = try #require(
            ContentView.commandPaletteForkAvailabilitySnapshotSource(
                liveIndexSnapshot: nil,
                fallbackSnapshot: staleFallback
            )
        )
        #expect(fallbackSource.snapshot.sessionId == staleFallback.sessionId)
        #expect(fallbackSource.snapshot.launchCommand?.launcher == "opencode")
        #expect(fallbackSource.snapshotFingerprint == fallbackFingerprint)
        #expect(fallbackSource.validationFallbackSnapshot?.sessionId == staleFallback.sessionId)
        #expect(fallbackSource.validationFallbackFingerprint == fallbackFingerprint)
        #expect(fallbackSource.resultHadFallback)
    }

    @Test
    func commandPaletteImmediateForkExecutionPrefersLiveIndexOverRestoredFallback() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(workspaceId: workspaceId, panelId: panelId)
        let liveSnapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: "/tmp/live-pi-repo",
            executablePath: "/usr/local/bin/pi"
        )
        let staleFallback = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "stale-opencode-session",
            workingDirectory: "/tmp/stale-opencode-repo",
            executablePath: "/usr/local/bin/opencode"
        )
        let liveFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(liveSnapshot)
        #expect(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                liveIndexSnapshot: liveSnapshot,
                fallbackSnapshot: staleFallback,
                cachedSnapshot: liveSnapshot,
                allowsAgentContinuation: true
            )
        )

        let selection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: liveFingerprint],
            liveIndexSnapshot: liveSnapshot,
            fallbackSnapshot: staleFallback,
            cachedSnapshot: liveSnapshot,
            allowsAgentContinuation: true
        )

        #expect(selection?.snapshot.sessionId == liveSnapshot.sessionId)
        #expect(selection?.snapshot.launchCommand?.launcher == "pi")
        #expect(selection?.usedFallbackSnapshot == false)
    }

    @Test
    func commandPaletteImmediateForkExecutionDoesNotPreferUnvalidatedLiveIndexOverRestoredFallback() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-palette-unvalidated-live-restored-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let palettePanelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let staleLiveSnapshot = makeForkableClaudeSnapshot(
            sessionId: "stale-live-claude-session",
            workingDirectory: root.appendingPathComponent("stale", isDirectory: true).path
        )
        let restoredSnapshot = makeForkableClaudeSnapshot(
            sessionId: "restored-current-claude-session",
            workingDirectory: root.appendingPathComponent("restored", isDirectory: true).path
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: staleLiveSnapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            forkSupportProvider: { _, _ in true },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )
        await sharedIndex.refreshForkAvailabilityNow()

        #expect(sharedIndex.index?.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == staleLiveSnapshot.sessionId)
        let validatedLiveSnapshot = sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId)
        #expect(validatedLiveSnapshot == nil)
        let fallbackFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(restoredSnapshot)
        let source = try #require(
            ContentView.commandPaletteForkAvailabilitySnapshotSource(
                liveIndexSnapshot: validatedLiveSnapshot,
                fallbackSnapshot: restoredSnapshot
            )
        )
        #expect(source.snapshot.sessionId == restoredSnapshot.sessionId)
        #expect(source.resultHadFallback)
        #expect(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [palettePanelKey],
                supportedRemoteContextsByPanelKey: [palettePanelKey: false],
                liveIndexSnapshot: validatedLiveSnapshot,
                fallbackSnapshot: restoredSnapshot,
                cachedSnapshot: restoredSnapshot,
                allowsAgentContinuation: true
            )
        )

        let selection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [palettePanelKey],
            supportedRemoteContextsByPanelKey: [palettePanelKey: false],
            snapshotFingerprintsByPanelKey: [palettePanelKey: fallbackFingerprint],
            resultHadFallbackByPanelKey: [palettePanelKey: true],
            liveIndexSnapshot: validatedLiveSnapshot,
            fallbackSnapshot: restoredSnapshot,
            cachedSnapshot: restoredSnapshot,
            allowsAgentContinuation: true
        )
        #expect(selection?.snapshot.sessionId == restoredSnapshot.sessionId)
        #expect(selection?.snapshot.sessionId != staleLiveSnapshot.sessionId)
        #expect(selection?.usedFallbackSnapshot == true)
    }

    @Test
    func commandPaletteForkProbeExecutableFingerprintChangesWhenPathSymlinkRetargets() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-palette-path-fingerprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let releaseOneBin = root
            .appendingPathComponent("release-one", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let releaseTwoBin = root
            .appendingPathComponent("release-two", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: releaseOneBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: releaseTwoBin, withIntermediateDirectories: true)
        try writeExecutableFixture(
            at: releaseOneBin.appendingPathComponent("pi", isDirectory: false),
            output: "pi 0.80.6"
        )
        try writeExecutableFixture(
            at: releaseTwoBin.appendingPathComponent("pi", isDirectory: false),
            output: "pi 0.59.0"
        )
        let current = root.appendingPathComponent("current", isDirectory: true)
        try fm.createSymbolicLink(
            at: current,
            withDestinationURL: root.appendingPathComponent("release-one", isDirectory: true)
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-palette-path-fingerprint",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                arguments: ["pi", "--session", "pi-palette-path-fingerprint"],
                workingDirectory: root.path,
                environment: [
                    "PATH": "\(current.appendingPathComponent("bin", isDirectory: true).path):/usr/bin:/bin",
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let snapshotFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(snapshot)
        let first = await ContentView.commandPaletteForkProbeExecutableFingerprint(snapshot)

        try fm.removeItem(at: current)
        try fm.createSymbolicLink(
            at: current,
            withDestinationURL: root.appendingPathComponent("release-two", isDirectory: true)
        )

        #expect(snapshotFingerprint == ContentView.commandPaletteForkSnapshotFingerprint(snapshot))
        #expect(first != (await ContentView.commandPaletteForkProbeExecutableFingerprint(snapshot)))
    }

    @Test
    func sharedForkProbeExposesExecutableFingerprintValidatedBeforePaletteCaching() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-shared-validated-executable-fingerprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")
        let workspaceId = UUID()
        let panelId = UUID()
        let snapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let sharedIndex = SharedLiveAgentIndex(
            forkSupportProvider: { _, _ in true },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: snapshot
        )

        let validatedFingerprint = try #require(
            sharedIndex.forkSupportProbeExecutableFingerprint(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: snapshot
            )
        )
        #expect(sharedIndex.forkSupportProbeAccepted(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: snapshot
        ))

        try writeExecutableFixture(at: executable, output: "pi 0.59.0-downgraded")

        #expect(validatedFingerprint != ContentView.commandPaletteForkProbeExecutableFingerprintValue(snapshot))
    }

    @Test
    func forkProbeExecutableResolutionSkipsExecutablePathDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-path-directory-skip-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let firstBin = root.appendingPathComponent("first-bin", isDirectory: true)
        let secondBin = root.appendingPathComponent("second-bin", isDirectory: true)
        try fm.createDirectory(
            at: firstBin.appendingPathComponent("pi", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: secondBin, withIntermediateDirectories: true)
        let executable = secondBin.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "path-directory-skip",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                arguments: ["pi", "--session", "path-directory-skip"],
                workingDirectory: root.path,
                environment: [
                    "PATH": "\(firstBin.path):\(secondBin.path):/usr/bin:/bin",
                ],
                capturedAt: 123,
                source: "process"
            )
        )

        let identity = try #require(AgentForkSupport.forkValidationExecutableIdentity(snapshot: snapshot))
        #expect(identity.lookupPath == executable.path)
    }

    @Test
    func commandPaletteProbeRequiredResultClearsOnPanelPresentationChange() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(workspaceId: workspaceId, panelId: panelId)
        let fingerprint = "probe-required-fingerprint"

        #expect(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: true
            ),
            "Probe-required palette positives must clear on panel changes while the async probe recomputes CLI support."
        )
    }

    @Test
    func commandPaletteFallbackProbeResultReusesUntilValidationTTL() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(workspaceId: workspaceId, panelId: panelId)
        let fingerprint = "probe-required-fingerprint"

        #expect(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: true,
                panelChanged: false,
                cachedResultIsFresh: true
            )
        )
        #expect(
            !ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: true,
                panelChanged: false,
                cachedResultIsFresh: true
            )
        )
        #expect(
            !ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: true,
                panelChanged: false,
                cachedResultIsFresh: false
            )
        )
        #expect(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: true,
                panelChanged: false,
                cachedResultIsFresh: false
            )
        )
    }

    @Test
    func commandPaletteRejectedProbeResultReusesUntilValidationTTL() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(workspaceId: workspaceId, panelId: panelId)
        let fingerprint = "rejected-probe-fingerprint"

        #expect(
            !ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: true,
                panelChanged: false,
                cachedResultIsFresh: true
            )
        )
        #expect(
            ContentView.commandPaletteForkableAgentProbeRejectionMatches(
                panelKey: panelKey,
                rejectedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false
            )
        )
        #expect(
            ContentView.commandPaletteForkableAgentProbeResultIsFresh(
                validatedAt: Date(timeIntervalSince1970: 10),
                now: Date(timeIntervalSince1970: 20)
            )
        )
        #expect(
            !ContentView.commandPaletteForkableAgentProbeResultIsFresh(
                validatedAt: Date(timeIntervalSince1970: 10),
                now: Date(
                    timeIntervalSince1970: 10 + ContentView.commandPaletteForkableAgentProbeResultTTL + 1
                )
            )
        )
    }

    @Test
    func commandPaletteProbeResultExpiryUsesNearestFreshValidation() {
        let firstPanelKey = "first-panel"
        let secondPanelKey = "second-panel"
        let now = Date(timeIntervalSince1970: 20)

        #expect(
            ContentView.commandPaletteNextForkableAgentProbeResultExpiry(
                validatedAtByPanelKey: [
                    firstPanelKey: Date(timeIntervalSince1970: 10),
                    secondPanelKey: Date(timeIntervalSince1970: 19),
                ],
                now: now
            ) == Date(timeIntervalSince1970: 10 + ContentView.commandPaletteForkableAgentProbeResultTTL)
        )
        #expect(
            ContentView.commandPaletteNextForkableAgentProbeResultExpiry(
                validatedAtByPanelKey: [
                    firstPanelKey: Date(timeIntervalSince1970: 1),
                ],
                now: now
            ) == nil,
            "An already-expired palette probe result should not schedule a future refresh instead of being pruned immediately."
        )
    }

    @Test
    func commandPaletteImmediateForkRejectsExpiredProbeRequiredResult() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-palette-execution-ttl-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(workspaceId: workspaceId, panelId: panelId)
        let snapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let fingerprint = ContentView.commandPaletteForkSnapshotFingerprint(snapshot)
        let executableFingerprint = ContentView.commandPaletteForkProbeExecutableFingerprintValue(snapshot)

        let freshSelection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            executableFingerprintsByPanelKey: [panelKey: executableFingerprint],
            validatedAtByPanelKey: [panelKey: Date(timeIntervalSince1970: 10)],
            now: Date(timeIntervalSince1970: 20),
            fallbackSnapshot: snapshot,
            cachedSnapshot: nil,
            allowsAgentContinuation: true
        )
        #expect(freshSelection?.usedFallbackSnapshot == true)

        let missingExecutableIdentitySelection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            executableFingerprintsByPanelKey: [:],
            validatedAtByPanelKey: [panelKey: Date(timeIntervalSince1970: 10)],
            now: Date(timeIntervalSince1970: 20),
            fallbackSnapshot: snapshot,
            cachedSnapshot: nil,
            allowsAgentContinuation: true
        )
        #expect(missingExecutableIdentitySelection == nil)

        let staleButFreshCachedExecutableFingerprintSelection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            executableFingerprintsByPanelKey: [panelKey: "stale-executable-fingerprint"],
            validatedAtByPanelKey: [panelKey: Date(timeIntervalSince1970: 10)],
            now: Date(timeIntervalSince1970: 20),
            fallbackSnapshot: snapshot,
            cachedSnapshot: nil,
            allowsAgentContinuation: true
        )
        #expect(
            staleButFreshCachedExecutableFingerprintSelection != nil,
            "The pure selection helper only checks probe TTL and metadata; action execution revalidates current executable identity off the main actor."
        )

        let expiredSelection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            executableFingerprintsByPanelKey: [panelKey: executableFingerprint],
            validatedAtByPanelKey: [panelKey: Date(timeIntervalSince1970: 10)],
            now: Date(
                timeIntervalSince1970: 10 + ContentView.commandPaletteForkableAgentProbeResultTTL + 1
            ),
            fallbackSnapshot: snapshot,
            cachedSnapshot: nil,
            allowsAgentContinuation: true
        )
        #expect(expiredSelection == nil)
    }

    @Test
    func customForkTemplateMustRenderBeforeSupportProbeAcceptsIt() async {
        let registration = CmuxVaultAgentRegistration(
            id: "needs-cwd",
            name: "Needs CWD",
            detect: CmuxVaultAgentDetectRule(processNames: ["needs-cwd"]),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "needs-cwd --session {{sessionId}}",
            forkCommand: "needs-cwd --cwd {{cwd}} --session {{sessionId}} --fork"
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("needs-cwd"),
            sessionId: "needs-cwd-session",
            workingDirectory: nil,
            launchCommand: nil,
            registration: registration
        )

        #expect(snapshot.forkCommand == nil)
        #expect(AgentForkSupport.forkValidationIdentity(snapshot: snapshot) == nil)
        #expect(!(await AgentForkSupport.supportsFork(snapshot: snapshot)))
    }

    @Test
    func forkCapabilityProbeCacheEvictsOldestEntriesPastCapacity() async {
        let cache = AgentForkCapabilityProbeCache(maxEntries: 2)
        await cache.store(true, for: "first", now: 0, expiresAt: 100)
        await cache.store(false, for: "second", now: 0, expiresAt: 100)
        await cache.store(true, for: "third", now: 0, expiresAt: 100)

        #expect(await cache.value(for: "first", now: 1) == nil)
        #expect(await cache.value(for: "second", now: 1) == false)
        #expect(await cache.value(for: "third", now: 1) == true)
    }

    @Test
    func forkCapabilityProbeCacheReinsertedExpiredKeysKeepNewestOrder() async {
        let cache = AgentForkCapabilityProbeCache(maxEntries: 2)
        await cache.store(true, for: "first", now: 0, expiresAt: 100)
        await cache.store(false, for: "second", now: 0, expiresAt: 1)

        #expect(await cache.value(for: "second", now: 2) == nil)

        await cache.store(true, for: "third", now: 2, expiresAt: 100)
        await cache.store(true, for: "second", now: 3, expiresAt: 100)
        await cache.store(false, for: "fourth", now: 4, expiresAt: 100)

        #expect(await cache.value(for: "second", now: 5) == true)
        #expect(await cache.value(for: "third", now: 5) == nil)
        #expect(await cache.value(for: "fourth", now: 5) == false)
    }

    @Test
    func sharedForkProbeCacheInvalidatesWhenPiFamilyLauncherChanges() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pi-family-shared-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("agent-wrapper", isDirectory: false)
        try writeExecutableFixture(at: executable)

        let workspaceId = UUID()
        let panelId = UUID()
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let snapshot = OSAllocatedUnfairLock(initialState: makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        ))
        let probedLaunchers = OSAllocatedUnfairLock(initialState: [String]())

        @Sendable func index(for snapshot: SessionRestorableAgentSnapshot) -> RestorableAgentSessionIndex {
            RestorableAgentSessionIndex.load(
                homeDirectory: root.path,
                fileManager: .default,
                registry: CmuxVaultAgentRegistry(registrations: [
                    CmuxVaultAgentRegistration.builtInPi,
                    CmuxVaultAgentRegistration.builtInOmp,
                ]),
                detectedSnapshots: [
                    RestorableAgentSessionIndex.PanelKey(
                        workspaceId: workspaceId,
                        panelId: panelId
                    ): (
                        snapshot: snapshot,
                        updatedAt: now.withLock { $0.timeIntervalSince1970 },
                        processIDs: [],
                        agentProcessIDs: [],
                        sessionIDSource: .explicit
                    ),
                ]
            )
        }

        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let snapshot = snapshot.withLock { $0 }
                return (
                    index: index(for: snapshot),
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [snapshot.launchCommand?.launcher ?? ""],
                    forkValidatedPanels: [
                        RestorableAgentSessionIndex.PanelKey(
                            workspaceId: workspaceId,
                            panelId: panelId
                        ),
                    ]
                )
            },
            forkSupportProvider: { snapshot, _ in
                let launcher = snapshot.launchCommand?.launcher ?? ""
                probedLaunchers.withLock { $0.append(launcher) }
                return launcher == "pi"
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: {
                now.withLock { $0 }
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId)?
                .launchCommand?.launcher == "pi"
        )
        #expect(probedLaunchers.withLock { $0 } == ["pi"])

        let ompSnapshot = makePiFamilySnapshot(
            launcher: "omp",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        snapshot.withLock { $0 = ompSnapshot }
        now.withLock { $0 = Date(timeIntervalSince1970: 1) }
        await sharedIndex.refreshForkAvailabilityNow()

        #expect(
            sharedIndex.snapshotForForkConversationCandidate(workspaceId: workspaceId, panelId: panelId)?
                .launchCommand?.launcher == "omp"
        )
        #expect(
            !sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId),
            "A Pi probe result must not make an OMP snapshot fresh just because the rendered fork command is unchanged."
        )
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil)

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(probedLaunchers.withLock { $0 } == ["pi", "omp"])
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil)
    }

    @Test
    func sharedForkProbeKeepsUnresolvedExecutableRejectionFreshUntilTTL() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-unresolved-fork-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let missingExecutable = root.appendingPathComponent("missing-pi", isDirectory: false)
        let snapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: missingExecutable.path
        )
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let loaderCallCount = OSAllocatedUnfairLock(initialState: 0)
        let providerCallCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loaderCallCount.withLock { $0 += 1 }
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: now.withLock { $0.timeIntervalSince1970 },
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            forkSupportProvider: { _, _ in
                providerCallCount.withLock { $0 += 1 }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: {
                now.withLock { $0 }
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(sharedIndex.forkSupportProbeRejected(workspaceId: workspaceId, panelId: panelId))
        #expect(providerCallCount.withLock { $0 } == 0)
        let loaderCallsAfterProbe = loaderCallCount.withLock { $0 }

        #expect(
            sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId),
            "An unresolved executable rejection should be fresh until the probe TTL instead of requeueing immediately."
        )
        #expect(loaderCallCount.withLock { $0 } == loaderCallsAfterProbe)
    }

    @Test
    func sharedForkProbeCoalescesDuplicateRequestsWhileValidationIsActive() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-active-probe-coalesce-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let snapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: [.builtInPi]),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            forkSupportProvider: { _, _ in
                probeCount.withLock { $0 += 1 }
                try? await Task.sleep(nanoseconds: 150_000_000)
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        async let refresh: Void = sharedIndex.refreshForkAvailabilityNow(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: snapshot
        )
        while probeCount.withLock({ $0 }) == 0 {
            await Task.yield()
        }
        let duplicateReturned = OSAllocatedUnfairLock(initialState: false)
        async let duplicateRefresh: Void = {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: snapshot
            )
            duplicateReturned.withLock { $0 = true }
        }()
        await Task.yield()
        #expect(!duplicateReturned.withLock { $0 })
        #expect(!sharedIndex.prepareForkAvailabilityProbe(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: snapshot
        ))
        #expect(!sharedIndex.prepareForkAvailabilityProbe(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: snapshot
        ))
        _ = await refresh
        _ = await duplicateRefresh

        #expect(sharedIndex.forkSupportProbeAccepted(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: snapshot
        ))
        #expect(probeCount.withLock { $0 } == 1)
    }

    @Test
    func sharedForkProbeWaitsForDuplicatePendingValidation() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pending-probe-coalesce-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let snapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let loaderStarted = OSAllocatedUnfairLock(initialState: false)
        let releaseLoader = OSAllocatedUnfairLock(initialState: false)
        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loaderStarted.withLock { $0 = true }
                while !releaseLoader.withLock({ $0 }) {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: [.builtInPi]),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            forkSupportProvider: { _, _ in
                probeCount.withLock { $0 += 1 }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        sharedIndex.scheduleRefreshIfStale(validating: panelKey)
        while !loaderStarted.withLock({ $0 }) {
            await Task.yield()
        }
        let duplicateReturned = OSAllocatedUnfairLock(initialState: false)
        async let duplicateRefresh: Void = {
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
            duplicateReturned.withLock { $0 = true }
        }()
        await Task.yield()
        #expect(!duplicateReturned.withLock { $0 })

        releaseLoader.withLock { $0 = true }
        _ = await duplicateRefresh

        #expect(sharedIndex.forkSupportProbeAccepted(workspaceId: workspaceId, panelId: panelId))
        #expect(probeCount.withLock { $0 } == 1)
    }

    @Test
    func sharedForkProbeSeparatesLiveAndFallbackRequestsForSamePanel() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-live-fallback-probe-batches-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let liveSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "live-index-request",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let fallbackSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "restored-fallback-request",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let loaderStarted = OSAllocatedUnfairLock(initialState: false)
        let releaseLoader = OSAllocatedUnfairLock(initialState: false)
        let probedSessionIds = OSAllocatedUnfairLock(initialState: [String]())
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loaderStarted.withLock { $0 = true }
                while !releaseLoader.withLock({ $0 }) {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: liveSnapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            forkSupportProvider: { snapshot, _ in
                probedSessionIds.withLock { $0.append(snapshot.sessionId) }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        sharedIndex.scheduleRefreshIfStale(validating: panelKey)
        for _ in 0..<1000 where !loaderStarted.withLock({ $0 }) {
            await Task.yield()
        }
        #expect(loaderStarted.withLock { $0 })

        await sharedIndex.refreshForkAvailabilityNow(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: fallbackSnapshot
        )
        #expect(probedSessionIds.withLock { $0 } == ["restored-fallback-request"])
        #expect(sharedIndex.forkSupportProbeAccepted(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: fallbackSnapshot
        ))

        releaseLoader.withLock { $0 = true }
        for _ in 0..<10_000 where !probedSessionIds.withLock({ $0.contains("live-index-request") }) {
            await Task.yield()
        }

        #expect(probedSessionIds.withLock { $0 } == [
            "restored-fallback-request",
            "live-index-request",
        ])
        #expect(sharedIndex.forkSupportProbeAccepted(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
    func sharedForkProbeDoesNotCoalesceMatchingIdentityAcrossPanels() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-cross-panel-probe-coalesce-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")

        let firstWorkspaceId = UUID()
        let firstPanelId = UUID()
        let secondWorkspaceId = UUID()
        let secondPanelId = UUID()
        let firstPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId
        )
        let secondPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId
        )
        let snapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: [.builtInPi]),
                    detectedSnapshots: [
                        firstPanelKey: (
                            snapshot: snapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                        secondPanelKey: (
                            snapshot: snapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [firstPanelKey, secondPanelKey]
                )
            },
            forkSupportProvider: { _, _ in
                probeCount.withLock { $0 += 1 }
                try? await Task.sleep(nanoseconds: 150_000_000)
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        async let firstRefresh: Void = sharedIndex.refreshForkAvailabilityNow(
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId,
            fallbackSnapshot: snapshot
        )
        while probeCount.withLock({ $0 }) == 0 {
            await Task.yield()
        }
        async let secondRefresh: Void = sharedIndex.refreshForkAvailabilityNow(
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId,
            fallbackSnapshot: snapshot
        )

        _ = await firstRefresh
        _ = await secondRefresh

        #expect(sharedIndex.forkSupportProbeAccepted(
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId,
            fallbackSnapshot: snapshot
        ))
        #expect(sharedIndex.forkSupportProbeAccepted(
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId,
            fallbackSnapshot: snapshot
        ))
        #expect(probeCount.withLock { $0 } == 2)
    }

    @Test
    func cancelledSharedForkProbeRefreshDoesNotRemoveOtherPendingPanel() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pending-probe-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)

        let firstWorkspaceId = UUID()
        let firstPanelId = UUID()
        let firstPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId
        )
        let secondWorkspaceId = UUID()
        let secondPanelId = UUID()
        let secondPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId
        )
        let firstSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "first-pending-probe",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let secondSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "second-pending-probe",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let loaderCallCount = OSAllocatedUnfairLock(initialState: 0)
        let loaderStartedCount = OSAllocatedUnfairLock(initialState: 0)
        let firstLoaderRelease = DispatchSemaphore(value: 0)
        let secondLoaderRelease = DispatchSemaphore(value: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let call = loaderCallCount.withLock { count in
                    count += 1
                    return count
                }
                loaderStartedCount.withLock { count in
                    count = max(count, call)
                }
                if call == 1 {
                    firstLoaderRelease.wait()
                } else if call == 2 {
                    secondLoaderRelease.wait()
                }
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        firstPanelKey: (
                            snapshot: firstSnapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                        secondPanelKey: (
                            snapshot: secondSnapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [firstPanelKey, secondPanelKey]
                )
            },
            forkSupportProvider: { _, _ in true },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        let firstRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId
            )
        }
        for _ in 0..<1000 where loaderStartedCount.withLock({ $0 }) < 1 {
            await Task.yield()
        }
        #expect(loaderStartedCount.withLock { $0 } >= 1)

        let secondRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: secondWorkspaceId,
                panelId: secondPanelId
            )
        }
        for _ in 0..<1000 where loaderStartedCount.withLock({ $0 }) < 2 {
            await Task.yield()
        }
        #expect(loaderStartedCount.withLock { $0 } >= 2)

        secondRefresh.cancel()
        secondLoaderRelease.signal()
        await secondRefresh.value
        firstLoaderRelease.signal()
        await firstRefresh.value

        #expect(
            sharedIndex.snapshotForForkAvailability(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId
            )?.sessionId == "first-pending-probe",
            "Cancelling one refresh must not remove another caller's pending probe before the surviving reload applies it."
        )
        #expect(
            sharedIndex.snapshotForForkAvailability(
                workspaceId: secondWorkspaceId,
                panelId: secondPanelId
            ) == nil
        )
    }

    @Test
    func sharedForkProbeFallbackWaitsForActiveSamePanelValidation() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pending-fallback-wait-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)

        let workspaceId = UUID()
        let panelId = UUID()
        let firstFallback = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "first-fallback",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let secondFallback = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "second-fallback",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let loaderCallCount = OSAllocatedUnfairLock(initialState: 0)
        let providerStartedCount = OSAllocatedUnfairLock(initialState: 0)
        let firstProviderRelease = OSAllocatedUnfairLock(initialState: false)
        let secondProviderRelease = OSAllocatedUnfairLock(initialState: false)
        let secondRefreshFinished = OSAllocatedUnfairLock(initialState: false)
        let probedSessionIds = OSAllocatedUnfairLock(initialState: [String]())
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loaderCallCount.withLock { $0 += 1 }
                return (
                    index: RestorableAgentSessionIndex.load(
                        homeDirectory: root.path,
                        fileManager: fm,
                        registry: CmuxVaultAgentRegistry(registrations: []),
                        detectedSnapshots: [:]
                    ),
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            forkSupportProvider: { snapshot, _ in
                let call = providerStartedCount.withLock { count in
                    count += 1
                    return count
                }
                probedSessionIds.withLock { $0.append(snapshot.sessionId) }
                while !Task.isCancelled {
                    let released = if call == 1 {
                        firstProviderRelease.withLock { $0 }
                    } else {
                        secondProviderRelease.withLock { $0 }
                    }
                    if released {
                        break
                    }
                    await Task.yield()
                }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        let firstRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: firstFallback
            )
        }
        for _ in 0..<1000 where providerStartedCount.withLock({ $0 }) < 1 {
            await Task.yield()
        }
        #expect(providerStartedCount.withLock { $0 } >= 1)

        let secondRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: secondFallback
            )
            secondRefreshFinished.withLock { $0 = true }
        }
        for _ in 0..<1000 where providerStartedCount.withLock({ $0 }) < 2
            && !secondRefreshFinished.withLock({ $0 }) {
            await Task.yield()
        }
        #expect(providerStartedCount.withLock { $0 } == 1)
        #expect(
            !secondRefreshFinished.withLock { $0 },
            "A same-panel fallback refresh must wait for the active validation instead of returning before its queued request runs."
        )

        firstProviderRelease.withLock { $0 = true }
        for _ in 0..<1000 where providerStartedCount.withLock({ $0 }) < 2 {
            await Task.yield()
        }
        #expect(providerStartedCount.withLock { $0 } == 2)
        #expect(!secondRefreshFinished.withLock { $0 })
        secondProviderRelease.withLock { $0 = true }
        await firstRefresh.value
        await secondRefresh.value

        #expect(loaderCallCount.withLock { $0 } == 0)
        #expect(probedSessionIds.withLock { $0 } == ["first-fallback", "second-fallback"])
        #expect(
            sharedIndex.forkSupportProbeAccepted(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: secondFallback
            ),
            "The queued same-panel fallback request must be validated before refreshForkAvailabilityNow returns."
        )
    }

    @Test
    func sharedForkProbeActiveWaitPreservesLaterQueuedValidationBatches() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pending-active-wait-batches-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)

        let firstWorkspaceId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000041"))
        let firstPanelId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000051"))
        let firstPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId
        )
        let secondWorkspaceId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000042"))
        let secondPanelId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000052"))
        let secondPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId
        )
        let firstSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "first-active-wait-batch",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let secondSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "second-active-wait-batch",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let loaderCallCount = OSAllocatedUnfairLock(initialState: 0)
        let blockedLoaderCount = OSAllocatedUnfairLock(initialState: 0)
        let releaseBlockedLoaders = DispatchSemaphore(value: 0)
        let activeProviderRelease = OSAllocatedUnfairLock(initialState: false)
        let firstProviderBlockCount = OSAllocatedUnfairLock(initialState: 0)
        let probedSessionIds = OSAllocatedUnfairLock(initialState: [String]())
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let call = loaderCallCount.withLock { count in
                    count += 1
                    return count
                }
                if call > 1 {
                    blockedLoaderCount.withLock { $0 += 1 }
                    releaseBlockedLoaders.wait()
                }
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        firstPanelKey: (
                            snapshot: firstSnapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                        secondPanelKey: (
                            snapshot: secondSnapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [firstPanelKey, secondPanelKey]
                )
            },
            forkSupportProvider: { snapshot, _ in
                probedSessionIds.withLock { $0.append(snapshot.sessionId) }
                if snapshot.sessionId == "first-active-wait-batch" {
                    let blockCount = firstProviderBlockCount.withLock { count in
                        count += 1
                        return count
                    }
                    if blockCount == 1 {
                        while !Task.isCancelled && !activeProviderRelease.withLock({ $0 }) {
                            await Task.yield()
                        }
                    }
                }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        let activeRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId
            )
        }
        for _ in 0..<1000 where probedSessionIds.withLock({ $0 }) != ["first-active-wait-batch"] {
            await Task.yield()
        }
        #expect(probedSessionIds.withLock { $0 } == ["first-active-wait-batch"])

        let collidingRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId
            )
        }
        for _ in 0..<1000 where blockedLoaderCount.withLock({ $0 }) < 1 {
            await Task.yield()
        }
        let laterRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: secondWorkspaceId,
                panelId: secondPanelId
            )
        }
        for _ in 0..<1000 where blockedLoaderCount.withLock({ $0 }) < 2 {
            await Task.yield()
        }
        releaseBlockedLoaders.signal()
        releaseBlockedLoaders.signal()

        for _ in 0..<1000 where firstProviderBlockCount.withLock({ $0 }) < 1 {
            await Task.yield()
        }
        #expect(probedSessionIds.withLock { $0 } == ["first-active-wait-batch"])

        activeProviderRelease.withLock { $0 = true }
        await activeRefresh.value
        await collidingRefresh.value
        await laterRefresh.value

        #expect(probedSessionIds.withLock { $0 }.contains("second-active-wait-batch"))
        #expect(
            sharedIndex.snapshotForForkAvailability(
                workspaceId: secondWorkspaceId,
                panelId: secondPanelId
            )?.sessionId == "second-active-wait-batch",
            "Waiting on an active first batch must not drop later queued validation batches."
        )
        #expect(forkValidationCancellationTombstoneCount(in: sharedIndex) == 0)
    }

    @Test
    func cancelledSharedForkProbeRefreshPreservesSurvivingFallbackSnapshot() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pending-fallback-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)

        let workspaceId = UUID()
        let panelId = UUID()
        let firstFallback = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "first-fallback",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let secondFallback = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "second-fallback",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let loaderCallCount = OSAllocatedUnfairLock(initialState: 0)
        let providerStartedCount = OSAllocatedUnfairLock(initialState: 0)
        let firstProviderRelease = OSAllocatedUnfairLock(initialState: false)
        let secondRefreshFinished = OSAllocatedUnfairLock(initialState: false)
        let probedSessionIds = OSAllocatedUnfairLock(initialState: [String]())
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loaderCallCount.withLock { $0 += 1 }
                return (
                    index: RestorableAgentSessionIndex.load(
                        homeDirectory: root.path,
                        fileManager: fm,
                        registry: CmuxVaultAgentRegistry(registrations: []),
                        detectedSnapshots: [:]
                    ),
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            forkSupportProvider: { snapshot, _ in
                providerStartedCount.withLock { $0 += 1 }
                probedSessionIds.withLock { $0.append(snapshot.sessionId) }
                while !Task.isCancelled && !firstProviderRelease.withLock({ $0 }) {
                    await Task.yield()
                }
                return snapshot.sessionId == "first-fallback"
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        let firstRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: firstFallback
            )
        }
        for _ in 0..<1000 where providerStartedCount.withLock({ $0 }) < 1 {
            await Task.yield()
        }
        #expect(providerStartedCount.withLock { $0 } == 1)

        let secondRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: secondFallback
            )
            secondRefreshFinished.withLock { $0 = true }
        }
        for _ in 0..<1000 where !secondRefreshFinished.withLock({ $0 }) {
            await Task.yield()
        }
        #expect(!secondRefreshFinished.withLock { $0 })

        secondRefresh.cancel()
        firstProviderRelease.withLock { $0 = true }
        await firstRefresh.value
        await secondRefresh.value

        #expect(loaderCallCount.withLock { $0 } == 0)
        #expect(probedSessionIds.withLock { $0 } == ["first-fallback"])
        #expect(forkValidationCancellationTombstoneCount(in: sharedIndex) == 0)
        #expect(
            sharedIndex.forkSupportProbeAccepted(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: firstFallback
            ),
            "Cancelling a later same-panel fallback request must not leave its fallback attached to the surviving request."
        )
        #expect(
            !sharedIndex.forkSupportProbeAccepted(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: secondFallback
            )
        )
    }

    @Test
    func cancelledSharedForkProbeRefreshDoesNotReplayCompletedValidation() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pending-probe-replay-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)

        let firstWorkspaceId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let firstPanelId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        let firstPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId
        )
        let secondWorkspaceId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let secondPanelId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        let secondPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId
        )
        let firstSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "first-replay",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let secondSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "second-replay",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let loaderCallCount = OSAllocatedUnfairLock(initialState: 0)
        let loaderStartedCount = OSAllocatedUnfairLock(initialState: 0)
        let firstLoaderRelease = DispatchSemaphore(value: 0)
        let secondProviderRelease = OSAllocatedUnfairLock(initialState: false)
        let probedSessionIds = OSAllocatedUnfairLock(initialState: [String]())
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let call = loaderCallCount.withLock { count in
                    count += 1
                    return count
                }
                loaderStartedCount.withLock { count in
                    count = max(count, call)
                }
                if call == 1 {
                    firstLoaderRelease.wait()
                }
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        firstPanelKey: (
                            snapshot: firstSnapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                        secondPanelKey: (
                            snapshot: secondSnapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [firstPanelKey, secondPanelKey]
                )
            },
            forkSupportProvider: { snapshot, _ in
                probedSessionIds.withLock { $0.append(snapshot.sessionId) }
                if snapshot.sessionId == "second-replay" {
                    while !Task.isCancelled && !secondProviderRelease.withLock({ $0 }) {
                        await Task.yield()
                    }
                }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        let firstRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId
            )
        }
        for _ in 0..<1000 where loaderStartedCount.withLock({ $0 }) < 1 {
            await Task.yield()
        }
        #expect(loaderStartedCount.withLock { $0 } == 1)

        let secondRefresh = Task {
            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: secondWorkspaceId,
                panelId: secondPanelId
            )
        }
        for _ in 0..<1000 where !probedSessionIds.withLock({ $0.contains("second-replay") }) {
            await Task.yield()
        }
        #expect(probedSessionIds.withLock { $0 } == ["first-replay", "second-replay"])

        secondRefresh.cancel()
        secondProviderRelease.withLock { $0 = true }
        await secondRefresh.value
        firstLoaderRelease.signal()
        await firstRefresh.value

        #expect(probedSessionIds.withLock { $0 } == ["first-replay", "second-replay"])
        #expect(forkValidationCancellationTombstoneCount(in: sharedIndex) == 0)
        #expect(
            sharedIndex.snapshotForForkAvailability(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId
            )?.sessionId == "first-replay",
            "Cancelling during a later validation must not restore and replay an already-completed earlier validation."
        )
    }

    private func forkValidationCancellationTombstoneCount(in sharedIndex: SharedLiveAgentIndex) -> Int {
        let indexMirror = Mirror(reflecting: sharedIndex)
        guard let tombstones = indexMirror.children.first(where: {
            $0.label == "cancelledForkValidationRequestIDs"
        })?.value else {
            return 0
        }
        return Mirror(reflecting: tombstones).children.reduce(0) { partial, entry in
            let entryMirror = Mirror(reflecting: entry.value)
            guard let cancelledRequestIDs = entryMirror.children.first(where: {
                $0.label == "value"
            })?.value else {
                return partial
            }
            return partial + Mirror(reflecting: cancelledRequestIDs).children.count
        }
    }

    @Test
    func sharedForkProbeBackgroundRefreshRestartsPendingRequestQueuedDuringActiveValidation() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pending-probe-background-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)

        let firstWorkspaceId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000021"))
        let firstPanelId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000031"))
        let firstPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId
        )
        let secondWorkspaceId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000022"))
        let secondPanelId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000032"))
        let secondPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId
        )
        let thirdWorkspaceId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000023"))
        let thirdPanelId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000033"))
        let thirdPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: thirdWorkspaceId,
            panelId: thirdPanelId
        )
        let firstSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "first-background",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let secondSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "second-background",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let thirdSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "third-background",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let loaderCallCount = OSAllocatedUnfairLock(initialState: 0)
        let firstProviderRelease = OSAllocatedUnfairLock(initialState: false)
        let secondProviderRelease = OSAllocatedUnfairLock(initialState: false)
        let probedSessionIds = OSAllocatedUnfairLock(initialState: [String]())
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loaderCallCount.withLock { $0 += 1 }
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        firstPanelKey: (
                            snapshot: firstSnapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                        secondPanelKey: (
                            snapshot: secondSnapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                        thirdPanelKey: (
                            snapshot: thirdSnapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [firstPanelKey, secondPanelKey, thirdPanelKey]
                )
            },
            forkSupportProvider: { snapshot, _ in
                probedSessionIds.withLock { $0.append(snapshot.sessionId) }
                if snapshot.sessionId == "first-background" {
                    while !Task.isCancelled && !firstProviderRelease.withLock({ $0 }) {
                        await Task.yield()
                    }
                } else if snapshot.sessionId == "second-background" {
                    while !Task.isCancelled && !secondProviderRelease.withLock({ $0 }) {
                        await Task.yield()
                    }
                }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        #expect(!sharedIndex.prepareForkAvailabilityProbe(workspaceId: firstWorkspaceId, panelId: firstPanelId))
        for _ in 0..<1000 where !probedSessionIds.withLock({ $0.contains("first-background") }) {
            await Task.yield()
        }
        #expect(probedSessionIds.withLock { $0 } == ["first-background"])

        #expect(!sharedIndex.prepareForkAvailabilityProbe(workspaceId: secondWorkspaceId, panelId: secondPanelId))
        for _ in 0..<1000 where probedSessionIds.withLock({ $0.count }) != 1 {
            await Task.yield()
        }
        #expect(probedSessionIds.withLock { $0 } == ["first-background"])

        firstProviderRelease.withLock { $0 = true }
        for _ in 0..<1000 where !probedSessionIds.withLock({ $0.contains("second-background") }) {
            await Task.yield()
        }

        #expect(probedSessionIds.withLock { $0 } == ["first-background", "second-background"])
        #expect(!sharedIndex.prepareForkAvailabilityProbe(workspaceId: thirdWorkspaceId, panelId: thirdPanelId))
        for _ in 0..<1000 where probedSessionIds.withLock({ $0.count }) != 2 {
            await Task.yield()
        }
        #expect(probedSessionIds.withLock { $0 } == ["first-background", "second-background"])

        secondProviderRelease.withLock { $0 = true }
        for _ in 0..<1000 where !probedSessionIds.withLock({ $0.contains("third-background") }) {
            await Task.yield()
        }

        #expect(probedSessionIds.withLock { $0 } == ["first-background", "second-background", "third-background"])
        #expect(loaderCallCount.withLock { $0 } >= 3)
        #expect(
            sharedIndex.snapshotForForkAvailability(
                workspaceId: thirdWorkspaceId,
                panelId: thirdPanelId
            )?.sessionId == "third-background",
            "A request queued while a restarted background validation is active must restart after that task clears."
        )
    }

    @Test
    func sharedForkProbeFallbackValidationDoesNotReloadLiveIndex() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fallback-probe-no-index-reload-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)

        let workspaceId = UUID()
        let panelId = UUID()
        let fallbackSnapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "fallback-no-index-reload",
            workingDirectory: root.path,
            executablePath: executable.path
        )
        let loaderCallCount = OSAllocatedUnfairLock(initialState: 0)
        let providerCallCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loaderCallCount.withLock { $0 += 1 }
                return (
                    index: RestorableAgentSessionIndex.load(
                        homeDirectory: root.path,
                        fileManager: fm,
                        registry: CmuxVaultAgentRegistry(registrations: []),
                        detectedSnapshots: [:]
                    ),
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            forkSupportProvider: { _, _ in
                providerCallCount.withLock { $0 += 1 }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: fallbackSnapshot
        )

        #expect(loaderCallCount.withLock { $0 } == 0)
        #expect(providerCallCount.withLock { $0 } == 1)
        #expect(
            sharedIndex.forkSupportProbeAccepted(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: fallbackSnapshot
            )
        )
    }

    @Test
    func sharedForkProbeRevalidatesUnresolvedExecutableAfterTTL() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-unresolved-fork-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let providerCallCount = OSAllocatedUnfairLock(initialState: 0)
        let snapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: root.appendingPathComponent("missing-pi", isDirectory: false).path
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: [.builtInPi]),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: now.withLock { $0.timeIntervalSince1970 },
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            forkSupportProvider: { _, _ in
                providerCallCount.withLock { $0 += 1 }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: {
                now.withLock { $0 }
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)

        #expect(providerCallCount.withLock { $0 } == 0)
        #expect(sharedIndex.forkSupportProbeRejected(workspaceId: workspaceId, panelId: panelId))
        #expect(
            sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId),
            "An unresolved executable rejection should stay fresh until the probe TTL expires."
        )
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil)

        try """
        #!/bin/sh
        printf '%s\\n' 'pi 0.80.6'
        """
            .write(to: root.appendingPathComponent("missing-pi", isDirectory: false), atomically: false, encoding: .utf8)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.appendingPathComponent("missing-pi", isDirectory: false).path
        )

        now.withLock { $0 = Date(timeIntervalSince1970: 16) }
        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(providerCallCount.withLock { $0 } == 1)
        #expect(sharedIndex.forkSupportProbeAccepted(workspaceId: workspaceId, panelId: panelId))
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) != nil)
    }

    @Test
    func sharedForkProbeCachePrunesClosedPanelsBeforeReuse() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-validation-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let includePanel = OSAllocatedUnfairLock(initialState: true)
        let processScopeGeneration = OSAllocatedUnfairLock(initialState: 0)
        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)
        let snapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "closed-panel-validation",
            workingDirectory: root.path,
            executablePath: executable.path
        )

        @Sendable func indexResult() -> SharedLiveAgentIndexLoader.LoadResult {
            let panelKey = RestorableAgentSessionIndex.PanelKey(
                workspaceId: workspaceId,
                panelId: panelId
            )
            let includePanel = includePanel.withLock { $0 }
            let index = RestorableAgentSessionIndex.load(
                homeDirectory: root.path,
                fileManager: .default,
                registry: CmuxVaultAgentRegistry(registrations: []),
                detectedSnapshots: includePanel ? [
                    panelKey: (
                        snapshot: snapshot,
                        updatedAt: now.withLock { $0.timeIntervalSince1970 },
                        processIDs: [],
                        agentProcessIDs: [],
                        sessionIDSource: .explicit
                    ),
                ] : [:]
            )
            return (
                index: index,
                liveAgentProcessFingerprint: [],
                processScopeFingerprint: ["generation-\(processScopeGeneration.withLock { $0 })"],
                forkValidatedPanels: includePanel ? [panelKey] : []
            )
        }

        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: { indexResult() },
            forkSupportProvider: { _, _ in
                probeCount.withLock { $0 += 1 }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: {
                now.withLock { $0 }
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(probeCount.withLock { $0 } == 1)
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) != nil)

        includePanel.withLock { $0 = false }
        processScopeGeneration.withLock { $0 += 1 }
        now.withLock { $0 = Date(timeIntervalSince1970: 1) }
        await sharedIndex.refreshForkAvailabilityNow()
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil)

        includePanel.withLock { $0 = true }
        processScopeGeneration.withLock { $0 += 1 }
        now.withLock { $0 = Date(timeIntervalSince1970: 2) }
        await sharedIndex.refreshForkAvailabilityNow()
        #expect(
            !sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId),
            "Recreating a panel inside the validation TTL must not reuse a validation from the closed panel."
        )
        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(probeCount.withLock { $0 } == 2)
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) != nil)
    }

    @Test
    func sharedForkProbeValidationInvalidatesWhenExecutableChanges() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-executable-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        let supportedExecutable = root.appendingPathComponent("pi-supported", isDirectory: false)
        let unsupportedExecutable = root.appendingPathComponent("pi-unsupported", isDirectory: false)
        func writePiProbe(_ url: URL, output: String) throws {
            try """
            #!/bin/sh
            printf '%s\\n' '\(output)'
            """
                .write(to: url, atomically: false, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try writePiProbe(supportedExecutable, output: "pi 0.80.6")
        try writePiProbe(unsupportedExecutable, output: "pi 0.59.0")
        try fm.createSymbolicLink(at: executable, withDestinationURL: supportedExecutable)

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-watch-session",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: executable.path,
                arguments: [executable.path, "--session", "pi-watch-session"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: [
                        .builtInPi,
                    ]),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) != nil)

        try fm.removeItem(at: executable)
        try fm.createSymbolicLink(at: executable, withDestinationURL: unsupportedExecutable)
        for _ in 0..<20 {
            if sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil,
            "Swapping the executable symlink should invalidate the outer fork validation before its TTL expires."
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        #expect(sharedIndex.forkSupportProbeRejected(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
    func sharedForkProbeValidationInvalidatesWhenPathDirectorySymlinkRetargets() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-path-symlink-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let releaseOneBin = root
            .appendingPathComponent("release-one", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let releaseTwoBin = root
            .appendingPathComponent("release-two", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: releaseOneBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: releaseTwoBin, withIntermediateDirectories: true)

        func writePiProbe(_ directory: URL, output: String) throws {
            let executable = directory.appendingPathComponent("pi", isDirectory: false)
            try """
            #!/bin/sh
            printf '%s\\n' '\(output)'
            """
                .write(to: executable, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        try writePiProbe(releaseOneBin, output: "pi 0.80.6")
        try writePiProbe(releaseTwoBin, output: "pi 0.59.0")
        let current = root.appendingPathComponent("current", isDirectory: true)
        try fm.createSymbolicLink(
            at: current,
            withDestinationURL: root.appendingPathComponent("release-one", isDirectory: true)
        )

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-path-symlink-session",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                arguments: ["pi", "--session", "pi-path-symlink-session"],
                workingDirectory: root.path,
                environment: [
                    "PATH": "\(current.appendingPathComponent("bin", isDirectory: true).path):/usr/bin:/bin",
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: [
                        .builtInPi,
                    ]),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) != nil)

        try fm.removeItem(at: current)
        try fm.createSymbolicLink(
            at: current,
            withDestinationURL: root.appendingPathComponent("release-two", isDirectory: true)
        )
        for _ in 0..<20 {
            if sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil,
            "Retargeting a symlinked PATH directory should invalidate the shared validation before its TTL expires."
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        #expect(sharedIndex.forkSupportProbeRejected(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
    func sharedForkProbeExecutableWatchResourcePolicyReservesFileDescriptors() {
        #expect((SharedLiveAgentIndex.forkExecutableWatchOpenFlags & O_CLOEXEC) == O_CLOEXEC)
        #expect(
            SharedLiveAgentIndex.forkExecutableWatchSourceCountBudget(
                softFileDescriptorLimit: 128,
                openFileDescriptorCount: 0
            ) == 0
        )
        #expect(
            SharedLiveAgentIndex.forkExecutableWatchSourceCountBudget(
                softFileDescriptorLimit: 256,
                openFileDescriptorCount: 0
            ) == 32
        )
        #expect(
            SharedLiveAgentIndex.forkExecutableWatchSourceCountBudget(
                softFileDescriptorLimit: 1024,
                openFileDescriptorCount: 0
            ) == 64
        )
        #expect(
            SharedLiveAgentIndex.forkExecutableWatchSourceCountBudget(
                softFileDescriptorLimit: 256,
                openFileDescriptorCount: 220
            ) == 0
        )
        #expect(
            SharedLiveAgentIndex.forkExecutableWatchSourceCountBudget(
                softFileDescriptorLimit: 256,
                openFileDescriptorCount: 100,
                pendingReservationCount: 20
            ) == 2
        )
    }

    @Test
    func sharedForkProbeValidationRefreshesBeforeReuseWhenWatchPathBudgetIsExceeded() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-watch-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        var pathDirectories: [String] = []
        for index in 0..<40 {
            let directory = root.appendingPathComponent("path-\(index)", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            pathDirectories.append(directory.path)
        }
        let executable = URL(fileURLWithPath: try #require(pathDirectories.last), isDirectory: true)
            .appendingPathComponent("pi", isDirectory: false)
        func writePiProbe(output: String, modifiedAt: TimeInterval) throws {
            try """
            #!/bin/sh
            printf '%s\\n' '\(output)'
            """
                .write(to: executable, atomically: false, encoding: .utf8)
            try fm.setAttributes(
                [
                    .posixPermissions: 0o755,
                    .modificationDate: Date(timeIntervalSince1970: modifiedAt),
                ],
                ofItemAtPath: executable.path
            )
        }
        try writePiProbe(output: "pi 0.80.6", modifiedAt: 1_000)

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-watch-budget-session",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                arguments: ["pi", "--session", "pi-watch-budget-session"],
                workingDirectory: root.path,
                environment: [
                    "PATH": pathDirectories.joined(separator: ":"),
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: [
                        .builtInPi,
                    ]),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            forkSupportProvider: { _, _ in
                probeCount.withLock { $0 += 1 }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(probeCount.withLock { $0 } == 1)
        #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        #expect(sharedIndex.forkSupportProbeAccepted(workspaceId: workspaceId, panelId: panelId))
        #expect(!sharedIndex.forkSupportProbeRejected(workspaceId: workspaceId, panelId: panelId))
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) != nil,
            "Watch budget exhaustion should not reject a supported agent; the result should instead refresh before reuse."
        )
        for _ in 0..<50 {
            if probeCount.withLock({ $0 }) >= 2 {
                break
            }
            await Task.yield()
        }
        #expect(
            probeCount.withLock { $0 } == 2,
            "Preparing a refresh-before-reuse validation should schedule a replacement probe."
        )

        try writePiProbe(output: "pi 0.59.0-downgraded", modifiedAt: 2_000)
        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(probeCount.withLock { $0 } == 3)
        #expect(sharedIndex.forkSupportProbeAccepted(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
    func sharedForkProbeSharesExecutableWatchAcrossPanelsWithSameExecutable() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-shared-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        let counter = root.appendingPathComponent("probe-count.txt", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s\\n' hit >> '\(counter.path)'
        printf '%s\\n' 'pi 0.80.6'
        """
            .write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let sharedIndex = SharedLiveAgentIndex(
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        for _ in 0..<130 {
            let workspaceId = UUID()
            let panelId = UUID()
            let snapshot = makePiFamilySnapshot(
                launcher: "pi",
                workspaceRoot: root.path,
                executablePath: executable.path
            )

            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: snapshot
            )
            #expect(
                sharedIndex.forkSupportProbeAccepted(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    fallbackSnapshot: snapshot
                ),
                "Panels that resolve the same Pi executable should share one filesystem watch record instead of exhausting the global source budget."
            )
        }

        let probeOutput = (try? String(contentsOf: counter, encoding: .utf8)) ?? ""
        #expect(probeOutput.split(separator: "\n").count == 1)
    }

    @Test
    func sharedForkProbeMergesExecutableWatchForSameExecutable() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-concurrent-shared-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")
        let sharedIndex = SharedLiveAgentIndex(
            forkSupportProvider: { _, _ in true },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )
        let firstWorkspaceId = UUID()
        let firstPanelId = UUID()
        let secondWorkspaceId = UUID()
        let secondPanelId = UUID()
        let firstSnapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let secondSnapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let notifiedPanelKeys = OSAllocatedUnfairLock(initialState: Set<String>())
        let unscopedNotificationCount = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .sharedLiveAgentIndexDidChange,
            object: sharedIndex,
            queue: nil
        ) { notification in
            if let panelIdsByWorkspaceId = notification.userInfo?["panelIdsByWorkspaceId"] as? [UUID: Set<UUID>] {
                notifiedPanelKeys.withLock {
                    for (workspaceId, panelIds) in panelIdsByWorkspaceId {
                        for panelId in panelIds {
                            _ = $0.insert("\(workspaceId.uuidString)|\(panelId.uuidString)")
                        }
                    }
                }
            } else if let workspaceId = notification.userInfo?["workspaceId"] as? UUID,
               let panelId = notification.userInfo?["panelId"] as? UUID {
                notifiedPanelKeys.withLock {
                    _ = $0.insert("\(workspaceId.uuidString)|\(panelId.uuidString)")
                }
            } else {
                unscopedNotificationCount.withLock { $0 += 1 }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        async let firstRefresh: Void = sharedIndex.refreshForkAvailabilityNow(
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId,
            fallbackSnapshot: firstSnapshot
        )
        async let secondRefresh: Void = sharedIndex.refreshForkAvailabilityNow(
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId,
            fallbackSnapshot: secondSnapshot
        )
        _ = await (firstRefresh, secondRefresh)

        #expect(
            sharedIndex.forkSupportProbeAccepted(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId,
                fallbackSnapshot: firstSnapshot
            )
        )
        #expect(
            sharedIndex.forkSupportProbeAccepted(
                workspaceId: secondWorkspaceId,
                panelId: secondPanelId,
                fallbackSnapshot: secondSnapshot
            )
        )

        try writeExecutableFixture(at: executable, output: "pi 0.59.0")
        for _ in 0..<20 {
            if !sharedIndex.forkSupportProbeAccepted(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId,
                fallbackSnapshot: firstSnapshot
            ),
               !sharedIndex.forkSupportProbeAccepted(
                workspaceId: secondWorkspaceId,
                panelId: secondPanelId,
                fallbackSnapshot: secondSnapshot
               ) {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(
            !sharedIndex.forkSupportProbeAccepted(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId,
                fallbackSnapshot: firstSnapshot
            ),
            "A shared executable watch install should keep the first panel attached to invalidation."
        )
        #expect(
            !sharedIndex.forkSupportProbeAccepted(
                workspaceId: secondWorkspaceId,
                panelId: secondPanelId,
                fallbackSnapshot: secondSnapshot
            ),
            "A shared executable watch install should keep the second panel attached to invalidation."
        )
        #expect(unscopedNotificationCount.withLock { $0 } == 0)
        #expect(
            notifiedPanelKeys.withLock { $0 } == Set([
                "\(firstWorkspaceId.uuidString)|\(firstPanelId.uuidString)",
                "\(secondWorkspaceId.uuidString)|\(secondPanelId.uuidString)",
            ]),
            "Shared executable watch invalidation should notify exactly the affected panel keys."
        )
    }

    @Test
    func sharedForkProbeRechecksExecutableWatchBudgetAfterConcurrentOpen() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("cmux-fork-concurrent-watch-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            forkSupportProvider: { _, _ in
                probeCount.withLock { $0 += 1 }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            forkExecutableWatchSourceBudgetProvider: { _ in 3 }
        )

        let firstExecutableDirectory = root.appendingPathComponent("first-bin", isDirectory: true)
        let secondExecutableDirectory = root.appendingPathComponent("second-bin", isDirectory: true)
        try fm.createDirectory(at: firstExecutableDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondExecutableDirectory, withIntermediateDirectories: true)
        let firstExecutable = firstExecutableDirectory.appendingPathComponent("pi", isDirectory: false)
        let secondExecutable = secondExecutableDirectory.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: firstExecutable, output: "pi 0.80.6")
        try writeExecutableFixture(at: secondExecutable, output: "pi 0.80.6")

        let firstWorkspaceId = UUID()
        let firstPanelId = UUID()
        let secondWorkspaceId = UUID()
        let secondPanelId = UUID()
        let firstSnapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: firstExecutable.path
        )
        let secondSnapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: secondExecutable.path
        )

        async let firstRefresh: Void = sharedIndex.refreshForkAvailabilityNow(
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId,
            fallbackSnapshot: firstSnapshot
        )
        async let secondRefresh: Void = sharedIndex.refreshForkAvailabilityNow(
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId,
            fallbackSnapshot: secondSnapshot
        )
        _ = await (firstRefresh, secondRefresh)

        let acceptedResults = [
            sharedIndex.forkSupportProbeAccepted(
                workspaceId: firstWorkspaceId,
                panelId: firstPanelId,
                fallbackSnapshot: firstSnapshot
            ),
            sharedIndex.forkSupportProbeAccepted(
                workspaceId: secondWorkspaceId,
                panelId: secondPanelId,
                fallbackSnapshot: secondSnapshot
            ),
        ]
        #expect(
            acceptedResults.filter { $0 }.count == 2,
            "Only one concurrent watch install should consume a three-source budget; the loser should fall back to a refresh-before-reuse validation."
        )
        #expect(
            probeCount.withLock { $0 } == 2,
            "A validation that loses the post-open budget race should still run the capability probe."
        )
    }

    @Test
    func sharedForkProbeExecutableWatchInvalidationNotifiesRequestingPanelAlias() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-watch-panel-alias-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")
        let currentWorkspaceId = UUID()
        let staleWorkspaceId = UUID()
        let panelId = UUID()
        let currentPanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: currentWorkspaceId,
            panelId: panelId
        )
        let stalePanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: staleWorkspaceId,
            panelId: panelId
        )
        let snapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        currentPanelKey: (
                            snapshot: snapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [stalePanelKey]
                )
            },
            forkSupportProvider: { _, _ in true },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )
        let notifiedPanelKeys = OSAllocatedUnfairLock(initialState: Set<String>())
        let observer = NotificationCenter.default.addObserver(
            forName: .sharedLiveAgentIndexDidChange,
            object: sharedIndex,
            queue: nil
        ) { notification in
            if let panelIdsByWorkspaceId = notification.userInfo?["panelIdsByWorkspaceId"] as? [UUID: Set<UUID>] {
                notifiedPanelKeys.withLock {
                    for (workspaceId, panelIds) in panelIdsByWorkspaceId {
                        for panelId in panelIds {
                            _ = $0.insert("\(workspaceId.uuidString)|\(panelId.uuidString)")
                        }
                    }
                }
                return
            }
            if let workspaceId = notification.userInfo?["workspaceId"] as? UUID,
               let panelId = notification.userInfo?["panelId"] as? UUID {
                notifiedPanelKeys.withLock {
                    _ = $0.insert("\(workspaceId.uuidString)|\(panelId.uuidString)")
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: currentWorkspaceId, panelId: panelId)
        #expect(
            sharedIndex.forkSupportProbeAccepted(workspaceId: currentWorkspaceId, panelId: panelId),
            "A restored workspace should be able to reuse a validation key matched by panel ID."
        )

        try writeExecutableFixture(at: executable, output: "pi 0.59.0")
        for _ in 0..<20 {
            if !sharedIndex.forkSupportProbeAccepted(workspaceId: currentWorkspaceId, panelId: panelId) {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(!sharedIndex.forkSupportProbeAccepted(workspaceId: currentWorkspaceId, panelId: panelId))
        #expect(
            notifiedPanelKeys.withLock { $0 }.contains(
                "\(currentWorkspaceId.uuidString)|\(panelId.uuidString)"
            ),
            "Executable watch invalidation must notify the requesting workspace key, not only the stale resolved validation key."
        )
    }

    @Test
    func sharedForkProbeEvictsExpiredExecutableWatchesBeforeBudgetCheck() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-watch-budget-expiry-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            forkSupportProvider: { _, _ in
                probeCount.withLock { $0 += 1 }
                return true
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: {
                now.withLock { $0 }
            }
        )

        let watchSourceBudget = SharedLiveAgentIndex.forkExecutableWatchSourceCountBudget()
        try #require(
            watchSourceBudget >= 2,
            "This regression needs enough file-descriptor budget to install at least one executable watch."
        )
        let expiredValidationCount = max(1, watchSourceBudget / 2)
        for index in 0..<expiredValidationCount {
            let executableDirectory = root.appendingPathComponent("expired-\(index)", isDirectory: true)
            try fm.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
            let executable = executableDirectory.appendingPathComponent("pi", isDirectory: false)
            try writeExecutableFixture(at: executable, output: "pi 0.80.6")
            let workspaceId = UUID()
            let panelId = UUID()
            let snapshot = makePiFamilySnapshot(
                launcher: "pi",
                workspaceRoot: root.path,
                executablePath: executable.path
            )

            await sharedIndex.refreshForkAvailabilityNow(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: snapshot
            )
            #expect(
                sharedIndex.forkSupportProbeAccepted(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    fallbackSnapshot: snapshot
                )
            )
        }
        #expect(probeCount.withLock { $0 } == expiredValidationCount)

        now.withLock { $0 = Date(timeIntervalSince1970: 20) }
        let executableDirectory = root.appendingPathComponent("current", isDirectory: true)
        try fm.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executable = executableDirectory.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")
        let workspaceId = UUID()
        let panelId = UUID()
        let snapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )

        await sharedIndex.refreshForkAvailabilityNow(
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: snapshot
        )

        #expect(probeCount.withLock { $0 } == expiredValidationCount + 1)
        #expect(
            sharedIndex.forkSupportProbeAccepted(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: snapshot
            ),
            "Expired executable watches must be evicted before the watch-budget check rejects a new validation."
        )
    }

    @Test
    func sharedForkProbeValidationInvalidatesWhenEarlierPathExecutableAppearsForPiAndOmp() async throws {
        struct Scenario {
            let launcher: String
            let kind: RestorableAgentKind
            let registration: CmuxVaultAgentRegistration
            let supportedOutput: String
            let unsupportedOutput: String
        }

        let scenarios = [
            Scenario(
                launcher: "pi",
                kind: .pi,
                registration: .builtInPi,
                supportedOutput: "pi 0.80.6",
                unsupportedOutput: "pi 0.59.0"
            ),
            Scenario(
                launcher: "omp",
                kind: .custom("omp"),
                registration: .builtInOmp,
                supportedOutput: "omp/13.15.0",
                unsupportedOutput: "omp/13.14.2"
            ),
        ]

        let fm = FileManager.default
        for scenario in scenarios {
            let root = fm.temporaryDirectory
                .appendingPathComponent("cmux-\(scenario.launcher)-path-watch-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: root) }
            let earlyPathDirectory = root.appendingPathComponent("early-bin", isDirectory: true)
            let latePathDirectory = root.appendingPathComponent("late-bin", isDirectory: true)
            try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
            try fm.createDirectory(at: earlyPathDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: latePathDirectory, withIntermediateDirectories: true)

            func writeProbe(_ directory: URL, output: String) throws {
                let executable = directory.appendingPathComponent(scenario.launcher, isDirectory: false)
                try """
                #!/bin/sh
                printf '%s\\n' '\(output)'
                """
                    .write(to: executable, atomically: false, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            }

            try writeProbe(latePathDirectory, output: scenario.supportedOutput)

            let workspaceId = UUID()
            let panelId = UUID()
            let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
            let sessionId = "\(scenario.launcher)-path-watch-session"
            let snapshot = SessionRestorableAgentSnapshot(
                kind: scenario.kind,
                sessionId: sessionId,
                workingDirectory: root.path,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: scenario.launcher,
                    executablePath: scenario.launcher,
                    arguments: [scenario.launcher, "--session", sessionId],
                    workingDirectory: root.path,
                    environment: [
                        "PATH": "\(earlyPathDirectory.path):\(latePathDirectory.path):/usr/bin:/bin",
                    ],
                    capturedAt: 123,
                    source: "process"
                ),
                registration: scenario.registration
            )
            let sharedIndex = SharedLiveAgentIndex(
                indexLoader: {
                    let index = RestorableAgentSessionIndex.load(
                        homeDirectory: root.path,
                        fileManager: fm,
                        registry: CmuxVaultAgentRegistry(registrations: [
                            scenario.registration,
                        ]),
                        detectedSnapshots: [
                            panelKey: (
                                snapshot: snapshot,
                                updatedAt: 0,
                                processIDs: [],
                                agentProcessIDs: [],
                                sessionIDSource: .explicit
                            ),
                        ]
                    )
                    return (
                        index: index,
                        liveAgentProcessFingerprint: [],
                        processScopeFingerprint: [],
                        forkValidatedPanels: [panelKey]
                    )
                },
                hookStoreDirectoryProvider: {
                    root.appendingPathComponent(".cmuxterm", isDirectory: true).path
                }
            )

            await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
            #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
            #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) != nil)

            try writeProbe(earlyPathDirectory, output: scenario.unsupportedOutput)
            for _ in 0..<20 {
                if sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(
                sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil,
                "Creating an earlier PATH \(scenario.launcher) should invalidate the shared validation before its TTL expires."
            )

            await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
            #expect(sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
            #expect(sharedIndex.forkSupportProbeRejected(workspaceId: workspaceId, panelId: panelId))
        }
    }

    @Test
    func sharedOpenCodeMissingWorkingDirectoryRejectsValidation() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-opencode-missing-cwd-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let missingWorkingDirectory = root.appendingPathComponent("deleted-working-directory", isDirectory: true).path
        let snapshot = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "opencode-missing-cwd-session",
            workingDirectory: missingWorkingDirectory
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: 0,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(!sharedIndex.forkSupportProbeAccepted(workspaceId: workspaceId, panelId: panelId))
        #expect(!sharedIndex.forkSupportProbeRejected(workspaceId: workspaceId, panelId: panelId))
        #expect(!sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId))
        let supportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        #expect(!supportsFork)
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil,
            "OpenCode snapshots with deleted local cwd should fail closed when the executable identity cannot be watched."
        )
    }

    @Test
    func openCodeValidationIdentityUsesCapturedClaudeConfigDirWithoutMigrationProbe() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let codexAccountsRoot = home.appendingPathComponent(".codex-accounts", isDirectory: true)
        let claudeAccountRoot = codexAccountsRoot.appendingPathComponent("claude", isDirectory: true)
        let accountsRootExisted = fm.fileExists(atPath: codexAccountsRoot.path)
        let claudeRootExisted = fm.fileExists(atPath: claudeAccountRoot.path)
        let uniqueName = "cmux-validation-identity-\(UUID().uuidString)"
        let legacyConfigDir = home
            .appendingPathComponent(".subrouter", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent(uniqueName, isDirectory: true)
        let migratedConfigDir = claudeAccountRoot.appendingPathComponent(uniqueName, isDirectory: true)
        try fm.createDirectory(at: migratedConfigDir, withIntermediateDirectories: true)
        let executableRoot = fm.temporaryDirectory
            .appendingPathComponent("cmux-opencode-identity-\(UUID().uuidString)", isDirectory: true)
        let executable = executableRoot.appendingPathComponent("opencode", isDirectory: false)
        try fm.createDirectory(at: executableRoot, withIntermediateDirectories: true)
        try writeExecutableFixture(at: executable)
        defer {
            try? fm.removeItem(at: executableRoot)
            try? fm.removeItem(at: migratedConfigDir)
            if !claudeRootExisted {
                try? fm.removeItem(at: claudeAccountRoot)
            }
            if !accountsRootExisted {
                try? fm.removeItem(at: codexAccountsRoot)
            }
        }

        let snapshot = makeProbeRequiredOpenCodeSnapshot(
            executablePath: executable.path,
            environment: [
                "CLAUDE_CONFIG_DIR": legacyConfigDir.path,
                "PATH": "/usr/bin:/bin",
            ]
        )
        let identity = try #require(AgentForkSupport.forkValidationIdentity(snapshot: snapshot))

        #expect(identity.contains("CLAUDE_CONFIG_DIR=\(legacyConfigDir.path)"))
        #expect(!identity.contains("CLAUDE_CONFIG_DIR=\(migratedConfigDir.path)"))
    }

    @Test
    func builtInOmpRequiresProbeButProjectForkOverrideDoesNot() {
        let builtIn = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: "omp-session",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omp",
                executablePath: "omp",
                arguments: ["omp", "--session", "omp-session"],
                workingDirectory: nil,
                environment: ["PATH": "/custom/omp/bin:/usr/bin"],
                capturedAt: 123,
                source: "process"
            ),
            registration: .builtInOmp
        )
        #expect(ContentView.commandPaletteSnapshotForkAvailability(builtIn) == .requiresProbe)
        #expect(builtIn.forkCommand?.contains("'PATH=/custom/omp/bin:/usr/bin'") == true)

        var metadataOverride = CmuxVaultAgentRegistration.builtInOmp
        metadataOverride.name = "Project OMP"
        metadataOverride.iconAssetName = "AgentIcons/ProjectOMP"
        let metadataOverridden = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: "omp-session",
            workingDirectory: nil,
            launchCommand: builtIn.launchCommand,
            registration: metadataOverride
        )
        #expect(ContentView.commandPaletteSnapshotForkAvailability(metadataOverridden) == .requiresProbe)

        var projectOverride = CmuxVaultAgentRegistration.builtInOmp
        projectOverride.name = "Project OMP"
        projectOverride.forkCommand = "{{executable}} --branch {{sessionId}}"
        let overridden = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: "omp-session",
            workingDirectory: nil,
            launchCommand: nil,
            registration: projectOverride
        )
        #expect(ContentView.commandPaletteSnapshotForkAvailability(overridden) == .supportedWithoutProbe)
        #expect(
            ContentView.commandPaletteSnapshotForkAvailability(overridden, isRemoteTerminal: true)
                == .supportedWithoutProbe
        )
    }

    @Test
    func piCapabilityProbeFailsClosedWhenSavedDirectoryIsMissing() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pi-capability-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try "#!/bin/sh\nprintf '%s\\n' '0.80.6'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-session",
            workingDirectory: root.appendingPathComponent("deleted-directory").path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: executable.path,
                arguments: [executable.path, "--session", "pi-session"],
                workingDirectory: root.appendingPathComponent("deleted-directory").path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        #expect(
            !(await AgentForkSupport.supportsFork(snapshot: snapshot)),
            "A missing saved cwd must not probe a Pi wrapper from cmux's own process cwd."
        )
        #expect(AgentForkSupport.forkValidationExecutableIdentity(snapshot: snapshot) == nil)
        #expect(!(await AgentForkSupport.supportsFork(snapshot: snapshot, isRemoteContext: true)))

        var relativeExecutableSnapshot = snapshot
        relativeExecutableSnapshot.launchCommand?.executablePath = "./pi"
        relativeExecutableSnapshot.launchCommand?.arguments = ["./pi", "--session", "pi-session"]
        #expect(
            !(await AgentForkSupport.supportsFork(snapshot: relativeExecutableSnapshot)),
            "A missing saved cwd must not probe a relative Pi executable from cmux's own process cwd."
        )
        #expect(AgentForkSupport.forkValidationExecutableIdentity(snapshot: relativeExecutableSnapshot) == nil)

        var relativePathSnapshot = snapshot
        relativePathSnapshot.launchCommand?.executablePath = "pi"
        relativePathSnapshot.launchCommand?.arguments = ["pi", "--session", "pi-session"]
        relativePathSnapshot.launchCommand?.environment = ["PATH": "./bin:/usr/bin:/bin"]
        #expect(
            !(await AgentForkSupport.supportsFork(snapshot: relativePathSnapshot)),
            "A missing saved cwd must not probe relative PATH entries from cmux's own process cwd."
        )
        #expect(AgentForkSupport.forkValidationExecutableIdentity(snapshot: relativePathSnapshot) == nil)

        let absoluteBin = root.appendingPathComponent("absolute-bin", isDirectory: true)
        try fileManager.createDirectory(at: absoluteBin, withIntermediateDirectories: true)
        let absolutePathPi = absoluteBin.appendingPathComponent("pi", isDirectory: false)
        try "#!/bin/sh\nprintf '%s\\n' '0.80.6'\n"
            .write(to: absolutePathPi, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: absolutePathPi.path)
        var absolutePathBeforeRelativeSnapshot = snapshot
        absolutePathBeforeRelativeSnapshot.launchCommand?.executablePath = "pi"
        absolutePathBeforeRelativeSnapshot.launchCommand?.arguments = ["pi", "--session", "pi-session"]
        absolutePathBeforeRelativeSnapshot.launchCommand?.environment = [
            "PATH": "\(absoluteBin.path):./bin:/usr/bin:/bin",
        ]
        #expect(
            !(await AgentForkSupport.supportsFork(snapshot: absolutePathBeforeRelativeSnapshot)),
            "A missing saved cwd must fail closed even when an absolute PATH hit precedes cwd-dependent entries."
        )
        #expect(AgentForkSupport.forkValidationExecutableIdentity(snapshot: absolutePathBeforeRelativeSnapshot) == nil)

        let oldOmp = root.appendingPathComponent("omp", isDirectory: false)
        try "#!/bin/sh\nprintf '%s\\n' 'omp/13.14.2'\n"
            .write(to: oldOmp, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldOmp.path)
        var ompWrappedSnapshot = snapshot
        ompWrappedSnapshot.launchCommand?.launcher = "omp"
        ompWrappedSnapshot.launchCommand?.executablePath = oldOmp.path
        ompWrappedSnapshot.launchCommand?.arguments = [oldOmp.path, "--session", "pi-session"]
        #expect(!(await AgentForkSupport.supportsFork(snapshot: ompWrappedSnapshot)))
        ompWrappedSnapshot.launchCommand?.launcher = nil
        #expect(!(await AgentForkSupport.supportsFork(snapshot: ompWrappedSnapshot)))

        let failedPi = root.appendingPathComponent("failed-pi", isDirectory: false)
        try "#!/bin/sh\nprintf '%s\\n' '0.80.6'\nexit 1\n"
            .write(to: failedPi, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failedPi.path)
        var failedSnapshot = snapshot
        failedSnapshot.launchCommand?.executablePath = failedPi.path
        failedSnapshot.launchCommand?.arguments = [failedPi.path, "--session", "pi-session"]
        #expect(!(await AgentForkSupport.supportsFork(snapshot: failedSnapshot)))

        let piAlias = root.appendingPathComponent("pi-coding-agent", isDirectory: false)
        try "#!/bin/sh\nprintf '%s\\n' '0.80.6'\n"
            .write(to: piAlias, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: piAlias.path)
        var piAliasSnapshot = snapshot
        piAliasSnapshot.sessionId = "pi-alias-session"
        piAliasSnapshot.workingDirectory = root.path
        piAliasSnapshot.launchCommand?.executablePath = piAlias.path
        piAliasSnapshot.launchCommand?.arguments = [piAlias.path, "--session", "pi-alias-session"]
        piAliasSnapshot.launchCommand?.workingDirectory = root.path
        #expect(await AgentForkSupport.supportsFork(snapshot: piAliasSnapshot))

        let sharedWrapper = root.appendingPathComponent("agent-wrapper", isDirectory: false)
        try "#!/bin/sh\nprintf '%s\\n' 'pi 1.0.0'\n"
            .write(to: sharedWrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedWrapper.path)
        var sharedPiSnapshot = snapshot
        sharedPiSnapshot.workingDirectory = root.path
        sharedPiSnapshot.launchCommand?.launcher = "pi"
        sharedPiSnapshot.launchCommand?.executablePath = sharedWrapper.path
        sharedPiSnapshot.launchCommand?.arguments = [sharedWrapper.path]
        sharedPiSnapshot.launchCommand?.workingDirectory = root.path
        #expect(await AgentForkSupport.supportsFork(snapshot: sharedPiSnapshot))
        let sharedOmpSnapshot = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: "omp-wrapper-session",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omp",
                executablePath: sharedWrapper.path,
                arguments: [sharedWrapper.path, "--session", "omp-wrapper-session"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 124,
                source: "process"
            ),
            registration: .builtInOmp
        )
        #expect(!(await AgentForkSupport.supportsFork(snapshot: sharedOmpSnapshot)))

        let ompThroughPiNamedWrapper = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: "omp-session",
            workingDirectory: root.appendingPathComponent("deleted-directory").path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omp",
                executablePath: executable.path,
                arguments: [executable.path, "--session", "omp-session"],
                workingDirectory: root.appendingPathComponent("deleted-directory").path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            ),
            registration: .builtInOmp
        )
        #expect(!(await AgentForkSupport.supportsFork(snapshot: ompThroughPiNamedWrapper)))

        let environmentWrapper = root.appendingPathComponent("environment-wrapper", isDirectory: false)
        try "#!/bin/sh\nif [ \"$PI_CONFIG_DIR\" = \"supported\" ]; then printf '%s\\n' 'pi 0.80.6'; else printf '%s\\n' 'pi 0.59.0'; fi\n"
            .write(to: environmentWrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: environmentWrapper.path)
        var supportedEnvironmentSnapshot = snapshot
        supportedEnvironmentSnapshot.workingDirectory = root.path
        supportedEnvironmentSnapshot.launchCommand?.executablePath = environmentWrapper.path
        supportedEnvironmentSnapshot.launchCommand?.arguments = [environmentWrapper.path]
        supportedEnvironmentSnapshot.launchCommand?.workingDirectory = root.path
        supportedEnvironmentSnapshot.launchCommand?.environment = ["PI_CONFIG_DIR": "supported"]
        #expect(await AgentForkSupport.supportsFork(snapshot: supportedEnvironmentSnapshot))
        var unsupportedEnvironmentSnapshot = supportedEnvironmentSnapshot
        unsupportedEnvironmentSnapshot.launchCommand?.environment = ["PI_CONFIG_DIR": "unsupported"]
        #expect(!(await AgentForkSupport.supportsFork(snapshot: unsupportedEnvironmentSnapshot)))
    }

    @Test
    func piCapabilityProbeUsesRenderedForkWorkingDirectoryWhenLaunchDirectoryDiffers() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pi-cwd-priority-\(UUID().uuidString)", isDirectory: true)
        let launchRoot = root.appendingPathComponent("launch-root", isDirectory: true)
        let restoredRoot = root.appendingPathComponent("restored-root", isDirectory: true)
        let launchBin = launchRoot.appendingPathComponent("bin", isDirectory: true)
        let restoredBin = restoredRoot.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: launchBin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: restoredBin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let launchExecutable = launchBin.appendingPathComponent("pi", isDirectory: false)
        try "#!/bin/sh\nprintf '%s\\n' '0.80.6'\n"
            .write(to: launchExecutable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchExecutable.path)

        let restoredExecutable = restoredBin.appendingPathComponent("pi", isDirectory: false)
        try "#!/bin/sh\nprintf '%s\\n' '0.59.0'\n"
            .write(to: restoredExecutable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restoredExecutable.path)

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-cwd-priority-session",
            workingDirectory: restoredRoot.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                arguments: ["pi", "--session", "pi-cwd-priority-session"],
                workingDirectory: launchRoot.path,
                environment: ["PATH": "./bin:/usr/bin:/bin"],
                capturedAt: 123,
                source: "process"
            )
        )

        let identity = try #require(AgentForkSupport.forkValidationExecutableIdentity(snapshot: snapshot))
        #expect(identity.lookupPath == restoredExecutable.path)
        #expect(
            !(await AgentForkSupport.supportsFork(snapshot: snapshot)),
            "The probe should resolve relative PATH entries from the same cwd used when rendering the fork command."
        )
    }

    @Test
    func piFamilyProbeCacheInvalidatesWhenExecutableFileIdentityChanges() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pi-executable-identity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        func writePiProbe(output: String, modifiedAt: TimeInterval) throws {
            try """
            #!/bin/sh
            printf '%s\\n' '\(output)'
            """
                .write(to: executable, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [
                    .posixPermissions: 0o755,
                    .modificationDate: Date(timeIntervalSince1970: modifiedAt),
                ],
                ofItemAtPath: executable.path
            )
        }

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-file-identity-session",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: executable.path,
                arguments: [executable.path, "--session", "pi-file-identity-session"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let executableIdentityResolver = AgentForkExecutableIdentityResolver()
        let capabilityProbeCache = ForkCapabilityProbeResultCache()
        func supportsFork(_ snapshot: SessionRestorableAgentSnapshot) async -> Bool {
            await AgentForkSupport.supportsFork(
                snapshot: snapshot,
                executableIdentityResolver: executableIdentityResolver,
                forkCapabilityProbeCache: capabilityProbeCache
            )
        }

        try writePiProbe(output: "pi 0.80.6", modifiedAt: 10)
        #expect(await supportsFork(snapshot))

        try writePiProbe(output: "pi 0.59.0", modifiedAt: 20)
        #expect(
            !(await supportsFork(snapshot)),
            "A Pi downgrade at the same executable path must not reuse the prior positive probe cache entry."
        )

        try writePiProbe(output: "pi 0.80.6", modifiedAt: 30)
        #expect(
            await supportsFork(snapshot),
            "A Pi upgrade at the same executable path must not reuse the prior negative probe cache entry."
        )
    }

    @Test
    func piFamilyCapabilityProbeCacheSharesExecutableIdentityAcrossSnapshots() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pi-executable-cache-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let executable = root.appendingPathComponent("agent-wrapper", isDirectory: false)
        let counter = root.appendingPathComponent("probe-count.txt", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s\\n' hit >> '\(counter.path)'
        printf '%s\\n' 'pi 0.80.6'
        """
            .write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        func snapshot(launcher: String, sessionId: String) -> SessionRestorableAgentSnapshot {
            var snapshot = makePiFamilySnapshot(
                launcher: launcher,
                workspaceRoot: root.path,
                executablePath: executable.path
            )
            snapshot.sessionId = sessionId
            snapshot.launchCommand?.arguments = [executable.path, "--session", sessionId]
            return snapshot
        }

        func probeCount() -> Int {
            let output = (try? String(contentsOf: counter, encoding: .utf8)) ?? ""
            return output.split(separator: "\n").count
        }

        let executableIdentityResolver = AgentForkExecutableIdentityResolver()
        let capabilityProbeCache = ForkCapabilityProbeResultCache()
        func supportsFork(_ snapshot: SessionRestorableAgentSnapshot) async -> Bool {
            await AgentForkSupport.supportsFork(
                snapshot: snapshot,
                executableIdentityResolver: executableIdentityResolver,
                forkCapabilityProbeCache: capabilityProbeCache
            )
        }

        #expect(await supportsFork(snapshot(launcher: "pi", sessionId: "pi-one")))
        #expect(await supportsFork(snapshot(launcher: "pi", sessionId: "pi-two")))
        #expect(probeCount() == 1)

        #expect(!(await supportsFork(snapshot(launcher: "omp", sessionId: "omp-one"))))
        #expect(probeCount() == 2)
    }

    @Test
    func piFamilyValidationExecutableResolutionWorkIdentityIgnoresSessionAndLauncher() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pi-resolution-work-key-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let executable = root.appendingPathComponent("agent-wrapper", isDirectory: false)
        try writeExecutableFixture(at: executable)

        func snapshot(launcher: String, sessionId: String) -> SessionRestorableAgentSnapshot {
            var snapshot = makePiFamilySnapshot(
                launcher: launcher,
                workspaceRoot: root.path,
                executablePath: executable.path
            )
            snapshot.sessionId = sessionId
            snapshot.launchCommand?.arguments = [executable.path, "--session", sessionId]
            return snapshot
        }

        let piOneIdentity = try #require(AgentForkSupport.forkValidationExecutableResolutionWorkIdentity(
            snapshot: snapshot(launcher: "pi", sessionId: "pi-one")
        ))
        let piTwoIdentity = try #require(AgentForkSupport.forkValidationExecutableResolutionWorkIdentity(
            snapshot: snapshot(launcher: "pi", sessionId: "pi-two")
        ))
        let ompIdentity = try #require(AgentForkSupport.forkValidationExecutableResolutionWorkIdentity(
            snapshot: snapshot(launcher: "omp", sessionId: "omp-one")
        ))

        #expect(piOneIdentity == piTwoIdentity)
        #expect(
            piOneIdentity == ompIdentity,
            "Executable resolution work should key only the wrapper lookup inputs; capability results use a launcher-specific cache key separately."
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func forkCapabilityProbeTimesOutWhenWrapperLeavesOutputPipeOpen() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pi-leaky-probe-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        let childPIDFile = root.appendingPathComponent("child-pid", isDirectory: false)
        let escapedChildPIDFile = childPIDFile.path
            .replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        (sleep 60) &
        printf '%s\\n' "$!" > '\(escapedChildPIDFile)'
        printf '%s\\n' '0.80.6'
        """
            .write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "leaky-pipe-session",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: executable.path,
                arguments: [executable.path, "--session", "leaky-pipe-session"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        #expect(!(await AgentForkSupport.supportsFork(snapshot: snapshot)))
        try expectProcessExited(pidFile: childPIDFile)
    }

    @Test(.timeLimit(.minutes(1)))
    func forkCapabilityProbeTerminatesSetsidDescendantHoldingOutputPipe() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pi-setsid-probe-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        let childPIDFile = root.appendingPathComponent("setsid-child-pid", isDirectory: false)
        let escapedChildPIDFile = childPIDFile.path
            .replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        /usr/bin/python3 -c 'import os, pathlib, signal; os.setsid(); pathlib.Path('\''\(escapedChildPIDFile)'\'').write_text(str(os.getpid())); signal.pause()' &
        while [ ! -s '\(escapedChildPIDFile)' ]; do :; done
        printf '%s\\n' '0.80.6'
        """
            .write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "setsid-pipe-session",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: executable.path,
                arguments: [executable.path, "--session", "setsid-pipe-session"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        #expect(!(await AgentForkSupport.supportsFork(snapshot: snapshot)))
        try expectProcessExited(pidFile: childPIDFile)
    }

    @Test(.timeLimit(.minutes(1)))
    func forkCapabilityProbeHardKillsSigtermIgnoringSetsidDescendantAfterTimedOutLeaderExits() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pi-setsid-sigterm-ignore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        let childPIDFile = root.appendingPathComponent("setsid-sigterm-ignored-child-pid", isDirectory: false)
        let escapedChildPIDFile = childPIDFile.path
            .replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        /usr/bin/python3 -c 'import os, pathlib, signal; os.setsid(); signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path('\''\(escapedChildPIDFile)'\'').write_text(str(os.getpid())); signal.pause()' &
        while [ ! -s '\(escapedChildPIDFile)' ]; do :; done
        trap 'exit 0' TERM
        sleep 10
        """
            .write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "setsid-sigterm-ignore-pipe-session",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: executable.path,
                arguments: [executable.path, "--session", "setsid-sigterm-ignore-pipe-session"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        #expect(!(await AgentForkSupport.supportsFork(snapshot: snapshot)))
        try expectProcessExited(pidFile: childPIDFile)
    }

    @Test
    func forkCapabilityProbeDrainsVerboseOutputWhileProcessRuns() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pi-verbose-probe-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s\\n' '0.80.6'
        i=0
        while [ "$i" -lt 5000 ]; do
          printf '%s\\n' 'verbose launcher warning that keeps writing before process exit'
          i=$((i + 1))
        done
        """
            .write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-verbose-session",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: executable.path,
                arguments: [executable.path, "--session", "pi-verbose-session"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        #expect(await AgentForkSupport.supportsFork(snapshot: snapshot))
    }

    @Test
    func processDetectedPiFamilySnapshotsPreserveLaunchPath() {
        let path = "/Users/example/.bun/bin:/usr/bin"
        for launcher in ["pi", "omp"] {
            let command = AgentLaunchCommandSnapshot(
                processDetectedLauncher: launcher,
                executablePath: launcher,
                arguments: [launcher],
                workingDirectory: nil,
                environment: ["PATH": path]
            )
            #expect(command.environment?["PATH"] == path)
        }
    }

    @Test
    func persistedBuiltInOmpSnapshotMigratesLegacyForkTemplate() throws {
        let sessionId = "omp-session-123"
        var legacyRegistration = CmuxVaultAgentRegistration.builtInOmp
        legacyRegistration.forkCommand = "{{executable}} --session {{sessionId}} --fork"
        let persisted = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: "/tmp/omp repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omp",
                executablePath: "/opt/homebrew/bin/omp",
                arguments: ["/opt/homebrew/bin/omp", "--session", sessionId],
                workingDirectory: "/tmp/omp repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            ),
            registration: legacyRegistration
        )

        let decoded = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: JSONEncoder().encode(persisted)
        )

        #expect(decoded.registration == .builtInOmp)
        #expect(decoded.forkCommand?.contains("'--fork' '\(sessionId)'") == true)

        var projectOverride = legacyRegistration
        projectOverride.name = "Project OMP"
        let overridden = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: nil,
            launchCommand: persisted.launchCommand,
            registration: projectOverride
        )
        let decodedOverride = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: JSONEncoder().encode(overridden)
        )
        #expect(decodedOverride.registration == projectOverride)

        var historicalRegistration = CmuxVaultAgentRegistration.builtInOmp
        historicalRegistration.iconAssetName = nil
        historicalRegistration.forkCommand = nil
        let historical = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: nil,
            launchCommand: persisted.launchCommand,
            registration: historicalRegistration
        )
        let decodedHistorical = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: JSONEncoder().encode(historical)
        )
        #expect(decodedHistorical.registration == historicalRegistration)
        #expect(decodedHistorical.forkCommand == nil)

        var legacyWithoutIcon = legacyRegistration
        legacyWithoutIcon.iconAssetName = nil
        let decodedLegacyWithoutIcon = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: JSONEncoder().encode(SessionRestorableAgentSnapshot(
                kind: .custom("omp"),
                sessionId: sessionId,
                workingDirectory: nil,
                launchCommand: persisted.launchCommand,
                registration: legacyWithoutIcon
            ))
        )
        #expect(decodedLegacyWithoutIcon.registration == .builtInOmp)
        #expect(decodedLegacyWithoutIcon.forkCommand?.contains("'--fork' '\(sessionId)'") == true)

        var customForkRegistration = CmuxVaultAgentRegistration.builtInOmp
        customForkRegistration.forkCommand = "{{executable}} --branch {{sessionId}}"
        let customFork = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: nil,
            launchCommand: persisted.launchCommand,
            registration: customForkRegistration
        )
        let decodedCustomFork = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: JSONEncoder().encode(customFork)
        )
        #expect(decodedCustomFork.registration == customForkRegistration)
        #expect(decodedCustomFork.forkCommand?.contains("'--branch' '\(sessionId)'") == true)
    }

    @Test
    func persistedPiProjectRegistrationKeepsForkOwnership() throws {
        let sessionId = "pi-session-123"
        var projectRegistration = CmuxVaultAgentRegistration.builtInPi
        projectRegistration.name = "Project Pi"
        projectRegistration.forkCommand = nil
        let persisted = SessionRestorableAgentSnapshot(
            kind: .custom("pi"),
            sessionId: sessionId,
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "/opt/homebrew/bin/pi",
                arguments: ["/opt/homebrew/bin/pi", "--session", sessionId],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "process"
            ),
            registration: projectRegistration
        )

        let decoded = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: JSONEncoder().encode(persisted)
        )

        #expect(decoded.kind == .custom("pi"))
        #expect(decoded.registration == projectRegistration)
        #expect(decoded.forkCommand == nil)

        var legacyBuiltIn = CmuxVaultAgentRegistration.builtInPi
        legacyBuiltIn.forkCommand = "{{executable}} --session {{sessionId}} --fork"
        let legacySnapshot = SessionRestorableAgentSnapshot(
            kind: .custom("pi"),
            sessionId: sessionId,
            workingDirectory: nil,
            launchCommand: persisted.launchCommand,
            registration: legacyBuiltIn
        )
        let decodedLegacy = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: JSONEncoder().encode(legacySnapshot)
        )
        #expect(decodedLegacy.kind == .custom("pi"))
        #expect(decodedLegacy.registration == .builtInPi)
        #expect(decodedLegacy.forkCommand?.contains("'--fork' '\(sessionId)'") == true)

        var historicalBuiltIn = CmuxVaultAgentRegistration.builtInPi
        historicalBuiltIn.iconAssetName = nil
        historicalBuiltIn.forkCommand = nil
        let historicalSnapshot = SessionRestorableAgentSnapshot(
            kind: .custom("pi"),
            sessionId: sessionId,
            workingDirectory: nil,
            launchCommand: persisted.launchCommand,
            registration: historicalBuiltIn
        )
        let decodedHistorical = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: JSONEncoder().encode(historicalSnapshot)
        )
        #expect(decodedHistorical.kind == .custom("pi"))
        #expect(decodedHistorical.registration == historicalBuiltIn)
        #expect(decodedHistorical.forkCommand == nil)
    }

    @Test
    func directOpenCodePresentationStaysVisibleWhileValidationRefreshes() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(makeProbeRequiredOpenCodeSnapshot(), panelId: panelId)

        let liveAgentIndex = SharedLiveAgentIndex(
            indexLoader: {
                SharedLiveAgentIndexLoader(
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    processSnapshotProvider: {
                        CmuxTopProcessSnapshot(
                            processes: [],
                            sampledAt: Date(timeIntervalSince1970: 42),
                            includesProcessDetails: true
                        )
                    },
                    capturedAtProvider: { 42 },
                    processArgumentsProvider: { _ in nil }
                )
                .loadResultSynchronously()
            },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        #expect(
            workspace.forkAgentConversationContextMenuPresentationAvailability(
                forPanelId: panelId,
                liveAgentIndex: liveAgentIndex
            ) == .agentIndexRefreshing
        )
    }

    @Test
    func restoredDirectOpenCodeCanValidateWithoutLiveIndexEntry() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-opencode-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutableFixture(at: executable)
        let snapshotWithExecutable = makeProbeRequiredOpenCodeSnapshot(
            workingDirectory: root.path,
            executablePath: executable.path
        )
        workspace.setRestoredAgentSnapshotForTesting(snapshotWithExecutable, panelId: panelId)

        let liveAgentIndex = SharedLiveAgentIndex(
            indexLoader: {
                SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    processSnapshotProvider: {
                        CmuxTopProcessSnapshot(
                            processes: [],
                            sampledAt: Date(timeIntervalSince1970: 42),
                            includesProcessDetails: true
                        )
                    },
                    capturedAtProvider: { 42 },
                    processArgumentsProvider: { _ in nil }
                )
                .loadResultSynchronously()
            },
            forkSupportProvider: { _, _ in true },
            hookStoreDirectoryProvider: { root.path },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        await liveAgentIndex.refreshForkAvailabilityNow(
            workspaceId: workspace.id,
            panelId: panelId,
            fallbackSnapshot: snapshotWithExecutable
        )

        #expect(
            workspace.forkAgentConversationContextMenuOpenAvailability(
                forPanelId: panelId,
                liveAgentIndex: liveAgentIndex
            ) == .available
        )
    }

    @Test
    func contextMenuOpenSelectionPrefersLiveIndexOverRestoredFallback() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-live-pi-restored-opencode-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.80.6")
        let liveSnapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let staleFallback = makeProbeRequiredOpenCodeSnapshot(
            sessionId: "stale-opencode-session",
            workingDirectory: root.appendingPathComponent("stale", isDirectory: true).path,
            executablePath: root.appendingPathComponent("opencode", isDirectory: false).path
        )
        workspace.setRestoredAgentSnapshotForTesting(staleFallback, panelId: panelId)
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: [.builtInPi]),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: liveSnapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            forkSupportProvider: { _, _ in true },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspace.id, panelId: panelId)
        let selection = workspace.forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId,
            liveAgentIndex: sharedIndex
        )

        #expect(selection.availability == .available)
        #expect(selection.snapshot?.sessionId == liveSnapshot.sessionId)
        #expect(selection.snapshot?.launchCommand?.launcher == "pi")
    }

    @Test
    func contextMenuOpenSelectionDoesNotPreferUnvalidatedLiveIndexOverRestoredFallback() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-unvalidated-live-restored-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let staleLiveSnapshot = makeForkableClaudeSnapshot(
            sessionId: "stale-live-claude-session",
            workingDirectory: root.appendingPathComponent("stale", isDirectory: true).path
        )
        let restoredSnapshot = makeForkableClaudeSnapshot(
            sessionId: "restored-current-claude-session",
            workingDirectory: root.appendingPathComponent("restored", isDirectory: true).path
        )
        workspace.setRestoredAgentSnapshotForTesting(restoredSnapshot, panelId: panelId)
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: staleLiveSnapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            forkSupportProvider: { _, _ in true },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        await sharedIndex.refreshForkAvailabilityNow()
        let selection = workspace.forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId,
            liveAgentIndex: sharedIndex
        )

        #expect(selection.availability == .available)
        #expect(selection.snapshot?.sessionId == restoredSnapshot.sessionId)
        #expect(selection.snapshot?.sessionId != staleLiveSnapshot.sessionId)
    }

    @Test
    func contextMenuOpenSelectionDoesNotFallbackWhenValidatedLiveProbeIsRejected() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-rejected-live-restored-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".cmuxterm", isDirectory: true), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("pi", isDirectory: false)
        try writeExecutableFixture(at: executable, output: "pi 0.1.0")
        let rejectedLiveSnapshot = makePiFamilySnapshot(
            launcher: "pi",
            workspaceRoot: root.path,
            executablePath: executable.path
        )
        let restoredSnapshot = makeForkableClaudeSnapshot(
            sessionId: "restored-current-claude-session",
            workingDirectory: root.appendingPathComponent("restored", isDirectory: true).path
        )
        workspace.setRestoredAgentSnapshotForTesting(restoredSnapshot, panelId: panelId)
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: [.builtInPi]),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: rejectedLiveSnapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            forkSupportProvider: { _, _ in false },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspace.id, panelId: panelId)
        let selection = workspace.forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId,
            liveAgentIndex: sharedIndex
        )

        #expect(sharedIndex.snapshotForForkConversationCandidate(workspaceId: workspace.id, panelId: panelId) != nil)
        #expect(sharedIndex.forkSupportProbeRejected(workspaceId: workspace.id, panelId: panelId))
        #expect(selection.availability == .unsupported)
        #expect(selection.snapshot == nil)
    }

    @Test
    func directOpenCodeContextMenuReconcilesLivenessAndVersionSupport() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-opencode-context-menu-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutableFixture(at: executable)
        let snapshotWithExecutable = makeProbeRequiredOpenCodeSnapshot(
            workingDirectory: root.path,
            executablePath: executable.path
        )
        workspace.setRestoredAgentSnapshotForTesting(snapshotWithExecutable, panelId: panelId)
        workspace.restoredAgentResumeStatesByPanelId[panelId] = .completedAgentExit
        try writeCustomAgentHookStore(
            root: root,
            agentId: "opencode",
            sessions: [
                snapshotWithExecutable.sessionId: customAgentHookRecord(
                    agentId: "opencode",
                    sessionId: snapshotWithExecutable.sessionId,
                    workspaceId: workspace.id,
                    panelId: panelId,
                    cwd: try #require(snapshotWithExecutable.workingDirectory),
                    executable: executable.path,
                    updatedAt: 10
                ),
            ]
        )

        let forkSupported = OSAllocatedUnfairLock(initialState: false)
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 42))
        let liveAgentIndex = SharedLiveAgentIndex(
            indexLoader: {
                SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    processSnapshotProvider: {
                        CmuxTopProcessSnapshot(
                            processes: [],
                            sampledAt: Date(timeIntervalSince1970: 42),
                            includesProcessDetails: true
                        )
                    },
                    capturedAtProvider: { 42 },
                    processArgumentsProvider: { _ in nil }
                )
                .loadResultSynchronously()
            },
            forkSupportProvider: { _, _ in
                now.withLock { $0 = Date(timeIntervalSince1970: 100) }
                return forkSupported.withLock { $0 }
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { now.withLock { $0 } }
        )
        #expect(
            workspace.forkAgentConversationContextMenuPresentationAvailability(
                forPanelId: panelId,
                liveAgentIndex: liveAgentIndex
            ) == .agentIndexRefreshing
        )

        await liveAgentIndex.refreshForkAvailabilityNow(workspaceId: workspace.id, panelId: panelId)
        #expect(liveAgentIndex.prepareForkAvailabilityProbe(workspaceId: workspace.id, panelId: panelId))
        #expect(
            workspace.forkAgentConversationContextMenuOpenAvailability(
                forPanelId: panelId,
                liveAgentIndex: liveAgentIndex
            ) == .unsupported
        )

        forkSupported.withLock { $0 = true }
        await liveAgentIndex.refreshForkAvailabilityNow(workspaceId: workspace.id, panelId: panelId)

        #expect(
            workspace.forkAgentConversationContextMenuOpenAvailability(
                forPanelId: panelId,
                liveAgentIndex: liveAgentIndex
            ) == .available
        )
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] != .completedAgentExit)
    }

    private func writeExecutableFixture(
        at executable: URL,
        output: String = "opencode 0.99.0"
    ) throws {
        try """
        #!/bin/sh
        cat <<'CMUX_EXECUTABLE_FIXTURE'
        \(output)
        CMUX_EXECUTABLE_FIXTURE
        """
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func expectProcessExited(pidFile: URL) throws {
        let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(rawPID))
        errno = 0
        let result = Darwin.kill(pid, 0)
        let processError = errno
        if result == 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
        #expect(
            result == -1 && processError == ESRCH,
            "The timed-out fork probe must terminate descendant process \(pid)."
        )
    }

    private func makeForkableClaudeSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }

    private func makeProbeRequiredOpenCodeSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87952",
        workingDirectory: String = "/tmp/fork repo",
        executablePath: String = "/opt/homebrew/bin/opencode",
        environment: [String: String]? = nil
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: executablePath,
                arguments: [executablePath, "--session", sessionId],
                workingDirectory: workingDirectory,
                environment: environment,
                capturedAt: 123,
                source: "process"
            )
        )
    }

    private func makePiFamilySnapshot(
        launcher: String,
        workspaceRoot: String,
        executablePath: String = "/usr/local/bin/agent-wrapper"
    ) -> SessionRestorableAgentSnapshot {
        let registration: CmuxVaultAgentRegistration = launcher == "omp" ? .builtInOmp : .builtInPi
        return SessionRestorableAgentSnapshot(
            kind: .custom(launcher),
            sessionId: "pi-family-session",
            workingDirectory: workspaceRoot,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: launcher,
                executablePath: executablePath,
                arguments: [executablePath, "--session", "pi-family-session"],
                workingDirectory: workspaceRoot,
                environment: nil,
                capturedAt: 123,
                source: "process"
            ),
            registration: registration
        )
    }

    private func writeCustomAgentHookStore(
        root: URL,
        agentId: String,
        sessions: [String: [String: Any]]
    ) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": sessions],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: stateDir.appendingPathComponent("\(agentId)-hook-sessions.json"),
            options: .atomic
        )
    }

    private func customAgentHookRecord(
        agentId: String,
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        executable: String,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": cwd,
            "pid": NSNull(),
            "isRestorable": true,
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": agentId,
                "executablePath": executable,
                "arguments": [executable, "--session", sessionId],
                "workingDirectory": cwd,
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
    }
}
