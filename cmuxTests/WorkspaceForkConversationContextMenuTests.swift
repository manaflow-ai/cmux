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
                SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    fileManager: .default,
                    registry: registry,
                    processSnapshotProvider: { snapshot },
                    capturedAtProvider: { snapshot.sampledAt.timeIntervalSince1970 },
                    processArgumentsProvider: { pid in
                        guard pid == processId else { return nil }
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
            }
        )

        await sharedIndex.refreshForkAvailabilityNow()
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

        await sharedIndex.refreshForkAvailabilityNow()
        #expect(
            sharedIndex.snapshotForForkAvailability(
                workspaceId: staleWorkspaceId,
                panelId: stalePanelId
            ) == nil
        )
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
        let processScopeFingerprint = OSAllocatedUnfairLock(initialState: Set<String>())
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
            },
            processScopeFingerprintProvider: {
                processScopeFingerprint.withLock { $0 }
            }
        )

        await sharedIndex.refreshForkAvailabilityNow()
        #expect(sharedIndex.prepareForkAvailabilityProbe())
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId)?.sessionId
                == sessionId
        )

        now.withLock { $0 = Date(timeIntervalSince1970: 2) }
        #expect(
            sharedIndex.prepareForkAvailabilityProbe(),
            "A completed fork probe should not expire solely because the old 1s window elapsed."
        )

        processScopeFingerprint.withLock { $0 = ["workspace|panel|pid"] }
        #expect(
            !sharedIndex.prepareForkAvailabilityProbe(),
            "Fork availability must revalidate when the cmux-scoped process fingerprint changes."
        )
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil)

        now.withLock { $0 = Date(timeIntervalSince1970: 61) }
        #expect(
            !sharedIndex.prepareForkAvailabilityProbe(),
            "Fork availability must fail closed while the shared index is refreshing."
        )
        #expect(sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) == nil)
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
