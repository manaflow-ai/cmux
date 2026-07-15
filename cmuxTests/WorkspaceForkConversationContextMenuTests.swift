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
struct WorkspaceForkConversationContextMenuTests {
    @Test
    func panelContextMenuActionUsesClickedPanel() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)
        let otherPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: true))
        #expect(workspace.focusedPanelId == otherPanel.id)

        #expect(
            workspace.forkAgentConversationFromContextMenu(
                fromPanelId: sourcePanelId,
                destination: .newTab
            )
        )

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
        #expect(AgentForkSupport.piFamilyVersionSupportsFork("0.60.0", agentID: "pi"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("0.59.9", agentID: "pi"))
        #expect(AgentForkSupport.piFamilyVersionSupportsFork("omp/13.15.0", agentID: "omp"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("omp/13.14.2", agentID: "omp"))
        #expect(!AgentForkSupport.piFamilyVersionSupportsFork("16.5.2", agentID: "unknown"))
    }

    @Test
    func builtInOmpRequiresProbeButProjectForkOverrideDoesNot() {
        let builtIn = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: "omp-session",
            workingDirectory: nil,
            launchCommand: nil,
            registration: .builtInOmp
        )
        #expect(ContentView.commandPaletteSnapshotForkAvailability(builtIn) == .requiresProbe)

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
    func piCapabilityProbeUsesFallbackDirectoryWhenSavedDirectoryIsMissing() async throws {
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

        #expect(await AgentForkSupport.supportsFork(snapshot: snapshot))
        #expect(!(await AgentForkSupport.supportsFork(snapshot: snapshot, isRemoteContext: true)))

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
        let snapshot = makeProbeRequiredOpenCodeSnapshot()
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelId)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-opencode-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

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
            fallbackSnapshot: snapshot
        )

        #expect(
            workspace.forkAgentConversationContextMenuOpenAvailability(
                forPanelId: panelId,
                liveAgentIndex: liveAgentIndex
            ) == .available
        )
    }

    @Test
    func directOpenCodeContextMenuReconcilesLivenessAndVersionSupport() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = makeProbeRequiredOpenCodeSnapshot()
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelId)
        workspace.restoredAgentResumeStatesByPanelId[panelId] = .completedAgentExit

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-opencode-context-menu-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try writeCustomAgentHookStore(
            root: root,
            agentId: "opencode",
            sessions: [
                snapshot.sessionId: customAgentHookRecord(
                    agentId: "opencode",
                    sessionId: snapshot.sessionId,
                    workspaceId: workspace.id,
                    panelId: panelId,
                    cwd: try #require(snapshot.workingDirectory),
                    executable: "/opt/homebrew/bin/opencode",
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
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", sessionId],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
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
