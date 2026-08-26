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
    @Test("Binding-only persistent SSH resume waits for topology admission")
    func persistentSSHBindingOnlyResumeWaitsForTopologyAdmission() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let source = Workspace(agentSessionAutoResumeDefaults: defaults.store)
        defer { source.teardownAllPanels() }
        source.configureRemoteConnection(remoteConfiguration(), autoConnect: false)

        let savedPanelID = try #require(source.focusedPanelId)
        let remotePTYSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: source.id,
            panelId: savedPanelID
        )
        source.remotePTYSessionIDsByPanelId[savedPanelID] = remotePTYSessionID
        source.surfaceResumeBindingsByPanelId[savedPanelID] = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "cd '/srv/project' && codex resume persistent-ssh-session",
            cwd: "/srv/project",
            checkpointId: "persistent-ssh-session",
            source: "agent-hook",
            autoResume: true,
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: source.id,
                surfaceID: savedPanelID,
                persistentPTYSessionID: remotePTYSessionID
            )),
            updatedAt: 1_800_000_300
        )
        source.updatePanelShellActivityState(
            panelId: savedPanelID,
            state: .commandRunning
        )
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let savedPanelIndex = try #require(
            snapshot.panels.firstIndex { $0.id == savedPanelID }
        )
        snapshot.panels[savedPanelIndex].terminal?.wasAgentRunning = true
        #expect(snapshot.panels[savedPanelIndex].terminal?.agent == nil)
        #expect(snapshot.panels[savedPanelIndex].terminal?.wasAgentRunning == true)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults.store)
        defer { restored.teardownAllPanels() }
        let restoredIDs = restored.restoreSessionSnapshot(
            snapshot,
            startupRestoreCommitOwner: .tabManagerTopology
        )
        let restoredPanelID = try #require(restoredIDs[savedPanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        let startupCommand = try #require(restoredPanel.surface.debugInitialCommand())
        let remoteCommand = try decodedRemoteCommand(from: startupCommand)
        let initialCommand = try decodedInitialCommand(from: remoteCommand)

        #expect(startupCommand.contains("ssh-pty-attach"))
        #expect(initialCommand.contains("/srv/project"), "\(initialCommand)")
        #expect(initialCommand.contains("codex resume persistent-ssh-session"), "\(initialCommand)")
        #expect(!initialCommand.contains("cmux restore"), "\(initialCommand)")
        #expect(!restoredPanel.surface.canCreateRuntimeSurface)

        restored.terminalStartupRestoreCoordinator.commitPendingRestores(
            panelIDs: [restoredPanelID]
        )
        // Topology publication alone does not admit an ownership-sensitive
        // resume. The deferred resolver must still accept or cancel it from
        // the fresh shared index before the runtime can start.
        #expect(!restoredPanel.surface.canCreateRuntimeSurface)
        #expect(restored.deferredAgentResumeRestoresByPanelId[restoredPanelID] != nil)
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

    @Test("Closing a staged relaunch cancels its restore transaction")
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
            // This test exercises cancellation of a synchronously claimed
            // restore transaction; keep ownership lookup deterministic rather
            // than racing the separate deferred-admission coordinator.
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

    private func decodedRemoteCommand(from startupCommand: String) throws -> String {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(startupCommand).map(\.value)
        let script = try #require(words.dropFirst(2).first)
        let range = try #require(
            script.range(of: #"--command-b64 [A-Za-z0-9+/=]+"#, options: .regularExpression)
        )
        let encoded = String(script[range]).split(separator: " ", maxSplits: 1).last.map(String.init)
        let data = try #require(encoded.flatMap { Data(base64Encoded: $0) })
        return try #require(String(data: data, encoding: .utf8))
    }

    private func decodedInitialCommand(from bootstrap: String) throws -> String {
        let payloadLine = try #require(bootstrap.split(separator: "\n").first { line in
            line.contains("printf %s '") && line.contains("> \"$cmux_initial_command_tmp\"")
        })
        let prefixRange = try #require(payloadLine.range(of: "printf %s '"))
        let encodedSuffix = payloadLine[prefixRange.upperBound...]
        let closingQuote = try #require(encodedSuffix.firstIndex(of: "'"))
        let encodedCommand = String(encodedSuffix[..<closingQuote])
        let data = try #require(Data(base64Encoded: encodedCommand))
        return try #require(String(data: data, encoding: .utf8))
    }

    private func remoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            transport: .ssh,
            terminalTransport: .ssh,
            destination: "dev@example.com",
            port: 22,
            identityFile: nil,
            sshOptions: ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil,
            relayPort: 64_089,
            relayID: "relay-terminal-startup-failure",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-terminal-startup-failure.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(
                requireExisting: false
            ),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-terminal-startup-failure"
        )
    }
}
