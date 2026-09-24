import Bonsplit
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class RejectingRestoreTabDelegate: BonsplitDelegate {
    func splitTabBar(
        _ controller: BonsplitController,
        shouldCreateTab tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) -> Bool {
        false
    }
}

@MainActor
@Suite("Terminal startup restore failure handling", .serialized)
struct TerminalStartupRestoreFailureTests {
    @Test("Transferred persistent SSH restore adopts the destination owner")
    func transferredPersistentSSHRestoreRetargetsRemoteOwner() throws {
        let panelID = UUID()
        let sourceWorkspaceID = UUID()
        let destinationWorkspaceID = UUID()
        let persistentPTYSessionID = "persistent-transfer-session"
        let sourceContext = SurfaceResumeRemoteContext(
            workspaceID: sourceWorkspaceID,
            surfaceID: panelID,
            persistentPTYSessionID: persistentPTYSessionID
        )
        let destinationContext = SurfaceResumeRemoteContext(
            workspaceID: destinationWorkspaceID,
            surfaceID: panelID,
            persistentPTYSessionID: " \(persistentPTYSessionID) "
        )
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume persistent-transfer-session",
            cwd: "/tmp/persistent-transfer-session",
            checkpointId: persistentPTYSessionID,
            source: "agent-hook",
            autoResume: true,
            launchFlavor: .persistentSSH(sourceContext),
            updatedAt: 1_800_000_304
        )
        let restore = DeferredAgentResumeRestore(
            stablePanelID: panelID,
            restorableAgent: nil,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: true,
            remoteResumeContext: sourceContext,
            remoteResumeCommandEmbedded: true,
            workingDirectory: binding.cwd,
            resumeWorkingDirectory: binding.cwd
        )

