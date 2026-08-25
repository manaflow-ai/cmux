import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import CmuxCore
import CmuxSidebar
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentSessionAutoResumeSwiftTests {
    /// Regression for #9619: cmux-owned restore input is an implementation
    /// detail, not a user or agent title. Preserve the automatic title captured
    /// before relaunch through that bootstrap event, then accept the first real
    /// title reported by the resumed session.
    @MainActor
    @Test(arguments: ["codex", "claude"])
    func restoredAgentBootstrapDoesNotReplacePersistedAutomaticTitle(kind: String) throws {
        let defaultsName = "cmux-issue-9619-\(kind)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let checkpointID = "019fce9e-9619-7a11-8e20-123456789abc"
        let persistedTitle = "Pre-restore \(kind.capitalized) task"
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        #expect(source.updatePanelTitle(panelId: sourcePanelID, title: persistedTitle))
        #expect(source.customTitle == nil)
        #expect(source.panelCustomTitles[sourcePanelID] == nil)

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        terminalSnapshot.resumeBinding = SurfaceResumeBindingSnapshot(
            name: kind.capitalized,
            kind: kind,
            command: "\(kind) --resume \(checkpointID)",
            cwd: source.currentDirectory,
            checkpointId: checkpointID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_777_777_777
        )
        terminalSnapshot.wasAgentRunning = true
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        let restoredTabID = try #require(restored.surfaceIdFromPanelId(restoredPanelID))
        let bootstrapInput =
            " \(AgentRestoreLaunch.cliStartupExecutableToken) restore \(kind) \(checkpointID)\n"
        let bootstrapTitle = bootstrapInput.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(restoredPanel.surface.debugInitialInputForTesting() == bootstrapInput)
        #expect(restored.panelTitle(panelId: restoredPanelID) == persistedTitle)
        #expect(restored.title == persistedTitle)
        #expect(restored.processTitle == persistedTitle)
        #expect(restored.bonsplitController.tab(restoredTabID)?.title == persistedTitle)

        // Ghostty can deliver the shell's command title before cmux receives the
        // matching shell-activity transition. The internal event must be inert in
        // either order.
        #expect(!restored.updatePanelTitle(panelId: restoredPanelID, title: bootstrapTitle))
        #expect(restored.panelTitle(panelId: restoredPanelID) == persistedTitle)
        #expect(restored.title == persistedTitle)
        #expect(restored.processTitle == persistedTitle)
        #expect(restored.bonsplitController.tab(restoredTabID)?.title == persistedTitle)

        restored.updatePanelShellActivityState(panelId: restoredPanelID, state: .commandRunning)
        #expect(restored.panelTitle(panelId: restoredPanelID) == persistedTitle)

        let genuineTitle = "Resumed \(kind.capitalized) session"
        #expect(restored.updatePanelTitle(panelId: restoredPanelID, title: genuineTitle))
        #expect(restored.panelTitle(panelId: restoredPanelID) == genuineTitle)
        #expect(restored.title == genuineTitle)
        #expect(restored.processTitle == genuineTitle)
        #expect(restored.bonsplitController.tab(restoredTabID)?.title == genuineTitle)
    }

    /// The same restore-title boundary applies to an ordinary shell with no
    /// agent bootstrap. Startup's generic shell title stays hidden until a real
    /// post-prompt command begins, after which normal title updates resume.
    @MainActor
    @Test func restoredPlainShellPreservesTitleUntilUserCommand() throws {
        let persistedTitle = "Pre-restore shell task"
        let source = Workspace()
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        #expect(source.updatePanelTitle(panelId: sourcePanelID, title: persistedTitle))

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let restored = Workspace()
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        let restoredTabID = try #require(restored.surfaceIdFromPanelId(restoredPanelID))

        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(!restored.updatePanelTitle(panelId: restoredPanelID, title: "zsh"))
        #expect(restored.panelTitle(panelId: restoredPanelID) == persistedTitle)
        #expect(restored.title == persistedTitle)
        #expect(restored.processTitle == persistedTitle)
        #expect(restored.bonsplitController.tab(restoredTabID)?.title == persistedTitle)

        restored.updatePanelShellActivityState(panelId: restoredPanelID, state: .promptIdle)
        let commandTitle = "cd /tmp/cmux-issue-9619"
        #expect(!restored.updatePanelTitle(panelId: restoredPanelID, title: commandTitle))
        #expect(restored.title == persistedTitle)

        // The title event and asynchronous shell-state report may arrive in
        // either order. A buffered title becomes genuine at the command-running
        // boundary and normal title ownership resumes from there.
        restored.updatePanelShellActivityState(panelId: restoredPanelID, state: .promptIdle)
        #expect(restored.panelTitle(panelId: restoredPanelID) == persistedTitle)
        restored.updatePanelShellActivityState(panelId: restoredPanelID, state: .commandRunning)
        #expect(restored.panelTitle(panelId: restoredPanelID) == commandTitle)
        #expect(restored.title == commandTitle)
        #expect(restored.processTitle == commandTitle)
        #expect(restored.bonsplitController.tab(restoredTabID)?.title == commandTitle)

        restored.updatePanelShellActivityState(panelId: restoredPanelID, state: .promptIdle)
        let directoryTitle = "/tmp/cmux-issue-9619"
        #expect(restored.updatePanelTitle(panelId: restoredPanelID, title: directoryTitle))
        #expect(restored.panelTitle(panelId: restoredPanelID) == directoryTitle)
        #expect(restored.title == directoryTitle)
        #expect(restored.processTitle == directoryTitle)
        #expect(restored.bonsplitController.tab(restoredTabID)?.title == directoryTitle)
    }

    /// A restored terminal can move through a detached transfer before its
    /// startup boundary has admitted a genuine title. The destination must
    /// continue the same boundary instead of treating the next startup event as
    /// a fresh, user-owned title.
    @MainActor
    @Test func restoredTitleBoundarySurvivesDetachedSurfaceTransfer() throws {
        let persistedTitle = "Pre-transfer restored title"
        let snapshotSource = Workspace()
        defer { snapshotSource.teardownAllPanels() }
        let snapshotPanelID = try #require(snapshotSource.focusedPanelId)
        #expect(snapshotSource.updatePanelTitle(panelId: snapshotPanelID, title: persistedTitle))

        let restoredSource = Workspace()
        defer { restoredSource.teardownAllPanels() }
        let restoredPanelIDs = restoredSource.restoreSessionSnapshot(
            snapshotSource.sessionSnapshot(includeScrollback: false)
        )
        let restoredPanelID = try #require(restoredPanelIDs[snapshotPanelID])
        restoredSource.updatePanelShellActivityState(
            panelId: restoredPanelID,
            state: .promptIdle
        )

        let commandTitle = "cd /tmp/cmux-issue-9619-transfer"
        #expect(!restoredSource.updatePanelTitle(panelId: restoredPanelID, title: commandTitle))
        let detached = try #require(restoredSource.detachSurface(panelId: restoredPanelID))
        #expect(detached.restoredPanelTitleBoundary != nil)

        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockPaneID = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(
            dock.attachDetachedSurface(
                detached,
                inPane: dockPaneID,
                focus: false
            ) == restoredPanelID
        )

        // The Dock already owns the transferred promptIdle state. A duplicate
        // report must not discard the pending title before commandRunning.
        dock.updatePanelShellActivityState(panelId: restoredPanelID, state: .promptIdle)
        dock.updatePanelShellActivityState(panelId: restoredPanelID, state: .commandRunning)
        let detachedFromDock = try #require(dock.detachSurface(panelId: restoredPanelID))
        #expect(detachedFromDock.restoredPanelTitleBoundary == nil)

        let destination = Workspace()
        defer { destination.teardownAllPanels() }
        let destinationPaneID = try #require(destination.bonsplitController.allPaneIds.first)
        #expect(
            destination.attachDetachedSurface(
                detachedFromDock,
                inPane: destinationPaneID,
                focus: true
            ) == restoredPanelID
        )
        let destinationTabID = try #require(destination.surfaceIdFromPanelId(restoredPanelID))
        #expect(destination.panelTitle(panelId: restoredPanelID) == commandTitle)
        #expect(destination.title == commandTitle)
        #expect(destination.processTitle == commandTitle)
        #expect(destination.bonsplitController.tab(destinationTabID)?.title == commandTitle)
    }

    /// Regression for #8501: restoring an auto-resumed terminal reapplies the
    /// panel's friendly persisted title before workspace metadata. The
    /// workspace title must follow that restored focused panel instead of the
    /// serialized resume launcher stored in the legacy process-title field.
    @MainActor
    @Test func restoredAutoTitledWorkspaceUsesFocusedPanelTitleInsteadOfResumeCommand() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let sessionID = "644498fd-8501-4d8e-a2dc-7496ca299d28"
            let friendlyTitle = "phase-zero-approval-handoff"
            let resumeCommand =
                "'/Applications/cmux.app/Contents/Resources/bin/cmux-claude-wrapper' " +
                "'--dangerously-skip-permissions' '--resume' '\(sessionID)'"
            let source = Workspace()
            let sourcePanelID = try #require(source.focusedPanelId)
            source.updatePanelShellActivityState(panelId: sourcePanelID, state: .commandRunning)
            source.applyProcessTitle(resumeCommand)
            try #require(source.setPanelCustomTitle(panelId: sourcePanelID, title: friendlyTitle))

            // The resume launcher can report its raw command before the user's
            // session-name hook refreshes the surface name. A focused surface
            // rename must immediately repair the automatic workspace title.
            #expect(source.customTitle == nil)
            #expect(source.title == friendlyTitle)
            #expect(source.processTitle == friendlyTitle)

            // Recreate the legacy mismatch persisted by affected releases.
            source.applyProcessTitle(resumeCommand)

            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(
                    workspaceId: source.id,
                    panelId: sourcePanelID
                ): SurfaceResumeBindingSnapshot(
                    name: "Claude",
                    kind: "claude",
                    command: resumeCommand,
                    cwd: source.currentDirectory,
                    checkpointId: sessionID,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_777
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )

            #expect(snapshot.customTitle == nil)
            #expect(snapshot.processTitle == resumeCommand)
            #expect(snapshot.panels.first?.title == friendlyTitle)
            #expect(snapshot.panels.first?.terminal?.resumeBinding?.command.contains(resumeCommand) == true)

            let restored = Workspace()
            let restoredPanelIDs = restored.restoreSessionSnapshot(snapshot)
            let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])

            #expect(restored.customTitle == nil)
            #expect(restored.panelTitle(panelId: restoredPanelID) == friendlyTitle)
            #expect(restored.title == friendlyTitle)
            #expect(restored.processTitle == friendlyTitle)

            // A resumed shell may publish its serialized launcher again after
            // restore. The friendly focused-surface title must remain the
            // workspace's settled automatic title after that later event too.
            restored.updatePanelTitle(panelId: restoredPanelID, title: resumeCommand)
            #expect(restored.panelTitle(panelId: restoredPanelID) == friendlyTitle)
            #expect(restored.title == friendlyTitle)
            #expect(restored.processTitle == friendlyTitle)
        }
    }

    @MainActor
    @Test func sessionRestoreDropsPersistedAgentStatusRuntimeState() throws {
        let source = Workspace()
        let sourcePanelId = try #require(source.focusedPanelId)
        let pidKey = "claude_code.issue-6441"

        source.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input"
        )
        source.recordAgentPID(key: pidKey, pid: 42_424, panelId: sourcePanelId, refreshPorts: false)

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.statusEntries.contains { $0.key == "claude_code" })

        let restored = Workspace()
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[sourcePanelId])

        #expect(restored.statusEntries["claude_code"] == nil)
        #expect(restored.agentPIDs.isEmpty)
        #expect(restored.agentPIDPanelIdsByKey.isEmpty)
        #expect(restored.agentPIDKeysByPanelId.isEmpty)
        #expect(restored.agentHibernationLifecycleState(panelId: restoredPanelId, fallback: nil) == .unknown)
    }

    @MainActor
    @Test func detachedAgentRuntimeAdoptionPreservesSavedPIDIdentity() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let pidKey = "claude_code.detached-reused-pid"
        let livePid = getpid()
        let currentIdentity = try #require(Workspace.agentPIDProcessIdentity(pid: livePid))
        let savedIdentity = AgentPIDProcessIdentity(
            pid: livePid,
            startSeconds: currentIdentity.startSeconds &- 1,
            startMicroseconds: currentIdentity.startMicroseconds
        )

        workspace.adoptDetachedAgentRuntimeState(
            Workspace.DetachedAgentRuntimeState(
                panelId: panelId,
                statusEntries: [:],
                agentPIDs: [pidKey: livePid],
                agentPIDProcessIdentities: [pidKey: savedIdentity],
                agentPIDKeys: [pidKey]
            )
        )

        #expect(workspace.agentPIDProcessIdentitiesByKey[pidKey] == savedIdentity)
        #expect(workspace.clearStaleAgentPIDs(panelId: panelId, refreshPorts: false))
        #expect(workspace.agentPIDs[pidKey] == nil)
        #expect(workspace.agentPIDProcessIdentitiesByKey[pidKey] == nil)
    }

    @MainActor
    @Test func claudeAgentHookResumeBindingRestoresFromLaunchCwdWhenRuntimeCwdDrifted() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let source = Workspace()
            let sourcePanelId = try #require(source.focusedPanelId)
            let sessionId = "claude-drifted-binding-session"
            let launchCwd = "/tmp/cmux-claude-launch"
            let runtimeCwd = "/tmp/cmux-claude-runtime"
            let agent = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: sessionId,
                workingDirectory: launchCwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/usr/local/bin/claude",
                    arguments: ["/usr/local/bin/claude", "--model", "claude-opus-4-8"],
                    workingDirectory: launchCwd,
                    environment: ["CLAUDE_CONFIG_DIR": "/tmp/cmux-claude-config"],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            source.setRestoredAgentSnapshotForTesting(agent, panelId: sourcePanelId)

            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Claude",
                    kind: "claude",
                    command: "{ cd -- '\(runtimeCwd)' 2>/dev/null || [ ! -d '\(runtimeCwd)' ]; } && 'claude' '--resume' '\(sessionId)'",
                    cwd: runtimeCwd,
                    checkpointId: sessionId,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_777
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )

            #expect(snapshot.panels.first?.terminal?.agent?.workingDirectory == launchCwd)
            #expect(snapshot.panels.first?.terminal?.resumeBinding?.cwd == runtimeCwd)

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))

            try assertAgentAutoResumeUsesStartupInput(
                restoredPanel,
                scriptContains: [launchCwd, "--resume", sessionId],
                scriptDoesNotContain: [runtimeCwd]
            )
            #expect(
                restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.cwd == launchCwd
            )
        }
    }

    /// Regression for #6617: after Cmd+Q/restore of a workspace whose focused
    /// terminal is running an auto-resumed agent in a project directory, the
    /// resumed shell spawns in its default directory and shell integration
    /// reports that directory (typically home) before the agent-resume command
    /// cds into the project. While the project directory still exists that
    /// spurious live report must not overwrite the restored workspace cwd,
    /// otherwise Cmd+T opens the next tab in home (~) instead of the project
    /// directory the agent is in.
    @MainActor
    @Test func cmdTAfterAgentResumeRestoreKeepsProjectCwdDespiteSpuriousHomePwdReport() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            // A real on-disk project directory so the restore guard can confirm it
            // still exists and treat the resumed shell's home report as spurious.
            let projectDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-cmdt-resume-project-\(UUID().uuidString)", isDirectory: true)
                .path
            try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedClaudeAgent(
                savedDirectory: projectDir
            )

            // The resumed shell starts before its agent-resume command cds, so
            // shell integration reports home first. Because the project directory
            // still exists, this spurious live report must be ignored so the
            // restored project cwd survives.
            let spuriousHomeReport = FileManager.default.homeDirectoryForCurrentUser.path
            try #require(spuriousHomeReport != projectDir)
            restored.updatePanelDirectory(panelId: restoredPanelId, directory: spuriousHomeReport)

            #expect(restored.currentDirectory == projectDir)
            #expect(restored.panelDirectories[restoredPanelId] == projectDir)

            // Cmd+T must open the new tab in the project directory, not home.
            let createdPanel = try #require(restored.newTerminalSurfaceInFocusedPane(focus: false))
            #expect(createdPanel.requestedWorkingDirectory == projectDir)
        }
    }

    /// Companion to #6617: when the saved project directory was deleted between
    /// sessions, the agent-resume `cd` fails and the resumed shell's reported
    /// (home) directory is the real location, so it must be accepted rather than
    /// dropped as a spurious post-restore report (which would strand the cwd on
    /// the deleted path and make Cmd+T inherit an invalid directory).
    @MainActor
    @Test func agentResumeRestoreAcceptsHomePwdReportWhenSavedDirectoryWasDeleted() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            // A saved directory that no longer exists on disk (deleted between
            // sessions). It is intentionally never created.
            let deletedDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-cmdt-deleted-project-\(UUID().uuidString)", isDirectory: true)
                .path
            #expect(!FileManager.default.fileExists(atPath: deletedDir))

            let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedClaudeAgent(
                savedDirectory: deletedDir
            )

            // The saved directory is gone, so the shell's reported (home) cwd is
            // the real fallback location and must be honored, not ignored.
            let homeReport = FileManager.default.homeDirectoryForCurrentUser.path
            try #require(homeReport != deletedDir)
            restored.updatePanelDirectory(panelId: restoredPanelId, directory: homeReport)

            #expect(restored.panelDirectories[restoredPanelId] == homeReport)
            #expect(restored.currentDirectory == homeReport)
        }
    }

    /// Regression for #7155: while a restored auto-resumed agent (e.g. Claude)
    /// still holds the pane's foreground, the shell never reaches a prompt, so
    /// the pane's tracked cwd cannot self-correct. The restore guard (#6617)
    /// swallows only the FIRST spurious post-restore report; any later stray
    /// report parks the tracked cwd on the surface default (home) for the rest
    /// of the resumed run. A ⌘D split from that pane must still inherit the
    /// directory the resumed session lives in, not the clobbered home value.
    @MainActor
    @Test func splitFromResumedAgentPaneInheritsSessionCwdWhenTrackedCwdClobbered() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId, _) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == projectDir)
        }
    }

    /// Same clobbered field state as the split test, exercised through the
    /// shared resolver's ⌘T entrypoint: a new tab in the focused pane must also
    /// inherit the resumed session's directory (#7155).
    @MainActor
    @Test func newTabFromResumedAgentPaneInheritsSessionCwdWhenTrackedCwdClobbered() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-newtab-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, _, _) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )

            let created = try #require(restored.newTerminalSurfaceInFocusedPane(focus: false))
            #expect(created.requestedWorkingDirectory == projectDir)
        }
    }

    /// Agent-hook-only restores can auto-resume without a restorable-agent
    /// snapshot. They still run a startup command that cds itself, so they need
    /// the same #7155 cwd rescue as restorable-agent restores.
    @MainActor
    @Test func splitFromBindingOnlyAutoResumedAgentPaneInheritsSessionCwdWhenTrackedCwdClobbered() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-binding-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedAgentHookBindingOnly(
                savedDirectory: projectDir
            )
            try #require(restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent == nil)
            try #require(
                restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .autoResumeCommandRunning
            )
            _ = try clobberResumedAgentTrackedCwd(restored, panelId: restoredPanelId, projectDir: projectDir)
            restored.foregroundProcessWorkingDirectoryProvider = { _ in nil }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == projectDir)
        }
    }

    @MainActor
    @Test func splitAfterBindingOnlyAutoResumeExitsFollowsTrackedCwdAgain() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-binding-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }
            let repairedDir = try makeTemporaryProjectDirectory(prefix: "cmux-binding-post-exit")
            defer { try? FileManager.default.removeItem(atPath: repairedDir) }

            let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedAgentHookBindingOnly(
                savedDirectory: projectDir
            )
            _ = try clobberResumedAgentTrackedCwd(restored, panelId: restoredPanelId, projectDir: projectDir)

            restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)
            try #require(restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == nil)
            #expect(restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelId] == nil)
            let retainedBinding = try #require(
                restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding
            )
            #expect(retainedBinding.autoResume == false)
            restored.updatePanelDirectory(panelId: restoredPanelId, directory: repairedDir)

            var providerConsulted = false
            restored.foregroundProcessWorkingDirectoryProvider = { _ in
                providerConsulted = true
                return projectDir
            }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == repairedDir)
            #expect(!providerConsulted)
        }
    }

    @MainActor
    @Test func splitFromLocalResumedAgentPaneInsideRemoteWorkspaceUsesSessionCwdRescue() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-remote-local-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId, _) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )
            restored.remoteConfiguration = WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-local-resume",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-local-resume.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            )
            try #require(restored.isRemoteWorkspace)
            try #require(!restored.isRemoteTerminalSurface(restoredPanelId))
            restored.foregroundProcessWorkingDirectoryProvider = { _ in nil }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == projectDir)
        }
    }

    /// The #7155 rescue state follows a detached pane. Otherwise a reattached
    /// auto-resumed pane can keep `.autoResumeCommandRunning` but lose the
    /// recorded session directory, so an unavailable live cwd would fall back
    /// to the clobbered tracked cwd.
    @MainActor
    @Test func detachedResumedAgentPaneKeepsSessionCwdFallbackWhenReattached() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-detach-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (source, sourcePanelId, homeDir) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )
            source.foregroundProcessWorkingDirectoryProvider = { _ in nil }

            let detached = try #require(source.detachSurface(panelId: sourcePanelId))
            #expect(source.restoredResumeSessionWorkingDirectoriesByPanelId[sourcePanelId] == nil)

            let destination = Workspace()
            let paneId = try #require(destination.bonsplitController.allPaneIds.first)
            let attachedPanelId = try #require(destination.attachDetachedSurface(
                detached,
                inPane: paneId,
                focus: false
            ))
            try #require(attachedPanelId == sourcePanelId)
            try #require(destination.panelDirectories[attachedPanelId] == homeDir)
            try #require(
                destination.restoredAgentResumeStatesByPanelId[attachedPanelId] == .autoResumeCommandRunning
            )
            destination.foregroundProcessWorkingDirectoryProvider = { _ in nil }

            let split = try #require(destination.newTerminalSplit(
                from: attachedPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == projectDir)
        }
    }

    /// Restores a workspace whose focused pane auto-resumes a Claude session in
    /// `projectDir`, then clobbers the pane's tracked cwd the way #7155 hits it
    /// in the field: the one-shot #6617 guard swallows the first spurious home
    /// report, and a second stray report then lands home in `panelDirectories`
    /// (and the workspace cwd) with no prompt left to repair it while the
    /// resumed agent keeps the foreground.
    @MainActor
    private func restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
        projectDir: String
    ) throws -> (workspace: Workspace, panelId: UUID, homeDirectory: String) {
        let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedClaudeAgent(
            savedDirectory: projectDir
        )
        try #require(
            restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .autoResumeCommandRunning
        )

        let homeDir = try clobberResumedAgentTrackedCwd(
            restored,
            panelId: restoredPanelId,
            projectDir: projectDir
        )
        return (restored, restoredPanelId, homeDir)
    }

    @MainActor
    private func restoreResumedRestorableAgentOnlyWorkspaceWithClobberedTrackedCwd(
        projectDir: String
    ) throws -> (workspace: Workspace, panelId: UUID, homeDirectory: String) {
        let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedRestorableClaudeAgentOnly(
            savedDirectory: projectDir
        )
        try #require(
            restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .autoResumeCommandRunning
        )

        let homeDir = try clobberResumedAgentTrackedCwd(
            restored,
            panelId: restoredPanelId,
            projectDir: projectDir
        )
        return (restored, restoredPanelId, homeDir)
    }

    @MainActor
    private func clobberResumedAgentTrackedCwd(
        _ restored: Workspace,
        panelId restoredPanelId: UUID,
        projectDir: String
    ) throws -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        try #require(homeDir != projectDir)

        // First spurious report: swallowed by the one-shot #6617 guard.
        restored.updatePanelDirectory(panelId: restoredPanelId, directory: homeDir)
        try #require(restored.panelDirectories[restoredPanelId] == projectDir)

        // Second stray report: the guard is spent, so home lands in every
        // tracked record while the resumed agent still runs in `projectDir`.
        restored.updatePanelDirectory(panelId: restoredPanelId, directory: homeDir)
        try #require(restored.panelDirectories[restoredPanelId] == homeDir)
        try #require(restored.currentDirectory == homeDir)

        return homeDir
    }

    private func makeTemporaryProjectDirectory(prefix: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @MainActor
    @Test func splitAfterSecondRestoreOfClobberedRestorableAgentPaneUsesAgentCwd() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-second-restore-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, _, homeDir) = try restoreResumedRestorableAgentOnlyWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )
            let clobberedSnapshot = restored.sessionSnapshot(includeScrollback: false)
            let clobberedTerminal = try #require(clobberedSnapshot.panels.first?.terminal)
            #expect(clobberedTerminal.workingDirectory == homeDir)
            #expect(clobberedTerminal.agent?.workingDirectory == projectDir)
            #expect(clobberedTerminal.resumeBinding == nil)

            let secondRestore = Workspace()
            secondRestore.restoreSessionSnapshot(clobberedSnapshot)
            let secondRestoredPanelId = try #require(secondRestore.focusedPanelId)
            try #require(
                secondRestore.restoredAgentResumeStatesByPanelId[secondRestoredPanelId] == .autoResumeCommandRunning
            )
            #expect(
                secondRestore.restoredResumeSessionWorkingDirectoriesByPanelId[secondRestoredPanelId] == projectDir
            )
            secondRestore.foregroundProcessWorkingDirectoryProvider = { _ in nil }

            let split = try #require(secondRestore.newTerminalSplit(
                from: secondRestoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == projectDir)
        }
    }

    /// The cmux-authored chat rebind must record the resume launcher's real
    /// target directory, not the persisted terminal cwd a stray report may
    /// have parked on home: the Claude transcript fallback resolves
    /// `~/.claude/projects/<encoded-cwd>/<session>.jsonl` from the record's
    /// cwd, so a clobbered value points the chat surface at the wrong
    /// project (#7155).
    @MainActor
    @Test func secondRestoreOfClobberedRestorableAgentPaneRebindsChatSessionToAgentCwd() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-second-restore-chat-rebind")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, _, homeDir) = try restoreResumedRestorableAgentOnlyWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )
            let clobberedSnapshot = restored.sessionSnapshot(includeScrollback: false)
            let clobberedTerminal = try #require(clobberedSnapshot.panels.first?.terminal)
            try #require(clobberedTerminal.workingDirectory == homeDir)
            let agentSessionId = try #require(clobberedTerminal.agent?.sessionId)
            // The registry keys records on the session id with the
            // `<source>-` prefix stripped.
            try #require(agentSessionId.hasPrefix("claude-"))
            let registrySessionId = String(agentSessionId.dropFirst("claude-".count))

            let secondRestore = Workspace()
            secondRestore.restoreSessionSnapshot(clobberedSnapshot)
            _ = try #require(secondRestore.focusedPanelId)

            let service = try #require(TerminalController.shared.agentChatTranscriptService)
            let record = try #require(service.registry.record(sessionID: registrySessionId))
            #expect(record.workingDirectory == projectDir)
        }
    }

    @MainActor
    @Test func registeredAgentWithCwdIgnoreDoesNotRescueFromLaunchCwd() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-cwd-ignore-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let sessionId = "session-ignore-\(UUID().uuidString)"
            let registration = CmuxVaultAgentRegistration(
                id: "acme-ignore",
                name: "Acme Ignore",
                detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "acme-agent --session {{sessionId}}",
                cwd: .ignore
            )
            let source = Workspace()
            source.currentDirectory = projectDir
            let sourcePanelId = try #require(source.focusedPanelId)
            source.updatePanelDirectory(panelId: sourcePanelId, directory: projectDir)
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            source.setRestoredAgentSnapshotForTesting(
                SessionRestorableAgentSnapshot(
                    kind: .custom(registration.id),
                    sessionId: sessionId,
                    workingDirectory: nil,
                    launchCommand: AgentLaunchCommandSnapshot(
                        processDetectedLauncher: registration.id,
                        executablePath: "/usr/local/bin/acme-agent",
                        arguments: ["/usr/local/bin/acme-agent", "--session", sessionId],
                        workingDirectory: projectDir,
                        environment: [:]
                    ),
                    registration: registration
                ),
                panelId: sourcePanelId
            )

            let snapshot = source.sessionSnapshot(includeScrollback: false)
            let terminal = try #require(snapshot.panels.first?.terminal)
            #expect(terminal.agent?.workingDirectory == nil)
            #expect(terminal.agent?.launchCommand?.workingDirectory == projectDir)

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            try #require(
                restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .autoResumeCommandRunning
            )
            #expect(restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelId] == nil)

            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            try #require(homeDir != projectDir)
            restored.updatePanelDirectory(panelId: restoredPanelId, directory: homeDir)
            try #require(restored.panelDirectories[restoredPanelId] == homeDir)

            // Even when the live foreground read yields the launch cwd, the
            // `.ignore` registration opted out of directory tracking, so the
            // rescue must not consult it.
            restored.foregroundProcessWorkingDirectoryProvider = { _ in projectDir }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == homeDir)
        }
    }

    /// A recorded session directory on a temporarily unmounted volume must
    /// not be tombstoned as deleted (#5278): a split while the volume is
    /// offline falls back to the tracked cwd, but the recorded entry survives
    /// so the rescue engages again after remount.
    @MainActor
    @Test func splitWhileSessionDirectoryVolumeUnmountedKeepsRescueArmed() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-unmounted-volume-resume")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId, homeDir) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )
            restored.foregroundProcessWorkingDirectoryProvider = { _ in nil }

            // Re-point the recorded session directory at a path whose volume
            // is not mounted, as if the resumed session lived on an external
            // drive that went offline after the tracked cwd was clobbered.
            let unmountedSessionDir = "/Volumes/cmux-missing-\(UUID().uuidString)/project"
            try #require(!FileManager.default.fileExists(atPath: unmountedSessionDir))
            restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelId] = unmountedSessionDir

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == homeDir)
            #expect(
                restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelId] == unmountedSessionDir
            )
        }
    }

    /// The #7155 rescue prefers the live foreground process's actual cwd
    /// (libproc) over the recorded session directory: a resumed agent that
    /// moved itself is followed to where it really is.
    @MainActor
    @Test func splitFromResumedAgentPanePrefersLiveForegroundProcessCwd() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }
            let liveDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-resume-live")
            defer { try? FileManager.default.removeItem(atPath: liveDir) }

            let (restored, restoredPanelId, _) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )
            restored.foregroundProcessWorkingDirectoryProvider = { _ in liveDir }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == liveDir)
        }
    }

    /// If libproc reports the same directory as the already-clobbered tracked
    /// cwd, it is probably the resume launcher shell rather than the agent's
    /// real cwd. Fall back to the recorded session directory instead.
    @MainActor
    @Test func splitFromResumedAgentPaneIgnoresLiveCwdMatchingClobberedTrackedCwd() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId, homeDir) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )
            restored.foregroundProcessWorkingDirectoryProvider = { _ in homeDir }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == projectDir)
        }
    }

    /// While the tracked cwd still matches the restored session directory the
    /// #7155 rescue stays out of the way: the tracked value wins and the live
    /// process is never inspected, so healthy panes keep today's behavior.
    @MainActor
    @Test func splitFromResumedAgentPaneKeepsTrackedCwdWhileUnclobbered() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedClaudeAgent(
                savedDirectory: projectDir
            )
            try #require(
                restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .autoResumeCommandRunning
            )
            var providerConsulted = false
            restored.foregroundProcessWorkingDirectoryProvider = { _ in
                providerConsulted = true
                return FileManager.default.temporaryDirectory.path
            }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == projectDir)
            #expect(!providerConsulted)
        }
    }

    /// When the live process cwd cannot be read (process gone, libproc denied)
    /// the #7155 rescue falls back to the recorded session directory.
    @MainActor
    @Test func splitFromResumedAgentPaneFallsBackToSessionDirectoryWhenLiveCwdUnavailable() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId, _) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )
            restored.foregroundProcessWorkingDirectoryProvider = { _ in nil }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == projectDir)
        }
    }

    /// When the recorded session directory was deleted while the agent ran and
    /// the live cwd is unreadable, the #7155 rescue steps aside instead of
    /// inheriting a dead path (mirroring the #6617 deleted-directory
    /// semantics), so the split falls back to the tracked cwd.
    @MainActor
    @Test func splitFromResumedAgentPaneFallsBackToTrackedCwdWhenSessionDirectoryDeleted() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId, homeDir) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )
            restored.foregroundProcessWorkingDirectoryProvider = { _ in nil }
            try FileManager.default.removeItem(atPath: projectDir)

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == homeDir)
            #expect(restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelId] == nil)

            try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
            let recreatedSplit = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(recreatedSplit.requestedWorkingDirectory == homeDir)
        }
    }

    @MainActor
    @Test func splitFromResumedAgentPaneIgnoresRecreatedDeletedSessionDirectory() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-resume-deleted-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }

            let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedClaudeAgent(
                savedDirectory: projectDir
            )
            try FileManager.default.removeItem(atPath: projectDir)
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

            restored.updatePanelDirectory(panelId: restoredPanelId, directory: homeDir)
            try #require(restored.panelDirectories[restoredPanelId] == homeDir)
            #expect(restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelId] == nil)

            try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
            restored.foregroundProcessWorkingDirectoryProvider = { _ in homeDir }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == homeDir)
        }
    }

    /// Once the resumed agent exits (the pane's shell reaches a prompt again)
    /// the pane leaves the resumed state: inheritance returns to the tracked
    /// cwd and the live process is no longer inspected — the recovery the
    /// #7155 reporter observed after quitting Claude.
    @MainActor
    @Test func splitAfterResumedAgentExitsFollowsTrackedCwdAgain() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-resume-project")
            defer { try? FileManager.default.removeItem(atPath: projectDir) }
            let repairedDir = try makeTemporaryProjectDirectory(prefix: "cmux-split-post-exit")
            defer { try? FileManager.default.removeItem(atPath: repairedDir) }

            let (restored, restoredPanelId, _) = try restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
                projectDir: projectDir
            )

            // The agent exits: the shell reaches a prompt, which completes the
            // restored-resume state and re-reports the real cwd.
            restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)
            try #require(restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .completedAgentExit)
            #expect(restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelId] == nil)
            restored.updatePanelDirectory(panelId: restoredPanelId, directory: repairedDir)

            var providerConsulted = false
            restored.foregroundProcessWorkingDirectoryProvider = { _ in
                providerConsulted = true
                return projectDir
            }

            let split = try #require(restored.newTerminalSplit(
                from: restoredPanelId,
                orientation: .horizontal,
                focus: false
            ))
            #expect(split.requestedWorkingDirectory == repairedDir)
            #expect(!providerConsulted)
        }
    }

    /// Direct coverage for the libproc read behind the #7155 rescue: the test
    /// runner's own pid resolves to its real working directory, and an invalid
    /// pid resolves to nil instead of trapping.
    @Test func processCurrentWorkingDirectoryReadsLiveProcessAndRejectsInvalidPid() throws {
        let ownCwd = try #require(Workspace.processCurrentWorkingDirectory(pid: getpid()))
        let resolvedOwnCwd = URL(fileURLWithPath: ownCwd).resolvingSymlinksInPath().path
        let expectedCwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().path
        #expect(resolvedOwnCwd == expectedCwd)

        #expect(Workspace.processCurrentWorkingDirectory(pid: -1) == nil)
    }

    /// Builds a workspace whose focused terminal hosts an auto-resumable Claude
    /// agent-hook session rooted at `savedDirectory`, snapshots it, and restores
    /// it into a fresh workspace. Returns the restored workspace and the restored
    /// focused panel id, asserting the saved directory was replayed onto both the
    /// workspace cwd and the panel directory.
    @MainActor
    private func restoreWorkspaceWithAutoResumedClaudeAgent(
        savedDirectory: String
    ) throws -> (workspace: Workspace, panelId: UUID) {
        let sessionId = "claude-cmdt-resume-\(UUID().uuidString)"
        let source = Workspace()
        source.currentDirectory = savedDirectory
        let sourcePanelId = try #require(source.focusedPanelId)

        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: savedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", sessionId],
                workingDirectory: savedDirectory,
                environment: [:],
                capturedAt: 1_777_777_777,
                source: "process"
            )
        )
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(agent, panelId: sourcePanelId)

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Claude",
                kind: "claude",
                command: "{ cd -- '\(savedDirectory)' 2>/dev/null || [ ! -d '\(savedDirectory)' ]; } && 'claude' '--resume' '\(sessionId)'",
                cwd: savedDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                autoResume: true,
                updatedAt: 1_777_777_777
            ),
        ])

        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        #expect(snapshot.currentDirectory == savedDirectory)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)

        // Restore replays the persisted directory onto the workspace and panel.
        #expect(restored.currentDirectory == savedDirectory)
        #expect(restored.panelDirectories[restoredPanelId] == savedDirectory)

        return (restored, restoredPanelId)
    }

    /// Builds a workspace whose focused terminal hosts an auto-resumable
    /// restorable Claude session rooted at `savedDirectory` without an
    /// agent-hook binding, snapshots it, and restores it into a fresh workspace.
    @MainActor
    private func restoreWorkspaceWithAutoResumedRestorableClaudeAgentOnly(
        savedDirectory: String
    ) throws -> (workspace: Workspace, panelId: UUID) {
        let sessionId = "claude-restorable-only-resume-\(UUID().uuidString)"
        let source = Workspace()
        source.currentDirectory = savedDirectory
        let sourcePanelId = try #require(source.focusedPanelId)
        source.updatePanelDirectory(panelId: sourcePanelId, directory: savedDirectory)

        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: savedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", sessionId],
                workingDirectory: savedDirectory,
                environment: [:],
                capturedAt: 1_777_777_777,
                source: "process"
            )
        )
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(agent, panelId: sourcePanelId)

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first?.terminal?.agent?.workingDirectory == savedDirectory)
        #expect(snapshot.panels.first?.terminal?.resumeBinding == nil)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)

        #expect(restored.currentDirectory == savedDirectory)
        #expect(restored.panelDirectories[restoredPanelId] == savedDirectory)
        #expect(restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding == nil)

        return (restored, restoredPanelId)
    }

    /// Builds a workspace that restores solely from a cmux-owned agent-hook
    /// binding: no restorable-agent snapshot is present, but the approved
    /// binding still auto-runs a startup command rooted at `savedDirectory`.
    @MainActor
    private func restoreWorkspaceWithAutoResumedAgentHookBindingOnly(
        savedDirectory: String
    ) throws -> (workspace: Workspace, panelId: UUID) {
        let sessionId = "claude-binding-only-resume-\(UUID().uuidString)"
        let source = Workspace()
        source.currentDirectory = savedDirectory
        let sourcePanelId = try #require(source.focusedPanelId)
        source.updatePanelDirectory(panelId: sourcePanelId, directory: savedDirectory)
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Claude",
                kind: "claude",
                command: "{ cd -- '\(savedDirectory)' 2>/dev/null || [ ! -d '\(savedDirectory)' ]; } && 'claude' '--resume' '\(sessionId)'",
                cwd: savedDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                autoResume: true,
                updatedAt: 1_777_777_777
            ),
        ])

        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        #expect(snapshot.panels.first?.terminal?.agent == nil)
        #expect(snapshot.panels.first?.terminal?.resumeBinding?.cwd == savedDirectory)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)

        #expect(restored.currentDirectory == savedDirectory)
        #expect(restored.panelDirectories[restoredPanelId] == savedDirectory)

        return (restored, restoredPanelId)
    }

    @MainActor
    @Test func claudeAgentHookResumeBindingIgnoresStaleRestoredAgentSnapshot() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let source = Workspace()
            let sourcePanelId = try #require(source.focusedPanelId)
            let staleSessionId = "claude-stale-restored-session"
            let freshSessionId = "claude-fresh-binding-session"
            let staleLaunchCwd = "/tmp/cmux-claude-stale-launch"
            let freshRuntimeCwd = "/tmp/cmux-claude-fresh-runtime"
            let staleAgent = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: staleSessionId,
                workingDirectory: staleLaunchCwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/usr/local/bin/claude",
                    arguments: ["/usr/local/bin/claude"],
                    workingDirectory: staleLaunchCwd,
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            source.setRestoredAgentSnapshotForTesting(staleAgent, panelId: sourcePanelId)

            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Claude",
                    kind: "claude",
                    command: "{ cd -- '\(freshRuntimeCwd)' 2>/dev/null || [ ! -d '\(freshRuntimeCwd)' ]; } && 'claude' '--resume' '\(freshSessionId)'",
                    cwd: freshRuntimeCwd,
                    checkpointId: freshSessionId,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_778
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
            let restoredBinding = try #require(
                restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding
            )

            #expect(restoredBinding.checkpointId == freshSessionId)
            #expect(restoredBinding.cwd == freshRuntimeCwd)
            #expect(restoredBinding.command.contains(freshRuntimeCwd), Comment(rawValue: restoredBinding.command))
            #expect(!restoredBinding.command.contains(staleLaunchCwd), Comment(rawValue: restoredBinding.command))
            #expect(restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent == nil)
            try assertAgentAutoResumeUsesStartupInput(
                restoredPanel,
                scriptContains: [freshRuntimeCwd, "--resume", freshSessionId],
                scriptDoesNotContain: [staleLaunchCwd, staleSessionId]
            )
        }
    }

    @MainActor
    @Test func crossKindAgentHookResumeBindingDoesNotRetainStaleClaudeSnapshot() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let source = Workspace()
            let sourcePanelId = try #require(source.focusedPanelId)
            let claudeSessionId = "claude-stale-cross-kind-session"
            let codexSessionId = "codex-fresh-binding-session"
            let cwd = "/tmp/cmux-cross-kind-runtime"
            let claudeAgent = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: claudeSessionId,
                workingDirectory: cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/usr/local/bin/claude",
                    arguments: ["/usr/local/bin/claude", "--model", "claude-opus-4-8"],
                    workingDirectory: cwd,
                    environment: ["CLAUDE_CONFIG_DIR": "/tmp/cmux-claude-config"],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            source.setRestoredAgentSnapshotForTesting(claudeAgent, panelId: sourcePanelId)

            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "{ cd -- '\(cwd)' 2>/dev/null || [ ! -d '\(cwd)' ]; } && 'codex' 'resume' '\(codexSessionId)'",
                    cwd: cwd,
                    checkpointId: codexSessionId,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_778
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
            let restoredTerminal = restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal
            let restoredBinding = try #require(restoredTerminal?.resumeBinding)

            #expect(restoredTerminal?.agent == nil)
            #expect(restoredBinding.kind == "codex")
            #expect(restoredBinding.checkpointId == codexSessionId)
            try assertAgentAutoResumeUsesStartupInput(
                restoredPanel,
                scriptContains: ["codex", "resume", codexSessionId],
                scriptDoesNotContain: [claudeSessionId, "claude-opus-4-8"]
            )
        }
    }

    @MainActor
    @Test func crossKindAgentHookResumeBindingIgnoresStaleClaudeHibernation() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let source = Workspace()
            let sourcePanelId = try #require(source.focusedPanelId)
            let claudeSessionId = "claude-stale-hibernated-session"
            let codexSessionId = "codex-fresh-hibernation-binding-session"
            let cwd = "/tmp/cmux-cross-kind-hibernation-runtime"
            let claudeAgent = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: claudeSessionId,
                workingDirectory: cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/usr/local/bin/claude",
                    arguments: ["/usr/local/bin/claude", "--model", "claude-opus-4-8"],
                    workingDirectory: cwd,
                    environment: ["CLAUDE_CONFIG_DIR": "/tmp/cmux-claude-config"],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )
            source.enterAgentHibernation(
                panelId: sourcePanelId,
                agent: claudeAgent,
                lastActivityAt: Date(timeIntervalSince1970: 1_777_777_776)
            )

            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "{ cd -- '\(cwd)' 2>/dev/null || [ ! -d '\(cwd)' ]; } && 'codex' 'resume' '\(codexSessionId)'",
                    cwd: cwd,
                    checkpointId: codexSessionId,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_778
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )
            let terminalSnapshot = try #require(snapshot.panels.first?.terminal)

            #expect(terminalSnapshot.agent == nil)
            #expect(terminalSnapshot.hibernation == nil)
            #expect(terminalSnapshot.resumeBinding?.kind == "codex")

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))

            try assertAgentAutoResumeUsesStartupInput(
                restoredPanel,
                scriptContains: ["codex", "resume", codexSessionId],
                scriptDoesNotContain: [claudeSessionId, "claude-opus-4-8"]
            )
        }
    }

    @Test func claudeRestorableIndexFindsNestedTranscriptWithoutTranscriptPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-nested-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let launchCwd = root.appendingPathComponent("repo.main", isDirectory: true)
        let runtimeCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeCwd, withIntermediateDirectories: true)

        let sessionId = "2c5f3e70-393c-485b-a263-601604a47cb2"
        let transcriptURL = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(expectedClaudeProjectDirName(launchCwd.path), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL)

        let workspaceId = UUID()
        let panelId = UUID()
        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: claudeHookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: runtimeCwd.path,
                    launchCwd: launchCwd.path,
                    configDir: configDir.path,
                    transcriptPath: nil,
                    updatedAt: 10
                ),
            ]
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fileManager)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        #expect(snapshot.sessionId == sessionId)
        #expect(snapshot.workingDirectory == launchCwd.path)
        #expect(snapshot.resumeCommand?.contains("cd -- '\(launchCwd.path)'") == true)
    }

    @Test func claudeRestorableIndexMapsNestedTranscriptPathToProjectCwd() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-nested-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let staleLaunchCwd = root.appendingPathComponent("stale-launch", isDirectory: true)
        let transcriptCwd = root.appendingPathComponent("repo.main", isDirectory: true)
        try fileManager.createDirectory(at: staleLaunchCwd, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: transcriptCwd, withIntermediateDirectories: true)

        let sessionId = "8cb5975d-0605-4b08-8417-b8922726de18"
        let transcriptURL = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(expectedClaudeProjectDirName(transcriptCwd.path), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL)

        let workspaceId = UUID()
        let panelId = UUID()
        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: claudeHookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: transcriptCwd.path,
                    launchCwd: staleLaunchCwd.path,
                    configDir: configDir.path,
                    transcriptPath: transcriptURL.path,
                    updatedAt: 10
                ),
            ]
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fileManager)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        #expect(snapshot.workingDirectory == transcriptCwd.path)
        #expect(snapshot.resumeCommand?.contains("cd -- '\(transcriptCwd.path)'") == true)
        #expect(snapshot.resumeCommand?.contains(staleLaunchCwd.path) == false)
    }

    private func expectedClaudeProjectDirName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func writeClaudeTranscript(sessionId: String, transcriptURL: URL) throws {
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}

        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    private func writeClaudeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessions,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: stateDir.appendingPathComponent("claude-hook-sessions.json"))
    }

    private func claudeHookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        recordedCwd: String,
        launchCwd: String,
        configDir: String,
        transcriptPath: String?,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": recordedCwd,
            "pid": NSNull(),
            "isRestorable": true,
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude"],
                "workingDirectory": launchCwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
        if let transcriptPath {
            record["transcriptPath"] = transcriptPath
        }
        return record
    }

    private func withRestoredDefaults<T>(
        key: String,
        defaults: UserDefaults = .standard,
        body: () throws -> T
    ) rethrows -> T {
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try body()
    }

    @MainActor
    private func assertAgentAutoResumeUsesStartupInput(
        _ panel: TerminalPanel,
        scriptContains needles: [String],
        scriptDoesNotContain excludedNeedles: [String] = []
    ) throws {
        #expect(panel.surface.debugInitialCommand() == nil)
        let input = try #require(panel.surface.debugInitialInputForTesting())
        let launcherPrefix = "/bin/zsh '"
        let launcherRange = try #require(input.range(of: launcherPrefix, options: .backwards))
        let launcherSuffix = input[launcherRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(launcherSuffix.hasSuffix("'"), Comment(rawValue: input))
        let scriptPath = String(launcherSuffix.dropLast())
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        for needle in needles {
            #expect(script.contains(needle), Comment(rawValue: script))
        }
        for needle in excludedNeedles {
            #expect(!script.contains(needle), Comment(rawValue: script))
        }
        #expect(script.contains("rm -f -- \"$0\""), Comment(rawValue: script))
        #expect(!script.contains("exec -l"), Comment(rawValue: script))
    }
}

