import Darwin
import Foundation
import CmuxCore
import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentSessionAutoResumeSwiftTests {
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

            try assertAgentAutoResumeUsesStartupCommand(
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
            #expect(restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding == nil)
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

            // The agent exits: the shell reaches a prompt, which invalidates the
            // restored-resume state and re-reports the real cwd.
            restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)
            try #require(restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == nil)
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
            try assertAgentAutoResumeUsesStartupCommand(
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
            try assertAgentAutoResumeUsesStartupCommand(
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

            try assertAgentAutoResumeUsesStartupCommand(
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
    private func assertAgentAutoResumeUsesStartupCommand(
        _ panel: TerminalPanel,
        scriptContains needles: [String],
        scriptDoesNotContain excludedNeedles: [String] = []
    ) throws {
        let command = try #require(panel.surface.debugInitialCommand())
        #expect(command.hasPrefix("/bin/zsh '"), Comment(rawValue: command))
        let scriptPath = String(command.dropFirst("/bin/zsh '".count).dropLast())
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        for needle in needles {
            #expect(script.contains(needle), Comment(rawValue: script))
        }
        for needle in excludedNeedles {
            #expect(!script.contains(needle), Comment(rawValue: script))
        }
        #expect(script.contains("CMUX_SHELL_INTEGRATION_DIR"), Comment(rawValue: script))
        #expect(script.contains("CMUX_ZSH_ZDOTDIR"), Comment(rawValue: script))
        #expect(script.contains("\"$_cmux_resume_shell\" -lic"), Comment(rawValue: script))
        #expect(script.contains("csh|tcsh) \"$_cmux_resume_shell\" -c"), Comment(rawValue: script))
        #expect(script.contains("exec -l \"$_cmux_resume_shell\""), Comment(rawValue: script))
    }
}
