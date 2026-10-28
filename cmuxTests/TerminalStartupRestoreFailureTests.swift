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
            workingDirectory: binding.cwd,
            resumeWorkingDirectory: binding.cwd
        )

        let retargeted = restore.retargetingRemoteOwner(destinationContext)
        #expect(retargeted.remoteResumeContext == destinationContext)
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
        let restoreBatch = SurfaceResumeRunPromptBatch.shared
        restoreBatch.reset()
        restoreBatch.beginRestorePass()
        defer { restoreBatch.reset() }
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
        #expect(restoreBatch.claimAgentRestore(kind: "codex", sessionID: sessionID) == .owner)
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

    @Test("Dock restore starts a duplicated Codex checkpoint once and keeps the copy recoverable")
    func duplicateCodexCheckpointClaimsOneRestoreOwner() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults.store,
            restorableAgentIndexProvider: { .empty }
        )
        defer { dock.closeAllPanels() }

        let sessionID = "duplicate-codex-checkpoint-\(UUID().uuidString)"
        let workingDirectory = "/tmp/duplicate-codex-checkpoint"
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
                capturedAt: 1_800_000_305,
                source: "process"
            )
        )

        func panel(_ id: UUID) -> SessionPanelSnapshot {
            SessionPanelSnapshot(
                id: id,
                type: .terminal,
                title: "Codex duplicate",
                directory: workingDirectory,
                isPinned: false,
                isManuallyUnread: false,
                gitBranch: nil,
                listeningPorts: [],
                ttyName: nil,
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: workingDirectory,
                    agent: agent,
                    wasAgentRunning: true
                )
            )
        }

        let firstID = UUID()
        let secondID = UUID()
        let snapshot = SessionSplitContainerSnapshot(
            focusedPanelId: firstID,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [firstID, secondID],
                selectedPanelId: firstID
            )),
            panels: [panel(firstID), panel(secondID)]
        )

        let restoreBatch = SurfaceResumeRunPromptBatch.shared
        restoreBatch.reset()
        restoreBatch.beginRestorePass()
        defer {
            restoreBatch.endRestorePass()
            restoreBatch.reset()
        }
        let restoredIDs = dock.restoreSessionSnapshot(snapshot)

        let firstPanelID = try #require(restoredIDs[firstID])
        let secondPanelID = try #require(restoredIDs[secondID])
        let firstPanel = try #require(dock.panels[firstPanelID] as? TerminalPanel)
        let secondPanel = try #require(dock.panels[secondPanelID] as? TerminalPanel)

        let firstInput = firstPanel.surface.debugInitialInputForTesting()
        let secondInput = secondPanel.surface.debugInitialInputForTesting()
        #expect([firstInput, secondInput].compactMap { $0 }.count == 1)
        #expect(firstInput?.contains(sessionID) == true || secondInput?.contains(sessionID) == true)
        let recoveryStates = [firstPanel.restoreRecovery.state, secondPanel.restoreRecovery.state]
        #expect(
            recoveryStates.contains {
                if case .failed(let reason, let recoveryInput) = $0 {
                    return reason == "duplicate-restore-owner" && recoveryInput?.contains(sessionID) == true
                }
                return false
            }
        )
    }

    @Test("Dock restore starts every distinct checkpoint once when one of them is duplicated")
    func dockRestoreStartsDistinctCheckpointsOnceWithOneDuplicate() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults.store,
            restorableAgentIndexProvider: { .empty }
        )
        defer { dock.closeAllPanels() }

        let workingDirectory = "/tmp/distinct-codex-checkpoints"
        let sessionIDs = (0..<14).map { "distinct-codex-\($0)-\(UUID().uuidString)" }
        // Fourteen distinct checkpoints, then a second copy of the last one.
        let panels = (sessionIDs + [sessionIDs[13]]).enumerated().map { offset, sessionID in
            Self.codexPanel(
                id: UUID(),
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                capturedAt: 1_800_000_400 + TimeInterval(offset)
            )
        }
        let snapshot = SessionSplitContainerSnapshot(
            focusedPanelId: panels[0].id,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: panels.map(\.id),
                selectedPanelId: panels[0].id
            )),
            panels: panels
        )

        let restoreBatch = SurfaceResumeRunPromptBatch.shared
        restoreBatch.reset()
        restoreBatch.beginRestorePass()
        defer {
            restoreBatch.endRestorePass()
            restoreBatch.reset()
        }
        let restoredIDs = dock.restoreSessionSnapshot(snapshot)
        let restored = try panels.map { panel in
            let restoredID = try #require(restoredIDs[panel.id])
            return try #require(dock.panels[restoredID] as? TerminalPanel)
        }

        // No budget: every distinct checkpoint starts, and only the extra
        // copy of the last one is held back as a duplicate.
        for (index, sessionID) in sessionIDs.enumerated() {
            #expect(restored[index].surface.debugInitialInputForTesting()?.contains(sessionID) == true)
        }
        let duplicate = restored[14]
        #expect(duplicate.surface.debugInitialInputForTesting() == nil)
        #expect(dock.deferredAgentResumeRestoresByPanelId[duplicate.id] == nil)
        if case .failed(let reason, let recoveryInput) = duplicate.restoreRecovery.state {
            #expect(reason == "duplicate-restore-owner")
            #expect(recoveryInput?.contains(sessionIDs[13]) == true)
        } else {
            Issue.record("the duplicate copy should be marked duplicate-restore-owner")
        }
    }

    @Test("Dock restore starts a hook-binding-only checkpoint once")
    func dockRestoreStartsHookBindingCheckpointOnce() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults.store,
            restorableAgentIndexProvider: { .empty }
        )
        defer { dock.closeAllPanels() }

        let sessionID = "hook-binding-checkpoint-\(UUID().uuidString)"
        let workingDirectory = "/tmp/hook-binding-checkpoint"
        let panels = [UUID(), UUID()].map {
            Self.hookBindingPanel(id: $0, sessionID: sessionID, workingDirectory: workingDirectory)
        }
        let snapshot = SessionSplitContainerSnapshot(
            focusedPanelId: panels[0].id,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: panels.map(\.id),
                selectedPanelId: panels[0].id
            )),
            panels: panels
        )

        let restoreBatch = SurfaceResumeRunPromptBatch.shared
        restoreBatch.reset()
        restoreBatch.beginRestorePass()
        defer {
            restoreBatch.endRestorePass()
            restoreBatch.reset()
        }
        let restoredIDs = dock.restoreSessionSnapshot(snapshot)
        let inputs = try panels.map { panel in
            let restoredID = try #require(restoredIDs[panel.id])
            return try #require(dock.panels[restoredID] as? TerminalPanel)
                .surface.debugInitialInputForTesting()
        }
        #expect(inputs.compactMap { $0 }.count == 1)
        #expect(inputs.compactMap { $0 }.first?.contains(sessionID) == true)
    }

    @Test("A hook binding does not start a checkpoint an agent panel already starts")
    func dockHookBindingDoesNotStartAClaimedCheckpoint() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults.store,
            restorableAgentIndexProvider: { .empty }
        )
        defer { dock.closeAllPanels() }

        let sessionID = "agent-then-hook-\(UUID().uuidString)"
        let workingDirectory = "/tmp/agent-then-hook"
        let agentPanel = Self.codexPanel(
            id: UUID(),
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            capturedAt: 1_800_000_450
        )
        let hookPanel = Self.hookBindingPanel(
            id: UUID(),
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            kind: "codex",
            command: "codex resume \(sessionID)"
        )
        let snapshot = SessionSplitContainerSnapshot(
            focusedPanelId: agentPanel.id,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [agentPanel.id, hookPanel.id],
                selectedPanelId: agentPanel.id
            )),
            panels: [agentPanel, hookPanel]
        )

        let restoreBatch = SurfaceResumeRunPromptBatch.shared
        restoreBatch.reset()
        restoreBatch.beginRestorePass()
        defer {
            restoreBatch.endRestorePass()
            restoreBatch.reset()
        }
        let restoredIDs = dock.restoreSessionSnapshot(snapshot)
        let restoredAgentID = try #require(restoredIDs[agentPanel.id])
        let restoredHookID = try #require(restoredIDs[hookPanel.id])
        let restoredAgent = try #require(dock.panels[restoredAgentID] as? TerminalPanel)
        let restoredHook = try #require(dock.panels[restoredHookID] as? TerminalPanel)
        #expect(restoredAgent.surface.debugInitialInputForTesting()?.contains(sessionID) == true)
        #expect(restoredHook.surface.debugInitialInputForTesting() == nil)
    }

    @Test("A hibernated copy never owns a checkpoint")
    func dockHibernatedCopyDoesNotOwnCheckpoint() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults.store,
            restorableAgentIndexProvider: { .empty }
        )
        defer { dock.closeAllPanels() }

        let sessionID = "hibernated-copy-\(UUID().uuidString)"
        let workingDirectory = "/tmp/hibernated-copy"
        var hibernated = Self.codexPanel(
            id: UUID(),
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            capturedAt: 1_800_000_460
        )
        hibernated.terminal?.hibernation = SessionAgentHibernationSnapshot(
            hibernatedAt: 120,
            lastActivityAt: 119
        )
        let live = Self.codexPanel(
            id: UUID(),
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            capturedAt: 1_800_000_461
        )
        let copy = Self.codexPanel(
            id: UUID(),
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            capturedAt: 1_800_000_462
        )
        let panels = [hibernated, live, copy]
        let snapshot = SessionSplitContainerSnapshot(
            focusedPanelId: hibernated.id,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: panels.map(\.id),
                selectedPanelId: hibernated.id
            )),
            panels: panels
        )

        let restoreBatch = SurfaceResumeRunPromptBatch.shared
        restoreBatch.reset()
        restoreBatch.beginRestorePass()
        defer {
            restoreBatch.endRestorePass()
            restoreBatch.reset()
        }
        let restoredIDs = dock.restoreSessionSnapshot(snapshot)
        let restored = try panels.map { panel in
            let restoredID = try #require(restoredIDs[panel.id])
            return try #require(dock.panels[restoredID] as? TerminalPanel)
        }
        // The hibernated copy stays hibernated without taking the checkpoint,
        // so the first non-hibernated copy starts it and the next is held.
        #expect(restored[0].surface.debugInitialInputForTesting() == nil)
        #expect(restored[1].surface.debugInitialInputForTesting()?.contains(sessionID) == true)
        #expect(restored[2].surface.debugInitialInputForTesting() == nil)
    }

    private static func codexPanel(
        id: UUID,
        sessionID: String,
        workingDirectory: String,
        capturedAt: TimeInterval
    ) -> SessionPanelSnapshot {
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
                capturedAt: capturedAt,
                source: "process"
            )
        )
        return SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "Codex",
            directory: workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: workingDirectory,
                agent: agent,
                wasAgentRunning: true
            )
        )
    }

    private static func hookBindingPanel(
        id: UUID,
        sessionID: String,
        workingDirectory: String,
        kind: String = "pi",
        command: String? = nil
    ) -> SessionPanelSnapshot {
        let binding = SurfaceResumeBindingSnapshot(
            name: kind,
            kind: kind,
            command: command ?? "pi --session \(sessionID)",
            cwd: workingDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            approvalPolicy: .auto,
            updatedAt: 1_800_000_500
        )
        return SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "Hook binding",
            directory: workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: workingDirectory,
                resumeBinding: binding,
                wasAgentRunning: true
            )
        )
    }

    @Test("Workspace restore claims one duplicate Codex checkpoint owner")
    func duplicateCodexCheckpointClaimsOneWorkspaceRestoreOwner() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }

        let sessionID = "duplicate-workspace-codex-\(UUID().uuidString)"
        let workingDirectory = "/tmp/duplicate-workspace-codex"
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
                capturedAt: 1_800_000_306,
                source: "process"
            )
        )

        let source = Workspace(
            workingDirectory: workingDirectory,
            agentSessionAutoResumeDefaults: defaults.store,
            restorableAgentIndexProvider: { .empty }
        )
        defer { source.teardownAllPanels() }
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let originalPanel = try #require(snapshot.panels.first)
        var firstPanel = originalPanel
        var firstTerminal = try #require(firstPanel.terminal)
        firstTerminal.agent = agent
        firstTerminal.wasAgentRunning = true
        firstPanel.terminal = firstTerminal
        var secondPanel = firstPanel
        secondPanel.id = UUID()
        snapshot.panels = [firstPanel, secondPanel]
        snapshot.focusedPanelId = firstPanel.id
        snapshot.layout = .pane(SessionPaneLayoutSnapshot(
            panelIds: [firstPanel.id, secondPanel.id],
            selectedPanelId: firstPanel.id
        ))

        let restoreBatch = SurfaceResumeRunPromptBatch.shared
        restoreBatch.reset()
        restoreBatch.beginRestorePass()
        defer {
            restoreBatch.endRestorePass()
            restoreBatch.reset()
        }

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            restorableAgentIndexProvider: { .empty }
        )
        defer { restored.teardownAllPanels() }
        let remap = restored.restoreSessionSnapshot(
            snapshot,
            startupRestoreCommitOwner: .workspaceTopology
        )
        let restoredPanels = remap.values.compactMap { restored.terminalPanel(for: $0) }
        #expect(restoredPanels.count == 2)
        let startupInputs = restoredPanels.compactMap { $0.surface.debugInitialInputForTesting() }
        #expect(startupInputs.count == 1)
        #expect(startupInputs.first?.contains(sessionID) == true)
        #expect(
            restoredPanels.contains {
                if case .failed(let reason, let recoveryInput) = $0.restoreRecovery.state {
                    return reason == "duplicate-restore-owner" && recoveryInput?.contains(sessionID) == true
                }
                return false
            }
        )
    }

    @Test("An unavailable index queues a hook checkpoint only once", arguments: [false, true])
    func unavailableIndexQueuesHookCheckpointOnce(inDock: Bool) throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let sessionID = "deferred-hook-\(UUID().uuidString)"
        let panels = [UUID(), UUID()].map { id in
            var panel = Self.hookBindingPanel(
                id: id,
                sessionID: sessionID,
                workingDirectory: "/tmp/deferred-hook"
            )
            panel.terminal?.isRemoteTerminal = true
            return panel
        }
        let layout = SessionWorkspaceLayoutSnapshot.pane(SessionPaneLayoutSnapshot(
            panelIds: panels.map(\.id),
            selectedPanelId: panels[0].id
        ))
        let batch = SurfaceResumeRunPromptBatch.shared
        batch.reset()
        batch.beginRestorePass()
        defer { batch.reset() }

        func check(_ restored: [TerminalPanel], deferredIDs: Set<UUID>) throws {
            #expect(restored.count == 2)
            let first = try #require(restored.first)
            let duplicate = try #require(restored.last)
            #expect(first.surface.debugInitialInputForTesting()?.contains(sessionID) == true)
            #expect(deferredIDs == [first.id])
            #expect(duplicate.surface.debugInitialInputForTesting() == nil)
            if case .failed(let reason, let recoveryInput) = duplicate.restoreRecovery.state {
                #expect(reason == "duplicate-restore-owner")
                #expect(recoveryInput?.contains(sessionID) == true)
                if !inDock {
                    #expect(recoveryInput?.contains("cmux restore") == false)
                }
            } else {
                Issue.record("a deferred duplicate must stay manually recoverable")
            }
        }

        if inDock {
            let dock = DockSplitStore(
                workspaceId: UUID(),
                baseDirectoryProvider: { nil },
                agentSessionAutoResumeDefaults: defaults.store,
                restorableAgentIndexProvider: { .unavailable }
            )
            defer { dock.closeAllPanels() }
            let remap = dock.restoreSessionSnapshot(SessionSplitContainerSnapshot(
                focusedPanelId: panels[0].id,
                layout: layout,
                panels: panels
            ))
            let restored = try panels.map { panel in
                let id = try #require(remap[panel.id])
                return try #require(dock.panels[id] as? TerminalPanel)
            }
            try check(restored, deferredIDs: Set(dock.deferredAgentResumeRestoresByPanelId.keys))
        } else {
            let workspace = Workspace(
                agentSessionAutoResumeDefaults: defaults.store,
                restorableAgentIndexProvider: { .unavailable }
            )
            defer { workspace.teardownAllPanels() }
            workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
                destination: "restore-test.invalid",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64_000,
                relayID: "restore-test",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/restore-test-\(UUID().uuidString).sock",
                terminalStartupCommand: "ssh restore-test.invalid"
            )
            var snapshot = workspace.sessionSnapshot(includeScrollback: false)
            snapshot.panels = panels
            snapshot.layout = layout
            snapshot.focusedPanelId = panels[0].id
            let remap = workspace.restoreSessionSnapshot(
                snapshot,
                startupRestoreCommitOwner: .workspaceTopology
            )
            let restored = try panels.map { panel in
                let id = try #require(remap[panel.id])
                return try #require(workspace.terminalPanel(for: id))
            }
            try check(restored, deferredIDs: Set(workspace.deferredAgentResumeRestoresByPanelId.keys))
        }
    }

    @Test("Path and hook UUID aliases start one checkpoint across restore containers",
          arguments: [false, true], ["pi", "omp"])
    func pathCheckpointAliasesStartOnce(inDock: Bool, kind: String) throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let sessionID = UUID().uuidString.lowercased()
        let path = "/tmp/restore sessions/2026-10-28_\(sessionID).jsonl"
        let agentKind = try #require(RestorableAgentKind(rawValue: kind))
        var first = Self.codexPanel(
            id: UUID(), sessionID: path, workingDirectory: "/tmp", capturedAt: 1
        )
        first.terminal?.agent = SessionRestorableAgentSnapshot(
            kind: agentKind, sessionId: path, workingDirectory: "/tmp", launchCommand: nil
        )
        var copy = first
        copy.id = UUID()
        let hook = Self.hookBindingPanel(
            id: UUID(), sessionID: sessionID, workingDirectory: "/tmp",
            kind: kind, command: "\(kind) --session \(sessionID)"
        )
        let panels = [first, copy, hook]
        let layout = SessionWorkspaceLayoutSnapshot.pane(SessionPaneLayoutSnapshot(
            panelIds: panels.map(\.id), selectedPanelId: first.id
        ))
        let batch = SurfaceResumeRunPromptBatch.shared
        batch.reset()
        batch.beginRestorePass()
        defer { batch.reset() }

        func check(_ restored: [TerminalPanel]) {
            #expect(restored.count == 3)
            // A path cannot be sent as an unquoted CLI argument. The valid
            // --surface route must still own its canonical checkpoint.
            #expect(restored.first?.surface.debugInitialInputForTesting() == " cmux restore --surface\n")
            for duplicate in restored.dropFirst() {
                #expect(duplicate.surface.debugInitialInputForTesting() == nil)
                if case .failed(let reason, let input) = duplicate.restoreRecovery.state {
                    #expect(reason == "duplicate-restore-owner")
                    #expect(input != nil)
                } else {
                    Issue.record("each alias must remain recoverable without starting a writer")
                }
            }
        }

        if inDock {
            let dock = DockSplitStore(
                workspaceId: UUID(), baseDirectoryProvider: { nil },
                agentSessionAutoResumeDefaults: defaults.store,
                restorableAgentIndexProvider: { .empty }
            )
            defer { dock.closeAllPanels() }
            let remap = dock.restoreSessionSnapshot(SessionSplitContainerSnapshot(
                focusedPanelId: first.id, layout: layout, panels: panels
            ))
            let restored = try panels.map { panel in
                let id = try #require(remap[panel.id])
                return try #require(dock.panels[id] as? TerminalPanel)
            }
            check(restored)
        } else {
            let workspace = Workspace(
                agentSessionAutoResumeDefaults: defaults.store,
                restorableAgentIndexProvider: { .empty }
            )
            defer { workspace.teardownAllPanels() }
            var snapshot = workspace.sessionSnapshot(includeScrollback: false)
            snapshot.panels = panels
            snapshot.layout = layout
            snapshot.focusedPanelId = first.id
            let remap = workspace.restoreSessionSnapshot(snapshot, startupRestoreCommitOwner: .workspaceTopology)
            let restored = try panels.map { panel in
                let id = try #require(remap[panel.id])
                return try #require(workspace.terminalPanel(for: id))
            }
            check(restored)
        }
    }

    @Test("A persistent PTY attachment does not claim a checkpoint needed by a later launch")
    func persistentPTYAttachmentDoesNotClaimCheckpoint() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let workspace = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            restorableAgentIndexProvider: { .unavailable }
        )
        defer { workspace.teardownAllPanels() }
        workspace.configureRemoteConnection(WorkspaceRemoteConfiguration(
            destination: "restore-test.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_000,
            relayID: "restore-pty-test",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/restore-pty-\(UUID().uuidString).sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(requireExisting: false),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "restore-pty-test"
        ), autoConnect: false)
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let sessionID = "pty-checkpoint-\(UUID().uuidString)"
        var attachedSnapshot = Self.codexPanel(
            id: UUID(), sessionID: sessionID, workingDirectory: "/tmp", capturedAt: 1
        )
        attachedSnapshot.terminal?.isRemoteTerminal = true
        attachedSnapshot.terminal?.remotePTYSessionID = "existing-pty"
        let batch = SurfaceResumeRunPromptBatch.shared
        batch.reset()
        batch.beginRestorePass()
        defer { batch.reset() }
        let attachedID = try #require(workspace.createPanel(
            from: attachedSnapshot, inPane: paneID, snapshotWorkspaceId: workspace.id,
            shouldRestoreSingleDefaultCloudTerminal: false, restorableAgentIndex: .unavailable
        ))
        let attached = try #require(workspace.terminalPanel(for: attachedID))
        #expect(workspace.remotePTYSessionIDsByPanelId[attachedID] == "existing-pty")
        #expect(attached.surface.debugInitialInputForTesting() == nil)
        #expect(workspace.deferredAgentResumeRestoresByPanelId[attachedID] == nil)

        var launchSnapshot = attachedSnapshot
        launchSnapshot.id = UUID()
        launchSnapshot.terminal?.isRemoteTerminal = false
        launchSnapshot.terminal?.remotePTYSessionID = nil
        let launchID = try #require(workspace.createPanel(
            from: launchSnapshot, inPane: paneID, snapshotWorkspaceId: workspace.id,
            shouldRestoreSingleDefaultCloudTerminal: false, restorableAgentIndex: .empty
        ))
        let launch = try #require(workspace.terminalPanel(for: launchID))
        #expect(launch.surface.debugInitialInputForTesting()?.contains(sessionID) == true)
    }

    private func makeAutoResumeDefaults() throws -> (store: UserDefaults, name: String) {
        let name = "cmux-terminal-startup-failure-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        store.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        return (store, name)
    }

}