@Suite(.serialized)
struct RemoteAgentRestoreWorkingDirectoryTests {
    @Test func retainedExactSelectionSurvivesPersistenceAndEveryCommandEntrypoint() throws {
        let capturedAgentDirectory = "/Users/alice/captured-agent-cwd"
        let capturedLaunchDirectory = "/Users/alice/captured-launch-cwd"
        let capturedArgumentDirectory = "/Users/alice/captured-argument-cwd"
        let overrideDirectory = "/Users/alice/binding-override-cwd"
        let trustedRemoteDirectory = "/home/remote/project"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "retained-exact-codex",
            workingDirectory: capturedAgentDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: [
                    "/usr/local/bin/codex",
                    "-C\(capturedArgumentDirectory)",
                    "--model",
                    "test-model",
                ],
                workingDirectory: capturedLaunchDirectory
            )
        )
        let constrained = snapshot.applyingRestoreWorkingDirectorySelection(
            .exact(trustedRemoteDirectory)
        )

        #expect(constrained.workingDirectory == trustedRemoteDirectory)
        #expect(constrained.launchCommand?.workingDirectory == nil)
        #expect(constrained.launchCommand?.arguments.contains { argument in
            argument.contains(capturedArgumentDirectory)
        } == false)

        let encoded = try JSONEncoder().encode(constrained)
        let decoded = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: encoded
        )
        #expect(decoded.restoreWorkingDirectorySelection == .exact(trustedRemoteDirectory))

        let resumeCommand = try #require(decoded.resumeCommand)
        let forkCommand = try #require(decoded.forkCommand)
        let explicitFallbackResume = try #require(decoded.resumeCommand(
            includeWorkingDirectoryPrefix: true,
            workingDirectorySelection: .recordedFallback(preferred: capturedAgentDirectory)
        ))
        let startupInput = try #require(decoded.resumeStartupInput(
            useLocalRestoreVerb: false,
            workingDirectorySelection: .recordedFallback(preferred: capturedLaunchDirectory)
        ))
        for command in [resumeCommand, forkCommand, explicitFallbackResume, startupInput] {
            #expect(command.contains(trustedRemoteDirectory), Comment(rawValue: command))
            #expect(!command.contains(capturedAgentDirectory), Comment(rawValue: command))
            #expect(!command.contains(capturedLaunchDirectory), Comment(rawValue: command))
            #expect(!command.contains(capturedArgumentDirectory), Comment(rawValue: command))
        }

        let override = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "/usr/local/bin/codex",
            arguments: ["/usr/local/bin/codex", "-C", overrideDirectory, "--model", "override"],
            workingDirectory: overrideDirectory
        )
        let preparedArguments = try #require(decoded.preparedResumeArguments(
            launchCommand: override,
            workingDirectorySelection: .recordedFallback(preferred: overrideDirectory),
            observedPermissionMode: nil
        ))
        #expect(!preparedArguments.contains("-C"))
        #expect(!preparedArguments.contains { $0.contains(overrideDirectory) })
    }

    @Test func retainedUnavailableSelectionDisablesEveryCommandEntrypoint() throws {
        let capturedDirectory = "/Users/alice/captured-cwd"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .grok,
            sessionId: "retained-unavailable-grok",
            workingDirectory: capturedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "grok",
                arguments: ["grok", "--cwd", capturedDirectory],
                workingDirectory: capturedDirectory
            ),
            registration: .builtInGrok
        )
        let unavailable = snapshot.applyingRestoreWorkingDirectorySelection(.unavailable)

        #expect(unavailable.workingDirectory == nil)
        #expect(unavailable.launchCommand?.workingDirectory == nil)
        #expect(unavailable.launchCommand?.arguments.contains(capturedDirectory) == false)
        #expect(unavailable.resumeCommand == nil)
        #expect(unavailable.forkCommand == nil)
        #expect(unavailable.resumeStartupInput(useLocalRestoreVerb: false) == nil)
        #expect(unavailable.preparedResumeArguments(
            launchCommand: snapshot.launchCommand,
            workingDirectory: capturedDirectory,
            observedPermissionMode: nil
        ) == nil)

        let encoded = try JSONEncoder().encode(unavailable)
        let decoded = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: encoded
        )
        #expect(decoded.restoreWorkingDirectorySelection == .unavailable)
        #expect(decoded.resumeCommand == nil)
        #expect(decoded.forkCommand == nil)
        #expect(
            TabManager.restorableAgentSnapshotFingerprint(snapshot) !=
                TabManager.restorableAgentSnapshotFingerprint(decoded)
        )
    }

    @Test func bindingExactSelectionRemainsAuthoritativeOverStaleAgentSelection() throws {
        let capturedDirectory = "/Users/alice/captured-binding-cwd"
        let sessionID = "binding-authority-session"
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "/usr/local/bin/codex",
            arguments: ["/usr/local/bin/codex", "-C", capturedDirectory, "resume", sessionID],
            workingDirectory: capturedDirectory
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume " + sessionID,
            cwd: capturedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            restoreWorkingDirectorySelection: .exact(nil),
            autoResume: true
        )
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: capturedDirectory,
            launchCommand: launchCommand,
            restoreWorkingDirectorySelection: .exact(capturedDirectory)
        )

        let constrained = binding.applyingRestoreWorkingDirectorySelection(
            .exact(capturedDirectory),
            from: agent
        )

        #expect(constrained.restoreWorkingDirectorySelection == .exact(nil))
        #expect(constrained.cwd == nil)
        #expect(!constrained.command.contains(capturedDirectory))
        #expect(constrained.launchCommand?.workingDirectory == nil)
        #expect(constrained.launchCommand?.arguments.contains(capturedDirectory) == false)
    }

    @Test func legacySnapshotWithoutSelectionKeepsRecordedFallbackBehavior() throws {
        let recordedDirectory = "/tmp/legacy-recorded-cwd"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "legacy-recorded-codex",
            workingDirectory: recordedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex"]
            )
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: encoded
        )
        #expect(decoded.restoreWorkingDirectorySelection == nil)
        let command = try #require(decoded.resumeCommand)
        #expect(command.contains(recordedDirectory), Comment(rawValue: command))
    }

    @Test func exactSelectionStripsRegisteredBuiltInRecordedCwdArguments() throws {
        let recordedLocalDirectory = "/Users/alice/recorded-agent-cwd"
        let trustedRemoteDirectory = "/repo-b"
        let cases: [(
            kind: RestorableAgentKind,
            registration: CmuxVaultAgentRegistration,
            executable: String,
            cwdOption: String,
            cwdArgument: String,
            launchWorkingDirectory: String?
        )] = [
            (
                .grok,
                .builtInGrok,
                "grok",
                "--cwd",
                "/Users/alice/grok-explicit-cwd",
                "/tmp/grok-process-cwd"
            ),
            (
                .kimi,
                .builtInKimi,
                "kimi",
                "--work-dir",
                "/Users/alice/kimi-explicit-cwd",
                nil
            ),
        ]

        for testCase in cases {
            let sessionId = "remote-\(testCase.executable)-session"
            let snapshot = SessionRestorableAgentSnapshot(
                kind: testCase.kind,
                sessionId: sessionId,
                workingDirectory: recordedLocalDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: testCase.executable,
                    executablePath: testCase.executable,
                    arguments: [testCase.executable, testCase.cwdOption, testCase.cwdArgument],
                    workingDirectory: testCase.launchWorkingDirectory,
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                ),
                registration: testCase.registration
            )

            for exactDirectory in [trustedRemoteDirectory, nil] as [String?] {
                let input = try #require(snapshot.resumeStartupInput(
                    useLocalRestoreVerb: false,
                    workingDirectorySelection: .exact(exactDirectory)
                ))
                #expect(input.contains(sessionId), Comment(rawValue: input))
                #expect(!input.contains(recordedLocalDirectory), Comment(rawValue: input))
                #expect(!input.contains(testCase.cwdArgument), Comment(rawValue: input))
                #expect(!input.contains(testCase.cwdOption), Comment(rawValue: input))
                if let exactDirectory {
                    #expect(input.contains(exactDirectory), Comment(rawValue: input))
                }
            }
        }
    }

    @Test func exactSelectionStripsAttachedShortCwdArguments() throws {
        let trustedRemoteDirectory = "/repo-b"
        let cases: [(
            kind: RestorableAgentKind,
            registration: CmuxVaultAgentRegistration?,
            executable: String,
            attachedCwdOption: String
        )] = [
            (.codex, nil, "codex", "-C/Users/alice/codex-explicit-cwd"),
            (.qoder, nil, "qodercli", "-w/Users/alice/qoder-explicit-cwd"),
            (.kimi, .builtInKimi, "kimi", "-w/Users/alice/kimi-explicit-cwd"),
        ]

        for testCase in cases {
            let sessionId = "remote-\(testCase.executable)-attached-cwd"
            let snapshot = SessionRestorableAgentSnapshot(
                kind: testCase.kind,
                sessionId: sessionId,
                workingDirectory: "/Users/alice/recorded-agent-cwd",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: testCase.executable,
                    executablePath: testCase.executable,
                    arguments: [testCase.executable, testCase.attachedCwdOption],
                    workingDirectory: "/tmp/process-cwd",
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                ),
                registration: testCase.registration
            )

            for exactDirectory in [trustedRemoteDirectory, nil] as [String?] {
                let input = try #require(snapshot.resumeStartupInput(
                    useLocalRestoreVerb: false,
                    workingDirectorySelection: .exact(exactDirectory)
                ))
                #expect(input.contains(sessionId), Comment(rawValue: input))
                #expect(!input.contains(testCase.attachedCwdOption), Comment(rawValue: input))
                if let exactDirectory {
                    #expect(input.contains(exactDirectory), Comment(rawValue: input))
                }
            }
        }
    }

    @Test func exactSelectionPreservesClaudeTeamsWorktreeArguments() throws {
        let worktree = "/tmp/team-worktree"
        let worktreeArguments = [
            ["-w", worktree],
            ["-w\(worktree)"],
        ]

        for arguments in worktreeArguments {
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "remote-claude-team",
                workingDirectory: "/Users/alice/recorded-agent-cwd",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claudeTeams",
                    executablePath: "cmux",
                    arguments: ["cmux", "claude-teams"] + arguments,
                    workingDirectory: "/Users/alice/recorded-launch-cwd",
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )

            let input = try #require(snapshot.resumeStartupInput(
                useLocalRestoreVerb: false,
                workingDirectorySelection: .exact(nil)
            ))
            #expect(input.contains(worktree), Comment(rawValue: input))
            #expect(input.contains("'-w"), Comment(rawValue: input))
        }
    }

    @MainActor
    @Test func genericDirectoryReportCannotSeedEmptyTrustRequiredRemotePanel() throws {
        let localDirectory = "/Users/alice/development"
        let genericDirectory = "/repo-a"
        let remoteCommand = "ssh cmux-remote"
        let workspace = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: remoteCommand
        )
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        workspace.panelDirectories.removeValue(forKey: panelId)

        #expect(workspace.remoteDirectoryTrustRequiredPanelIds.contains(panelId))
        #expect(!workspace.updatePanelDirectory(panelId: panelId, directory: genericDirectory))
        #expect(workspace.panelDirectories[panelId] == nil)
        #expect(workspace.reportedPanelDirectory(panelId: panelId) == nil)
    }

    @MainActor
    @Test func remoteAutoResumeUsesLatestAuthoritativeDirectoryReport() throws {
        let defaultsName = "cmux-remote-latest-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let localDirectory = "/Users/alice/development"
        let firstRemoteDirectory = "/repo-a"
        let latestRemoteDirectory = "/repo-b"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "codex-remote-latest-cwd-\(UUID().uuidString)"
        let source = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: remoteCommand,
            agentSessionAutoResumeDefaults: defaults
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        #expect(source.updateRemotePanelDirectory(panelId: sourcePanelId, directory: firstRemoteDirectory))
        #expect(source.updateRemotePanelDirectory(panelId: sourcePanelId, directory: latestRemoteDirectory))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            restorableCodexAgent(sessionId: sessionId, workingDirectory: firstRemoteDirectory),
            panelId: sourcePanelId
        )
        let firstBindingAgent = restorableCodexAgent(
            sessionId: sessionId,
            workingDirectory: firstRemoteDirectory
        )
        #expect(source.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "codex resume \(sessionId)",
                cwd: firstRemoteDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                launchCommand: firstBindingAgent.launchCommand,
                restoreWorkingDirectorySelection: .exact(firstRemoteDirectory),
                autoResume: true
            ),
            panelId: sourcePanelId
        ))

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first?.directoryIsTrustedRemoteReport == true)
        #expect(snapshot.panels.first?.terminal?.workingDirectory == latestRemoteDirectory)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[sourcePanelId])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
        let startupInput = try #require(restoredPanel.surface.initialInput)

        #expect(startupInput.contains(latestRemoteDirectory), Comment(rawValue: startupInput))
        #expect(!startupInput.contains(firstRemoteDirectory), Comment(rawValue: startupInput))
        #expect(!startupInput.contains(localDirectory), Comment(rawValue: startupInput))
        #expect(restoredPanel.requestedWorkingDirectory == latestRemoteDirectory)
        let restoredBinding = try #require(
            restored.surfaceResumeBinding(panelId: restoredPanelId)
        )
        #expect(restoredBinding.restoreWorkingDirectorySelection == .exact(latestRemoteDirectory))
        #expect(restoredBinding.cwd == latestRemoteDirectory)

        let newerRemoteDirectory = "/repo-c"
        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        #expect(restored.updateRemotePanelDirectory(
            panelId: restoredPanelId,
            directory: newerRemoteDirectory
        ))
        let secondSnapshot = restored.sessionSnapshot(includeScrollback: false)
        let secondRestore = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { secondRestore.teardownAllPanels() }
        let secondPanelIds = secondRestore.restoreSessionSnapshot(secondSnapshot)
        let secondPanelId = try #require(secondPanelIds[restoredPanelId])
        let secondPanel = try #require(secondRestore.terminalPanel(for: secondPanelId))
        let secondStartupInput = try #require(secondPanel.surface.initialInput)
        let secondAgent = try #require(secondRestore.restoredAgentSnapshotsByPanelId[secondPanelId])

        #expect(secondAgent.restoreWorkingDirectorySelection == .exact(newerRemoteDirectory))
        #expect(secondStartupInput.contains(newerRemoteDirectory), Comment(rawValue: secondStartupInput))
        #expect(!secondStartupInput.contains(latestRemoteDirectory), Comment(rawValue: secondStartupInput))
        #expect(
            secondRestore.surfaceResumeBinding(panelId: secondPanelId)?.restoreWorkingDirectorySelection ==
                .exact(newerRemoteDirectory)
        )
    }

    @MainActor
    @Test func remoteDirectoryNamespacedAutoResumeSkipsWithoutTrustedLaunchDirectory() throws {
        let defaultsName = "cmux-remote-launch-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let localDirectory = "/Users/alice/development"
        let staleAgentDirectory = "/repo-a"
        let staleLaunchDirectory = "/repo-launch"
        let latestRemoteDirectory = "/repo-b"
        let savedScrollback = "last remote agent output\n"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "grok-remote-launch-cwd-\(UUID().uuidString)"
        let source = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: remoteCommand,
            agentSessionAutoResumeDefaults: defaults
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        #expect(source.updateRemotePanelDirectory(panelId: sourcePanelId, directory: staleAgentDirectory))
        #expect(source.updateRemotePanelDirectory(panelId: sourcePanelId, directory: latestRemoteDirectory))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .grok,
                sessionId: sessionId,
                workingDirectory: staleAgentDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "grok",
                    executablePath: "grok",
                    arguments: ["grok", "--cwd", staleLaunchDirectory],
                    workingDirectory: staleLaunchDirectory,
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                ),
                registration: .builtInGrok
            ),
            panelId: sourcePanelId
        )
        #expect(source.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "grok",
                command: "grok --resume \(sessionId) --cwd '\(staleLaunchDirectory)'",
                cwd: staleLaunchDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "grok",
                    executablePath: "grok",
                    arguments: ["grok", "--cwd", staleLaunchDirectory],
                    workingDirectory: staleLaunchDirectory
                ),
                autoResume: true
            ),
            panelId: sourcePanelId
        ))

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first?.directoryIsTrustedRemoteReport == true)
        #expect(snapshot.panels.first?.terminal?.workingDirectory == latestRemoteDirectory)
        #expect(snapshot.panels.first?.terminal?.agent?.workingDirectory == staleAgentDirectory)
        #expect(snapshot.panels.first?.terminal?.agent?.launchCommand?.workingDirectory == staleLaunchDirectory)

        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelId })
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        terminalSnapshot.scrollback = savedScrollback
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        try withRestoredRemoteSurfaceSnapshot(
            snapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: true
        ) { restored, restoredPanelId, restoredPanel, resumeSnapshot in
            let startupInput = restoredPanel.surface.initialInput
            #expect(startupInput == nil, Comment(rawValue: startupInput ?? "nil"))
            #expect(restoredPanel.requestedWorkingDirectory == nil)
            #expect(restored.restoredAgentSnapshotsByPanelId[restoredPanelId] == nil)
            #expect(restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == nil)
            #expect(restored.restoredTerminalScrollbackByPanelId[restoredPanelId] == savedScrollback)
            #expect(restored.surfaceResumeBinding(panelId: restoredPanelId) == nil)
            #expect(resumeSnapshot.binding == nil)
            #expect(resumeSnapshot.restoreRecord == nil)
        }
    }

    @MainActor
    @Test func remoteAutoResumeWithoutTrustedDirectoryRejectsRecordedLocalCwd() throws {
        let defaultsName = "cmux-remote-untrusted-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let localDirectory = "/Users/alice/development"
        let untrustedRecordedDirectory = "/Users/alice/recorded-agent-cwd"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "codex-remote-untrusted-cwd-\(UUID().uuidString)"
        let source = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: remoteCommand,
            agentSessionAutoResumeDefaults: defaults
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            restorableCodexAgent(sessionId: sessionId, workingDirectory: untrustedRecordedDirectory),
            panelId: sourcePanelId
        )

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelId })
        snapshot.panels[panelIndex].directory = untrustedRecordedDirectory
        snapshot.panels[panelIndex].directoryIsTrustedRemoteReport = false
        snapshot.panels[panelIndex].directoryRequiresRemoteTrust = true
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        terminalSnapshot.workingDirectory = untrustedRecordedDirectory
        terminalSnapshot.isRemoteTerminal = true
        terminalSnapshot.wasAgentRunning = true
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[sourcePanelId])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
        let startupInput = try #require(restoredPanel.surface.initialInput)

        #expect(startupInput.contains(sessionId), Comment(rawValue: startupInput))
        #expect(!startupInput.contains(untrustedRecordedDirectory), Comment(rawValue: startupInput))
        #expect(!startupInput.contains(localDirectory), Comment(rawValue: startupInput))
        #expect(restoredPanel.requestedWorkingDirectory == nil)
        #expect(restored.remoteDirectoryTrustRequiredPanelIds.contains(restoredPanelId))

        let newlyReportedRemoteDirectory = "/repo-b"
        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        #expect(restored.updateRemotePanelDirectory(
            panelId: restoredPanelId,
            directory: newlyReportedRemoteDirectory
        ))
        let secondSnapshot = restored.sessionSnapshot(includeScrollback: false)
        let secondRestore = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { secondRestore.teardownAllPanels() }
        let secondPanelIds = secondRestore.restoreSessionSnapshot(secondSnapshot)
        let secondPanelId = try #require(secondPanelIds[restoredPanelId])
        let secondPanel = try #require(secondRestore.terminalPanel(for: secondPanelId))
        let secondStartupInput = try #require(secondPanel.surface.initialInput)
        let secondAgent = try #require(secondRestore.restoredAgentSnapshotsByPanelId[secondPanelId])

        #expect(secondAgent.restoreWorkingDirectorySelection == .exact(newlyReportedRemoteDirectory))
        #expect(secondStartupInput.contains(newlyReportedRemoteDirectory), Comment(rawValue: secondStartupInput))
        #expect(!secondStartupInput.contains(untrustedRecordedDirectory), Comment(rawValue: secondStartupInput))
    }

    @MainActor
    @Test func unavailableRemoteAgentRetainsOnlyPersistentSSHReattach() throws {
        let defaultsName = "cmux-remote-persistent-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let capturedDirectory = "/Users/alice/persistent-agent-cwd"
        let trustedRuntimeDirectory = "/home/remote/persistent-project"
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(
                command: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "remote-cwd-policy"
            ),
            autoConnect: false
        )
        let sourcePanelId = try #require(source.focusedPanelId)
        let persistentSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: source.id,
            panelId: sourcePanelId
        )
        #expect(source.updateRemotePanelDirectory(
            panelId: sourcePanelId,
            directory: trustedRuntimeDirectory
        ))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .grok,
                sessionId: "persistent-grok-session",
                workingDirectory: capturedDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "grok",
                    executablePath: "grok",
                    arguments: ["grok", "--cwd", capturedDirectory],
                    workingDirectory: capturedDirectory
                ),
                registration: .builtInGrok
            ),
            panelId: sourcePanelId
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume persistent-grok-session --cwd '\(capturedDirectory)'",
            cwd: capturedDirectory,
            checkpointId: "persistent-grok-session",
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "grok",
                arguments: ["grok", "--cwd", capturedDirectory],
                workingDirectory: capturedDirectory
            ),
            autoResume: true,
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: source.id,
                surfaceID: sourcePanelId,
                persistentPTYSessionID: persistentSessionID
            ))
        )
        #expect(source.setSurfaceResumeBinding(binding, panelId: sourcePanelId))

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[sourcePanelId])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
        let retained = try #require(restored.restoredAgentSnapshotsByPanelId[restoredPanelId])

        #expect(retained.restoreWorkingDirectorySelection == .unavailable)
        #expect(retained.resumeCommand == nil)
        #expect(retained.forkCommand == nil)
        #expect(
            restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .manualResumeAvailable
        )
        #expect(restored.surfaceResumeBinding(panelId: restoredPanelId)?.launchFlavor.remoteContext != nil)

        let attachCommand = try #require(restoredPanel.surface.debugInitialCommand())
        #expect(attachCommand.contains("ssh-pty-attach"), Comment(rawValue: attachCommand))
        #expect(attachCommand.contains("--require-existing"), Comment(rawValue: attachCommand))
        #expect(!attachCommand.contains(capturedDirectory), Comment(rawValue: attachCommand))

        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(attachCommand).map(\.value)
        let commandIndex = try #require(words.firstIndex(of: "--command-b64"))
        let commandPayloadIndex = words.index(after: commandIndex)
        try #require(words.indices.contains(commandPayloadIndex))
        let commandPayload = words[commandPayloadIndex]
        let remoteCommandData = try #require(Data(base64Encoded: commandPayload))
        let remoteCommand = try #require(String(data: remoteCommandData, encoding: .utf8))
        let unsafeStartupInput = try #require(binding.remoteStartupInput())
        let unsafeStartupPayload = Data(unsafeStartupInput.utf8).base64EncodedString()
        #expect(!remoteCommand.contains(unsafeStartupPayload), Comment(rawValue: remoteCommand))
        #expect(!remoteCommand.contains(capturedDirectory), Comment(rawValue: remoteCommand))
    }

    @MainActor
    @Test func persistentSSHExactSelectionEmbedsOnlyConstrainedAgentStartupInput() throws {
        let capturedDirectory = "/Users/alice/persistent-agent-cwd"
        let trustedRemoteDirectory = "/home/remote/persistent-project"
        let sessionId = "persistent-codex-session"
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.configureRemoteConnection(
            remoteWorkspaceConfiguration(
                command: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "remote-exact-cwd-policy"
            ),
            autoConnect: false
        )
        let panelId = try #require(workspace.focusedPanelId)
        let persistentSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: workspace.id,
            panelId: panelId
        )
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: capturedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "-C", capturedDirectory],
                workingDirectory: capturedDirectory
            )
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionId) -C '\(capturedDirectory)'",
            cwd: capturedDirectory,
            checkpointId: sessionId,
            source: "agent-hook",
            environment: ["CODEX_HOME": "/tmp/remote-codex-home"],
            launchCommand: agent.launchCommand,
            autoResume: true,
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: workspace.id,
                surfaceID: panelId,
                persistentPTYSessionID: persistentSessionID
            ))
        )
        let constrainedBinding = binding.applyingRestoreWorkingDirectorySelection(
            .exact(trustedRemoteDirectory),
            from: agent
        )
        let constrainedStartupInput = try #require(constrainedBinding.remoteStartupInput())
        let remoteCommand = try #require(workspace.persistentSSHResumeCommand(
            for: constrainedBinding,
            expectedWorkspaceID: workspace.id,
            expectedSurfaceID: panelId,
            persistentPTYSessionID: persistentSessionID
        ))
        let constrainedPayload = Data(constrainedStartupInput.utf8).base64EncodedString()
        let unsafeStartupInput = try #require(binding.remoteStartupInput())
        let unsafePayload = Data(unsafeStartupInput.utf8).base64EncodedString()

        #expect(constrainedStartupInput.contains(trustedRemoteDirectory))
        #expect(!constrainedStartupInput.contains(capturedDirectory))
        #expect(constrainedStartupInput.contains("CODEX_HOME=/tmp/remote-codex-home"), Comment(rawValue: constrainedStartupInput))
        #expect(remoteCommand.contains(constrainedPayload), Comment(rawValue: remoteCommand))
        #expect(!remoteCommand.contains(unsafePayload), Comment(rawValue: remoteCommand))

        var staleExactNilBinding = binding
        staleExactNilBinding.restoreWorkingDirectorySelection = .exact(nil)
        let exactNilRemoteCommand = try #require(workspace.persistentSSHResumeCommand(
            for: staleExactNilBinding,
            expectedWorkspaceID: workspace.id,
            expectedSurfaceID: panelId,
            persistentPTYSessionID: persistentSessionID
        ))
        #expect(!exactNilRemoteCommand.contains(capturedDirectory), Comment(rawValue: exactNilRemoteCommand))

        var exactWithoutLaunchBinding = binding
        exactWithoutLaunchBinding.launchCommand = nil
        exactWithoutLaunchBinding.restoreWorkingDirectorySelection = .exact(trustedRemoteDirectory)
        let exactWithoutLaunchRemoteCommand = try #require(workspace.persistentSSHResumeCommand(
            for: exactWithoutLaunchBinding,
            expectedWorkspaceID: workspace.id,
            expectedSurfaceID: panelId,
            persistentPTYSessionID: persistentSessionID
        ))
        #expect(exactWithoutLaunchRemoteCommand.contains("--require-existing"))
        #expect(!exactWithoutLaunchRemoteCommand.contains(capturedDirectory))
    }

    @MainActor
    @Test(arguments: [RestorableAgentKind.codex, .opencode])
    func remoteManualResumeRecordUsesOnlyTrustedReportedDirectory(
        kind: RestorableAgentKind
    ) throws {
        let localWorkspaceDirectory = "/Users/alice/development"
        let capturedAgentDirectory = "/Users/alice/captured-agent-cwd"
        let capturedLaunchDirectory = "/Users/alice/captured-launch-cwd"
        let capturedArgumentDirectory = "/Users/alice/captured-argument-cwd"
        let trustedRemoteDirectory = "/home/remote/current-project"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "\(kind.rawValue)-remote-manual-\(UUID().uuidString)"
        let executable = kind == .codex ? "codex" : "opencode"
        let cwdOption = kind == .codex ? "-C" : "--cwd"
        let source = Workspace(
            workingDirectory: localWorkspaceDirectory,
            initialTerminalCommand: remoteCommand
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        #expect(source.updateRemotePanelDirectory(
            panelId: sourcePanelId,
            directory: trustedRemoteDirectory
        ))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: sessionId,
                workingDirectory: capturedAgentDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: executable,
                    executablePath: "/usr/local/bin/\(executable)",
                    arguments: [
                        "/usr/local/bin/\(executable)",
                        cwdOption,
                        capturedArgumentDirectory,
                        "--model",
                        "test-model",
                    ],
                    workingDirectory: capturedLaunchDirectory,
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            ),
            panelId: sourcePanelId
        )
        #expect(source.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: kind.rawValue,
                command: "\(executable) resume \(sessionId) \(cwdOption) '\(capturedArgumentDirectory)'",
                cwd: capturedAgentDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: executable,
                    executablePath: "/usr/local/bin/\(executable)",
                    arguments: [
                        "/usr/local/bin/\(executable)",
                        cwdOption,
                        capturedArgumentDirectory,
                        "--model",
                        "test-model",
                    ],
                    workingDirectory: capturedLaunchDirectory
                ),
                autoResume: true
            ),
            panelId: sourcePanelId
        ))

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        try withRestoredRemoteSurface(
            snapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: false
        ) { workspace, panelId, panel, restoreRecord in
            #expect(panel.surface.initialInput == nil)
            #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .manualResumeAvailable)
            #expect(restoreRecord.kind == kind.rawValue)
            #expect(restoreRecord.checkpointID == sessionId)
            #expect(restoreRecord.workingDirectory == trustedRemoteDirectory)
            #expect(restoreRecord.preparedArgumentsWorkingDirectory == trustedRemoteDirectory)

            let launchCommand = try #require(restoreRecord.launchCommand)
            #expect(launchCommand.workingDirectory == nil)
            let launchArguments = launchCommand.arguments.joined(separator: " ")
            #expect(!launchArguments.contains(capturedAgentDirectory))
            #expect(!launchArguments.contains(capturedLaunchDirectory))
            #expect(!launchArguments.contains(capturedArgumentDirectory))
            #expect(!launchCommand.arguments.contains(cwdOption))

            let preparedArguments = try #require(restoreRecord.preparedArguments)
                .joined(separator: " ")
            #expect(!preparedArguments.contains(capturedAgentDirectory))
            #expect(!preparedArguments.contains(capturedLaunchDirectory))
            #expect(!preparedArguments.contains(capturedArgumentDirectory))

            let continuation = try #require(
                workspace.restoredAgentSnapshotsByPanelId[panelId]
            )
            let resumeCommand = try #require(continuation.resumeCommand)
            #expect(resumeCommand.contains(trustedRemoteDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedAgentDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedLaunchDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedArgumentDirectory), Comment(rawValue: resumeCommand))

            workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
            #expect(workspace.restoredAgentSnapshotsByPanelId[panelId] == nil)
            let retainedBinding = try #require(
                workspace.sessionSnapshot(includeScrollback: false)
                    .panels.first(where: { $0.id == panelId })?
                    .terminal?.resumeBinding
            )
            let retainedInput = try #require(
                retainedBinding.inlineStartupInput(repairPortableAgentExecutable: false)
            )
            #expect(retainedBinding.restoreWorkingDirectorySelection == .exact(trustedRemoteDirectory))
            #expect(retainedBinding.autoResume == false)
            #expect(retainedInput.contains(trustedRemoteDirectory), Comment(rawValue: retainedInput))
            #expect(!retainedInput.contains(capturedAgentDirectory), Comment(rawValue: retainedInput))
            #expect(!retainedInput.contains(capturedLaunchDirectory), Comment(rawValue: retainedInput))
            #expect(!retainedInput.contains(capturedArgumentDirectory), Comment(rawValue: retainedInput))
        }
    }

    @MainActor
    @Test func hibernatedRemoteContinuationUsesOnlyTrustedReportedDirectory() throws {
        let localWorkspaceDirectory = "/Users/alice/development"
        let capturedAgentDirectory = "/Users/alice/hibernated-agent-cwd"
        let capturedLaunchDirectory = "/Users/alice/hibernated-launch-cwd"
        let capturedArgumentDirectory = "/Users/alice/hibernated-argument-cwd"
        let trustedRemoteDirectory = "/home/remote/hibernated-project"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "codex-remote-hibernated-\(UUID().uuidString)"
        let source = Workspace(
            workingDirectory: localWorkspaceDirectory,
            initialTerminalCommand: remoteCommand
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        #expect(source.updateRemotePanelDirectory(
            panelId: sourcePanelId,
            directory: trustedRemoteDirectory
        ))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionId,
                workingDirectory: capturedAgentDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "codex",
                    executablePath: "/usr/local/bin/codex",
                    arguments: [
                        "/usr/local/bin/codex",
                        "-C\(capturedArgumentDirectory)",
                        "--model",
                        "test-model",
                    ],
                    workingDirectory: capturedLaunchDirectory,
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            ),
            panelId: sourcePanelId
        )

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelId })
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        terminalSnapshot.hibernation = SessionAgentHibernationSnapshot(
            hibernatedAt: 1_777_777_777,
            lastActivityAt: 1_777_777_700
        )
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        try withRestoredRemoteSurface(
            snapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: true,
            agentHibernationPresentationVisible: false
        ) { workspace, panelId, panel, restoreRecord in
            #expect(panel.isAgentHibernated)
            #expect(restoreRecord.workingDirectory == trustedRemoteDirectory)
            #expect(restoreRecord.launchCommand?.workingDirectory == nil)

            let structuredArguments = [
                restoreRecord.launchCommand?.arguments.joined(separator: " "),
                restoreRecord.preparedArguments?.joined(separator: " "),
            ].compactMap { $0 }.joined(separator: " ")
            #expect(!structuredArguments.contains(capturedAgentDirectory))
            #expect(!structuredArguments.contains(capturedLaunchDirectory))
            #expect(!structuredArguments.contains(capturedArgumentDirectory))

            let hibernatedAgent = try #require(panel.agentHibernationState?.agent)
            let resumeCommand = try #require(hibernatedAgent.resumeCommand)
            #expect(resumeCommand.contains(trustedRemoteDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedAgentDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedLaunchDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedArgumentDirectory), Comment(rawValue: resumeCommand))

            #expect(workspace.resumeAgentHibernation(panelId: panelId, focus: false))
            let queuedInput = try #require(panel.surface.debugInitialInputForTesting())
            #expect(queuedInput.contains(sessionId), Comment(rawValue: queuedInput))
            #expect(queuedInput.contains(trustedRemoteDirectory), Comment(rawValue: queuedInput))
            #expect(!queuedInput.contains(capturedAgentDirectory), Comment(rawValue: queuedInput))
            #expect(!queuedInput.contains(capturedLaunchDirectory), Comment(rawValue: queuedInput))
            #expect(!queuedInput.contains(capturedArgumentDirectory), Comment(rawValue: queuedInput))
        }
    }

    @MainActor
    private func withRestoredRemoteSurface<T>(
        _ snapshot: SessionWorkspaceSnapshot,
        sourcePanelId: UUID,
        autoResumeAgentSessions: Bool,
        agentHibernationPresentationVisible: Bool = true,
        body: (
            _ workspace: Workspace,
            _ panelId: UUID,
            _ panel: TerminalPanel,
            _ restoreRecord: ControlSurfaceRestoreRecord
        ) throws -> T
    ) throws -> T {
        try withRestoredRemoteSurfaceSnapshot(
            snapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: autoResumeAgentSessions,
            agentHibernationPresentationVisible: agentHibernationPresentationVisible
        ) { workspace, panelId, panel, resumeSnapshot in
            let restoreRecord = try #require(resumeSnapshot.restoreRecord)
            return try body(workspace, panelId, panel, restoreRecord)
        }
    }

    @MainActor
    private func withRestoredRemoteSurfaceSnapshot<T>(
        _ snapshot: SessionWorkspaceSnapshot,
        sourcePanelId: UUID,
        autoResumeAgentSessions: Bool,
        agentHibernationPresentationVisible: Bool = true,
        body: (
            _ workspace: Workspace,
            _ panelId: UUID,
            _ panel: TerminalPanel,
            _ resumeSnapshot: ControlSurfaceResumeSnapshot
        ) throws -> T
    ) throws -> T {
        let defaultsName = "cmux-remote-restore-helper-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(
            autoResumeAgentSessions,
            forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        )

        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            agentSessionAutoResumeDefaults: defaults
        )
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
            window.orderOut(nil)
        }

        let workspace = try #require(manager.selectedWorkspace)
        workspace.setAgentHibernationAutoResumePresentationVisible(
            agentHibernationPresentationVisible
        )
        let restoredPanelIds = workspace.restoreSessionSnapshot(snapshot)
        let panelId = try #require(restoredPanelIds[sourcePanelId])
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: true,
            windowID: windowId,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: panelId,
            paneID: nil
        )
        let resolution = TerminalController.shared.controlSurfaceResumeGet(
            routing: routing,
            explicitTargetID: panelId,
            hasResolvedWindowID: true
        )
        guard case .result(let result) = resolution else {
            Issue.record("surface.resume.get failed: \(resolution)")
            throw RemoteSurfaceRestoreTestError.resumeRecordUnavailable
        }
        return try body(workspace, panelId, panel, result)
    }

    private enum RemoteSurfaceRestoreTestError: Error {
        case resumeRecordUnavailable
    }

    private func remoteWorkspaceConfiguration(
        command: String,
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_000,
            relayID: "relay-remote-cwd-\(UUID().uuidString)",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-remote-cwd-\(UUID().uuidString).sock",
            terminalStartupCommand: command,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot
        )
    }

    private func restorableCodexAgent(
        sessionId: String,
        workingDirectory: String
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: workingDirectory,
                environment: [:],
                capturedAt: 1_777_777_777,
                source: "process"
            )
        )
    }
}