        let retargeted = restore.retargetingRemoteOwner(destinationContext)
        #expect(retargeted.remoteResumeContext == destinationContext)
        #expect(retargeted.remoteResumeCommandEmbedded)
        #expect(
            retargeted.resumeBinding == binding.retargetingRemoteOwner(
                expectedWorkspaceID: sourceWorkspaceID,
                expectedSurfaceID: panelID,
                workspaceID: destinationWorkspaceID,
                surfaceID: panelID,
                persistentPTYSessionID: destinationContext.persistentPTYSessionID
            )
        )

        let mismatchedSession = restore.retargetingRemoteOwner(
            SurfaceResumeRemoteContext(
                workspaceID: destinationWorkspaceID,
                surfaceID: panelID,
                persistentPTYSessionID: "different-session"
            )
        )
        #expect(mismatchedSession.remoteResumeContext == sourceContext)

        let localRestore = DeferredAgentResumeRestore(
            stablePanelID: panelID,
            restorableAgent: nil,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: false,
            remoteResumeContext: sourceContext,
            workingDirectory: binding.cwd,
            resumeWorkingDirectory: binding.cwd
        )
        #expect(
            localRestore.retargetingRemoteOwner(destinationContext)
                .remoteResumeContext == sourceContext
        )
    }

    @Test("Failed Dock adoption clears source-owned hibernation tracking")
    func failedDockAdoptionClearsSourceHibernationTracking() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let source = Workspace(agentSessionAutoResumeDefaults: defaults.store)
        defer { source.teardownAllPanels() }
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults.store
        )
        let rejectingDelegate = RejectingRestoreTabDelegate()
        dock.bonsplitController.delegate = rejectingDelegate
        defer {
            dock.bonsplitController.delegate = dock
            dock.closeAllPanels()
        }

        let savedPanelID = UUID()
        let sourceKey = AgentHibernationPanelKey(
            workspaceId: source.id,
            panelId: savedPanelID
        )
        let controller = AgentHibernationController.shared
        controller.activityByPanel[sourceKey] = 1
        controller.terminalInputByPanel[sourceKey] = 2
        controller.lifecycleChangeByPanel[sourceKey] = 3
        controller.teardownValidationEpochByPanel[sourceKey] = 4
        defer {
            controller.discardTrackingStateForClosedPanel(
                workspaceId: source.id,
                panelId: savedPanelID
            )
            controller.discardTrackingStateForClosedPanel(
                workspaceId: dock.workspaceId,
                panelId: savedPanelID
            )
        }

        let sessionID = "failed-dock-adoption-\(UUID().uuidString)"
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/tmp/failed-dock-adoption",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex", "resume", sessionID],
                workingDirectory: "/tmp/failed-dock-adoption",
                environment: [:],
                capturedAt: 1_800_000_301,
                source: "process"
            )
        )
        let panelSnapshot = SessionPanelSnapshot(
            id: savedPanelID,
            type: .terminal,
            title: "Failed Dock adoption",
            customTitle: nil,
            directory: agent.workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: agent.workingDirectory,
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

        #expect(restoredIDs[savedPanelID] == nil)
        #expect(controller.activityByPanel[sourceKey] == nil)
        #expect(controller.terminalInputByPanel[sourceKey] == nil)
        #expect(controller.lifecycleChangeByPanel[sourceKey] == nil)
        #expect(controller.teardownValidationEpochByPanel[sourceKey] == nil)
    }

    @Test("Closing a staged relaunch cancels its restore transaction and releases its claim")
    func closingStagedRelaunchCancelsRestore() throws {
        let sessionID = "closed-staged-restore-\(UUID().uuidString)"
        let workingDirectory = "/tmp/closed-staged-restore"
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex", "resume", sessionID],
                workingDirectory: workingDirectory,
                environment: [:],
                capturedAt: 1_800_000_302,
                source: "process"
            )
        )
        defer {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: agent.kind.rawValue,
                sessionId: sessionID
            )
        }
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let recorder = AgentChatResumeIntentRecorder { _ in }
        let source = Workspace(
            workingDirectory: workingDirectory,
            initialTerminalInput: " cmux restore codex \(sessionID)\n",
            initialTerminalStartupRestoreAgent: agent,
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: recorder
        )
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        let persisted = source.sessionSnapshot(includeScrollback: false)

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: recorder,
            // Keep ownership lookup deterministic rather than racing the
            // separate deferred-admission coordinator.
            restorableAgentIndexProvider: { .empty }
        )
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(
            persisted,
            startupRestoreCommitOwner: .tabManagerTopology
        )
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(!restoredPanel.surface.canCreateRuntimeSurface)
        // Local restores claim at the CLI pre-exec boundary. Seed an owned
        // transaction here to exercise the separate remote/compatibility
        // claim-release path that panel teardown must still cover.
        #expect(
            AgentResumeLaunchGuard.shared.claimResumeLaunchWithToken(
                kind: agent.kind.rawValue,
                sessionId: sessionID
            ) != nil
        )
        restored.terminalStartupRestoreCoordinator.stage(
            panel: restoredPanel,
            snapshot: agent,
            manualResumeAvailable: true,
            willRunStartupCommand: false,
            willRunStartupInput: false,
            resumeWorkingDirectory: workingDirectory,
            ownsResumeLaunchClaim: true,
            defersStartupRestoreAdmission: true
        )
        #expect(
            !AgentResumeLaunchGuard.shared.claimResumeLaunch(
                kind: agent.kind.rawValue,
                sessionId: sessionID
            )
        )

        #expect(restored.closePanel(restoredPanelID, force: true))
        #expect(restored.terminalPanel(for: restoredPanelID) == nil)
        #expect(restoredPanel.surface.debugTeardownRequest().requestedAt != nil)
        #expect(
            AgentResumeLaunchGuard.shared.claimResumeLaunch(
                kind: agent.kind.rawValue,
                sessionId: sessionID
            )
        )

        restored.terminalStartupRestoreCoordinator.commitPendingRestores(
            panelIDs: [restoredPanelID]
        )
        #expect(restored.restoredAgentSnapshotsByPanelId[restoredPanelID] == nil)
    }

    @Test("Cancelling a binding-only deferred resume retires automatic ownership")
    func cancellingBindingOnlyDeferredResumeRetiresAutomaticOwnership() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults.store)
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "binding-only-cancel-(UUID().uuidString)"
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume (sessionID)",
            cwd: "/tmp/binding-only-cancel",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_800_000_303
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = binding
        let restore = DeferredAgentResumeRestore(
            stablePanelID: panelID,
            restorableAgent: nil,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: false,
            workingDirectory: binding.cwd,
            resumeWorkingDirectory: binding.cwd
        )
        workspace.deferredAgentResumeRestoresByPanelId[panelID] = restore
        workspace.restoredAgentLifecycle.setResumeState(
            .awaitingAutoResumeCommand,
            panelId: panelID
        )
        var replacementBinding = binding
        replacementBinding.checkpointId = "replacement-(UUID().uuidString)"
        replacementBinding.command = "codex resume (replacementBinding.checkpointId!)"
        workspace.surfaceResumeBindingsByPanelId[panelID] = replacementBinding

        workspace.cancelDeferredAgentResumeRestore(
            panelId: panelID,
            restore: restore
        )

        #expect(workspace.deferredAgentResumeRestoresByPanelId[panelID] == nil)
        #expect(
            workspace.restoredAgentResumeStatesByPanelId[panelID]
                == .manualResumeAvailable
        )
        #expect(workspace.surfaceResumeBindingsByPanelId[panelID]?.autoResume == true)
    }

    private func makeAutoResumeDefaults() throws -> (store: UserDefaults, name: String) {
        let name = "cmux-terminal-startup-failure-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        store.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        return (store, name)
    }

}
