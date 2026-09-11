import CMUXAgentLaunch
import Foundation
import CmuxCore
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SessionPersistenceResumeBindingTests {
    @Test func restoreWorkingDirectorySelectionRoundTripsAndFailsClosed() throws {
        let unsafeDirectory = "/Users/alice/captured-cwd"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume session --cwd '\(unsafeDirectory)'",
            cwd: unsafeDirectory,
            checkpointId: "session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .unavailable,
            autoResume: true
        )

        let encoded = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(SurfaceResumeBindingSnapshot.self, from: encoded)

        #expect(decoded.restoreWorkingDirectorySelection == .unavailable)
        #expect(decoded.inlineStartupInput(repairPortableAgentExecutable: false) == nil)
        #expect(decoded.remoteStartupInput() == nil)
    }

    @Test func unavailableSelectionErasesPersistedAgentRestoreRecipe() {
        let unsafeDirectory = "/Users/alice/captured-cwd"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume session --cwd '\(unsafeDirectory)'",
            cwd: unsafeDirectory,
            checkpointId: "session",
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "/usr/local/bin/grok",
                arguments: ["/usr/local/bin/grok", "--cwd", unsafeDirectory],
                workingDirectory: unsafeDirectory
            ),
            autoResume: true
        )
        let agent = SessionRestorableAgentSnapshot(
            kind: .grok,
            sessionId: "session",
            workingDirectory: unsafeDirectory,
            launchCommand: binding.launchCommand
        )

        let constrained = binding.applyingRestoreWorkingDirectorySelection(
            .unavailable,
            from: agent
        )

        #expect(constrained.restoreWorkingDirectorySelection == .unavailable)
        #expect(constrained.command.isEmpty)
        #expect(constrained.cwd == nil)
        #expect(constrained.launchCommand == nil)
    }

    @Test func exactRestoreWithoutLaunchCapturePreservesBindingEnvironment() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume remote-session",
            cwd: "/home/remote/project",
            checkpointId: "remote-session",
            source: "agent-hook",
            environment: ["CODEX_HOME": "/home/remote/.codex"],
            restoreWorkingDirectorySelection: .exact("/home/remote/project")
        )

        let startupInput = try #require(binding.remoteStartupInput())
        #expect(
            startupInput.contains("CODEX_HOME=/home/remote/.codex"),
            Comment(rawValue: startupInput)
        )
        #expect(startupInput.contains("/home/remote/project"), Comment(rawValue: startupInput))
    }

    @Test func exactRestoreRepairsStaleManagedExecutableBeforeWrapping() throws {
        let staleExecutable = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-shims", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)
            .path
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "'\(staleExecutable)' claude-teams --resume stale-session",
            cwd: "/home/remote/project",
            checkpointId: "stale-session",
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claudeTeams",
                executablePath: staleExecutable,
                arguments: [staleExecutable, "claude-teams", "--model", "sonnet"],
                workingDirectory: "/Users/alice/local-project"
            ),
            restoreWorkingDirectorySelection: .exact("/home/remote/project")
        )

        let startupInput = try #require(
            binding.inlineStartupInput(repairPortableAgentExecutable: true)
        )
        #expect(!startupInput.contains(staleExecutable), Comment(rawValue: startupInput))
        #expect(startupInput.contains("claude-teams"), Comment(rawValue: startupInput))
    }

    @Test func localHookRefreshDoesNotInheritRemoteRestorePolicy() throws {
        let sessionID = "same-session-execution-boundary"
        let remoteContext = SurfaceResumeRemoteContext(
            workspaceID: UUID(),
            surfaceID: UUID(),
            persistentPTYSessionID: "remote-pty"
        )
        let remoteBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: "/home/remote/project",
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "resume", sessionID],
                workingDirectory: "/home/remote/project"
            ),
            restoreWorkingDirectorySelection: .exact("/home/remote/project"),
            launchFlavor: .persistentSSH(remoteContext)
        )
        let localRefresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            checkpointId: sessionID,
            source: "agent-hook",
            launchFlavor: .local
        )
        let remoteSnapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/home/remote/project",
            launchCommand: remoteBinding.launchCommand,
            restoreWorkingDirectorySelection: .exact("/home/remote/project")
        )

        let snapshot = try #require(
            localRefresh.managedRestorableAgentSnapshot(
                replacing: remoteSnapshot,
                previousBinding: remoteBinding
            )
        )
        #expect(snapshot.workingDirectory == nil)
        #expect(snapshot.launchCommand == nil)
        #expect(snapshot.restoreWorkingDirectorySelection == nil)
    }

    @Test func unavailableRestorePolicySurvivesCwdRetargeting() {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume session",
            cwd: nil,
            checkpointId: "session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .unavailable
        )

        let retargeted = binding.retargetingWorkingDirectory("/remote/new-project")
        #expect(retargeted == binding)
    }

    @Test func persistentSSHOwnerRetargetKeepsSamePTYSessionState() throws {
        let sessionID = "same-session-retarget"
        let persistentPTYSessionID = "stable-remote-pty"
        let sourceContext = SurfaceResumeRemoteContext(
            workspaceID: UUID(),
            surfaceID: UUID(),
            persistentPTYSessionID: persistentPTYSessionID
        )
        let destinationContext = SurfaceResumeRemoteContext(
            workspaceID: UUID(),
            surfaceID: UUID(),
            persistentPTYSessionID: " \(persistentPTYSessionID) "
        )
        let previousBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: "/home/remote/project",
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "resume", sessionID],
                workingDirectory: "/home/remote/project"
            ),
            restoreWorkingDirectorySelection: .exact("/home/remote/project"),
            launchFlavor: .persistentSSH(sourceContext)
        )
        let retargetedRefresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            checkpointId: sessionID,
            source: "agent-hook",
            launchFlavor: .persistentSSH(destinationContext)
        )
        let previousSnapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/home/remote/project",
            launchCommand: previousBinding.launchCommand,
            restoreWorkingDirectorySelection: .exact("/home/remote/project")
        )

        let snapshot = try #require(
            retargetedRefresh.managedRestorableAgentSnapshot(
                replacing: previousSnapshot,
                previousBinding: previousBinding
            )
        )
        #expect(snapshot.workingDirectory == previousSnapshot.workingDirectory)
        #expect(snapshot.launchCommand == previousSnapshot.launchCommand)
        #expect(
            snapshot.restoreWorkingDirectorySelection ==
                previousSnapshot.restoreWorkingDirectorySelection
        )
    }

    @Test func blankPersistentPTYIDsNeverShareExecutionLocation() {
        let lhs = SurfaceResumeLaunchFlavor.persistentSSH(
            SurfaceResumeRemoteContext(
                workspaceID: UUID(),
                surfaceID: UUID(),
                persistentPTYSessionID: " "
            )
        )
        let rhs = SurfaceResumeLaunchFlavor.persistentSSH(
            SurfaceResumeRemoteContext(
                workspaceID: UUID(),
                surfaceID: UUID(),
                persistentPTYSessionID: "\n"
            )
        )
        #expect(!lhs.representsSameExecutionLocation(as: rhs))
    }

    @MainActor
    @Test func detachedIdKeyedRetargetRefreshesCwdSelection() throws {
        let oldDirectory = "/remote/old-project"
        let liveDirectory = "/remote/live-project"
        let codexBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume detached-session",
            cwd: oldDirectory,
            checkpointId: "detached-session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .exact(oldDirectory)
        )
        let retargetedCodex = try #require(
            DockSplitStore.dockResumeBinding(
                preservedBinding: codexBinding,
                preservedSessionDirectory: oldDirectory,
                restoredResumeSessionWorkingDirectory: liveDirectory,
                detachedDirectoryWasReadFromLiveForegroundProcess: true,
                agentProvenExited: false
            )
        )

        #expect(retargetedCodex.cwd == liveDirectory)
        #expect(
            retargetedCodex.restoreWorkingDirectorySelection == .exact(liveDirectory)
        )

        let directoryKeyedBinding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume detached-session",
            cwd: oldDirectory,
            checkpointId: "detached-session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .exact(oldDirectory)
        )
        let retainedDirectoryKeyed = try #require(
            DockSplitStore.dockResumeBinding(
                preservedBinding: directoryKeyedBinding,
                preservedSessionDirectory: oldDirectory,
                restoredResumeSessionWorkingDirectory: liveDirectory,
                detachedDirectoryWasReadFromLiveForegroundProcess: true,
                agentProvenExited: false
            )
        )
        #expect(retainedDirectoryKeyed.cwd == oldDirectory)
        #expect(
            retainedDirectoryKeyed.restoreWorkingDirectorySelection == .exact(oldDirectory)
        )
    }

    @MainActor
    @Test func localHookRefreshDoesNotApplyRetainedRemotePolicy() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
        }
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "workspace-execution-boundary"
        let remoteBinding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume \(sessionID)",
            cwd: "/home/remote/project",
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "grok",
                arguments: ["grok", "--resume", sessionID],
                workingDirectory: "/home/remote/project"
            ),
            restoreWorkingDirectorySelection: .exact("/home/remote/project"),
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: workspace.id,
                surfaceID: panelID,
                persistentPTYSessionID: "workspace-remote-pty"
            ))
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = remoteBinding
        workspace.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .grok,
                sessionId: sessionID,
                workingDirectory: "/home/remote/project",
                launchCommand: remoteBinding.launchCommand,
                registration: .builtInGrok,
                restoreWorkingDirectorySelection: .exact("/home/remote/project")
            ),
            panelId: panelID
        )

        let localRefresh = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume \(sessionID)",
            checkpointId: sessionID,
            source: "agent-hook",
            launchFlavor: .local
        )
        #expect(workspace.setSurfaceResumeBinding(localRefresh, panelId: panelID))

        let storedBinding = try #require(workspace.surfaceResumeBinding(panelId: panelID))
        #expect(storedBinding.launchFlavor == .local)
        #expect(storedBinding.restoreWorkingDirectorySelection == nil)
        #expect(storedBinding.cwd == nil)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelID]?.restoreWorkingDirectorySelection == nil)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelID]?.workingDirectory == nil)
    }

    @MainActor
    @Test func resumeBindingSelectionChangesAutosaveFingerprint() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
        }
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        var binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume fingerprint-session",
            cwd: "/srv/project",
            checkpointId: "fingerprint-session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .exact("/srv/project"),
            autoResume: true
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = binding
        let exactFingerprint = manager.sessionAutosaveFingerprint()

        binding.restoreWorkingDirectorySelection = .unavailable
        workspace.surfaceResumeBindingsByPanelId[panelID] = binding
        let unavailableFingerprint = manager.sessionAutosaveFingerprint()

        #expect(exactFingerprint != unavailableFingerprint)
    }

}
