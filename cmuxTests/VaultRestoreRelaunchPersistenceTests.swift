import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct VaultRestoreRelaunchPersistenceTests {
    @Test("Queued Vault restore survives an early idle report and relaunch")
    func queuedRestoreSurvivesPromptIdleSnapshot() throws {
        let launch = try makeLaunch(sessionID: "vault-queued-relaunch")
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let resumeIntentRecorder = AgentChatResumeIntentRecorder { _ in }

        let source = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)

        // The shell can report its initial prompt before the restore selector
        // starts or before the resumed agent process becomes observable.
        source.panelShellActivityStates[sourcePanelID] = .promptIdle

        let persisted = source.sessionSnapshot(
            includeScrollback: false,
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let persistedTerminal = try #require(
            persisted.panels.first { $0.id == sourcePanelID }?.terminal
        )
        #expect(persistedTerminal.wasAgentRunning == true)
        #expect(persistedTerminal.agent?.sessionId == snapshot.sessionId)

        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(decoded)
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.surface.debugInitialInputForTesting() == launch.initialInput)
        #expect(
            restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelID]
                == launch.workingDirectory
        )
    }

    @Test("Relaunch restore commits lifecycle and chat state at its tab topology boundary")
    func relaunchRestoreWaitsForTabTopologyCommit() throws {
        let launch = try makeLaunch(sessionID: "vault-topology-admission")
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        var resumeIntents: [AgentChatResumeIntent] = []
        let resumeIntentRecorder = AgentChatResumeIntentRecorder {
            resumeIntents.append($0)
        }
        let source = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let persisted = source.sessionSnapshot(includeScrollback: false)
        let sourcePanelID = try #require(source.focusedPanelId)
        let committedIntentCount = resumeIntents.count

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(
            persisted,
            startupRestoreCommitOwner: .tabManagerTopology
        )
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(!restoredPanel.surface.canCreateRuntimeSurface)
        #expect(restoredPanel.surface.debugInitialInputForTesting() == launch.initialInput)
        #expect(restored.restoredAgentSnapshotsByPanelId[restoredPanelID] == nil)
        #expect(resumeIntents.count == committedIntentCount)

        restored.terminalStartupRestoreCoordinator.commitPendingRestores()

        #expect(restoredPanel.surface.canCreateRuntimeSurface)
        #expect(
            restored.restoredAgentSnapshotsByPanelId[restoredPanelID]?.sessionId
                == snapshot.sessionId
        )
        #expect(resumeIntents.count == committedIntentCount + 1)
        #expect(resumeIntents.last?.surfaceID == restoredPanelID.uuidString)
    }

    @Test("Tab manager publishes restored workspaces before releasing terminals")
    func tabManagerRestoreReleasesDeferredAdmission() throws {
        let launch = try makeLaunch(sessionID: "vault-tab-manager-admission")
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let resumeIntentRecorder = AgentChatResumeIntentRecorder { _ in }
        let source = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let persistedWorkspace = source.sessionSnapshot(includeScrollback: false)
        let sourcePanelID = try #require(source.focusedPanelId)

        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let restoredPanelIDs = manager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [persistedWorkspace]
        ))
        let restoredWorkspace = try #require(manager.tabs.first)
        let restoredPanelID = try #require(restoredPanelIDs.first?[sourcePanelID])
        let restoredPanel = try #require(restoredWorkspace.terminalPanel(for: restoredPanelID))

        #expect(manager.tabs.contains { $0 === restoredWorkspace })
        #expect(restoredPanel.surface.canCreateRuntimeSurface)
        #expect(restoredPanel.surface.debugInitialInputForTesting() == launch.initialInput)
    }

    @Test("Cancelling a staged relaunch releases its launch claim and closes the terminal")
    func cancelledRelaunchRestoreReleasesClaimAndClosesTerminal() throws {
        let sessionID = "vault-cancelled-relaunch-\(UUID().uuidString)"
        let launch = try makeLaunch(sessionID: sessionID)
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        defer {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: snapshot.kind.rawValue,
                sessionId: sessionID
            )
        }
        let resumeIntentRecorder = AgentChatResumeIntentRecorder { _ in }
        let source = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let persisted = source.sessionSnapshot(includeScrollback: false)
        let sourcePanelID = try #require(source.focusedPanelId)

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(
            persisted,
            startupRestoreCommitOwner: .tabManagerTopology
        )
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(!restoredPanel.surface.canCreateRuntimeSurface)
        #expect(
            !AgentResumeLaunchGuard.shared.claimResumeLaunch(
                kind: snapshot.kind.rawValue,
                sessionId: sessionID
            )
        )

        restored.terminalStartupRestoreCoordinator.cancelPendingRestore(
            panelID: restoredPanelID
        )

        #expect(restoredPanel.surface.debugTeardownRequest().requestedAt != nil)
        #expect(
            AgentResumeLaunchGuard.shared.claimResumeLaunch(
                kind: snapshot.kind.rawValue,
                sessionId: sessionID
            )
        )
    }

    @Test("Cancelling a Vault startup preserves a resume claim owned elsewhere")
    func cancelledVaultStartupPreservesForeignClaim() throws {
        let sessionID = "vault-foreign-claim-\(UUID().uuidString)"
        let launch = try makeLaunch(sessionID: sessionID)
        let snapshot = try #require(launch.startupRestoreAgent)
        let resumeIntentRecorder = AgentChatResumeIntentRecorder { _ in }
        #expect(
            AgentResumeLaunchGuard.shared.claimResumeLaunch(
                kind: snapshot.kind.rawValue,
                sessionId: sessionID
            )
        )
        defer {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: snapshot.kind.rawValue,
                sessionId: sessionID
            )
        }
        let workspace = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            initialTerminalStartupRestoreCommitOwner: .tabManagerTopology,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))

        #expect(!panel.surface.canCreateRuntimeSurface)
        workspace.terminalStartupRestoreCoordinator.cancelPendingRestore(
            panelID: panelID
        )

        #expect(panel.surface.debugTeardownRequest().requestedAt != nil)
        #expect(
            !AgentResumeLaunchGuard.shared.claimResumeLaunch(
                kind: snapshot.kind.rawValue,
                sessionId: sessionID
            )
        )
    }

    @Test("Manual Vault continuation does not auto-resume after relaunch")
    func manualContinuationDoesNotAutoResume() throws {
        let launch = try makeLaunch(sessionID: "vault-manual-relaunch")
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let resumeIntentRecorder = AgentChatResumeIntentRecorder { _ in }

        let source = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        let sourcePanel = try #require(source.terminalPanel(for: sourcePanelID))
        source.terminalStartupRestoreCoordinator.stage(
            panel: sourcePanel,
            snapshot: snapshot,
            manualResumeAvailable: true,
            willRunStartupCommand: false,
            willRunStartupInput: false,
            resumeWorkingDirectory: launch.workingDirectory
        )
        source.terminalStartupRestoreCoordinator.commitPendingRestores()
        source.panelShellActivityStates[sourcePanelID] = .promptIdle

        let persisted = source.sessionSnapshot(
            includeScrollback: false,
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let persistedTerminal = try #require(
            persisted.panels.first { $0.id == sourcePanelID }?.terminal
        )
        #expect(persistedTerminal.wasAgentRunning == false)

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(persisted)
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(restoredPanel.surface.debugInitialInputForTesting() == nil)
        #expect(restoredPanel.surface.canCreateRuntimeSurface)
        #expect(restoredPanel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(!restoredPanel.surface.hasLiveSurface)
    }

    @Test("Binding-only Dock restore cannot persist its own queued intent")
    func bindingOnlyDockRestoreDoesNotSelfAuthorize() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let savedPanelID = UUID()
        let sessionID = "vault-binding-only-dock"
        let directory = "/tmp/vault-binding-only-dock"
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: directory,
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_800_000_200
        )
        let panelSnapshot = SessionPanelSnapshot(
            id: savedPanelID,
            type: .terminal,
            title: "Binding-only restore",
            customTitle: nil,
            directory: directory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                resumeBinding: binding,
                wasAgentRunning: true
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults.store
        )
        defer { store.closeAllPanels() }
        let restoredIDs = store.restoreSessionSnapshot(SessionSplitContainerSnapshot(
            focusedPanelId: savedPanelID,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [savedPanelID],
                selectedPanelId: savedPanelID
            )),
            panels: [panelSnapshot]
        ))
        let restoredPanelID = try #require(restoredIDs[savedPanelID])
        #expect(
            store.restoredAgentLifecycle.resumeStatesByPanelId[restoredPanelID]
                == .awaitingAutoResumeCommand
        )

        let persisted = store.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: [:]),
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let persistedTerminal = try #require(
            persisted.panels.first { $0.id == restoredPanelID }?.terminal
        )
        #expect(persistedTerminal.agent == nil)
        #expect(persistedTerminal.wasAgentRunning == false)
    }

    @Test("Dock restore adopts staged startup work from its source workspace")
    func dockRestoreAdoptsSourceWorkspaceStartupWork() throws {
        let launch = try makeLaunch(sessionID: "vault-dock-restore-transfer")
        let agent = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        var resumeIntents: [AgentChatResumeIntent] = []
        let resumeIntentRecorder = AgentChatResumeIntentRecorder {
            resumeIntents.append($0)
        }
        let source = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let dockWorkspaceID = UUID()
        let dock = DockSplitStore(
            workspaceId: dockWorkspaceID,
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { dock.closeAllPanels() }
        let savedPanelID = UUID()
        let panelSnapshot = SessionPanelSnapshot(
            id: savedPanelID,
            type: .terminal,
            title: "Vault Dock restore",
            customTitle: nil,
            directory: launch.workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: launch.workingDirectory,
                agent: agent,
                wasAgentRunning: true
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )
        let restoredIDs = dock.restoreSessionSnapshot(
            SessionSplitContainerSnapshot(
                focusedPanelId: savedPanelID,
                layout: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [savedPanelID],
                    selectedPanelId: savedPanelID
                )),
                panels: [panelSnapshot],
                sourceWorkspaceIdsByPanelId: [savedPanelID: source.id]
            ),
            sourceWorkspaceResolver: { workspaceID in
                workspaceID == source.id ? source : nil
            }
        )
        let restoredPanelID = try #require(restoredIDs[savedPanelID])
        let restoredPanel = try #require(dock.panels[restoredPanelID] as? TerminalPanel)

        #expect(restoredPanel.surface.debugInitialInputForTesting() == launch.initialInput)
        #expect(restoredPanel.surface.canCreateRuntimeSurface)
        #expect(
            dock.restoredAgentLifecycle.snapshotsByPanelId[restoredPanelID]?.sessionId
                == agent.sessionId
        )
        #expect(resumeIntents.count == 1)
        #expect(resumeIntents.first?.surfaceID == restoredPanelID.uuidString)
        #expect(resumeIntents.first?.workspaceID == dockWorkspaceID.uuidString)
    }

    private func makeLaunch(sessionID: String) throws -> SessionEntryResumeLaunch {
        let entry = SessionEntry(
            id: "codex:\(sessionID)",
            agent: .codex,
            sessionId: sessionID,
            title: "Persisted Vault session",
            cwd: "/tmp/vault-persisted-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_100),
            fileURL: nil,
            specifics: .codex(
                model: "gpt-5.5",
                approvalPolicy: "never",
                sandboxMode: "disabled",
                effort: "high"
            )
        )
        return try #require(entry.resumeLaunch)
    }

    private func makeAutoResumeDefaults() throws -> (store: UserDefaults, name: String) {
        let name = "cmux-vault-relaunch-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        store.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        return (store, name)
    }
}
