import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies the app-owned compare-and-claim boundary used by Codex restore.
@MainActor
@Suite(.serialized)
struct SurfaceResumeRestoreClaimTests {
    @Test
    func workspaceRestoreClaimRejectsReplacementAndPreservesParentBinding() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let parent = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            cwd: "/tmp/parent-cwd",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 10
        )
        let child = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume child-session",
            cwd: "/tmp/child-cwd",
            checkpointId: "child-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 11
        )

        #expect(workspace.setSurfaceResumeBinding(parent, panelId: panelID))
        #expect(workspace.claimSurfaceResumeBinding(
            panelId: panelID,
            expectedCheckpointID: "parent-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 10
        ))
        #expect(!workspace.setSurfaceResumeBinding(child, panelId: panelID))
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == parent)
    }

    @Test
    func workspaceRestoreClaimRejectsExecutionLocationChange() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let remoteContext = SurfaceResumeRemoteContext(
            workspaceID: workspace.id,
            surfaceID: panelID,
            persistentPTYSessionID: "remote-claim-session"
        )
        let remoteParent = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume shared-session",
            cwd: "/remote/project",
            checkpointId: "shared-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            launchFlavor: .persistentSSH(remoteContext),
            updatedAt: 12
        )
        let localRefresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume shared-session",
            checkpointId: "shared-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            launchFlavor: .local,
            updatedAt: 13
        )

        #expect(workspace.setSurfaceResumeBinding(remoteParent, panelId: panelID))
        #expect(workspace.claimSurfaceResumeBinding(
            panelId: panelID,
            expectedCheckpointID: "shared-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 12
        ))
        #expect(!workspace.setSurfaceResumeBinding(localRefresh, panelId: panelID))
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == remoteParent)
    }

    @Test
    func dockRestoreClaimConsumesOnSameSessionRefresh() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel
        let parent = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 20
        )
        let refresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            cwd: "/tmp/refreshed-cwd",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 21
        )

        #expect(store.setSurfaceResumeBinding(parent, panelId: panel.id))
        #expect(store.claimSurfaceResumeBinding(
            panelId: panel.id,
            expectedCheckpointID: "parent-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 20
        ))
        #expect(store.setSurfaceResumeBinding(refresh, panelId: panel.id))
        #expect(store.surfaceResumeBinding(panelId: panel.id) == refresh)
        #expect(store.surfaceResumeRestoreClaimsByPanelId[panel.id] == nil)
    }

    @Test
    func dockRestoreClaimRejectsExecutionLocationChange() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel
        let remoteParent = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume shared-session",
            cwd: "/remote/project",
            checkpointId: "shared-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: store.workspaceId,
                surfaceID: panel.id,
                persistentPTYSessionID: "remote-claim-session"
            )),
            updatedAt: 22
        )
        let localRefresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume shared-session",
            checkpointId: "shared-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            launchFlavor: .local,
            updatedAt: 23
        )

        #expect(store.setSurfaceResumeBinding(remoteParent, panelId: panel.id))
        #expect(store.claimSurfaceResumeBinding(
            panelId: panel.id,
            expectedCheckpointID: "shared-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 22
        ))
        #expect(!store.setSurfaceResumeBinding(localRefresh, panelId: panel.id))
        #expect(store.surfaceResumeBinding(panelId: panel.id) == remoteParent)
    }

    @Test
    func dockBindingAppliesAuthoritativeRemoteSelectionToRetainedSnapshot() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel

        let capturedDirectory = "/Users/austin/local-codex-project"
        let trustedRemoteDirectory = "/home/remote/codex-project"
        let sessionID = "dock-remote-cwd-session"
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "codex",
            arguments: ["codex", "resume", sessionID, "-C", capturedDirectory],
            workingDirectory: capturedDirectory
        )
        store.restoredAgentLifecycle.setSnapshot(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionID,
                workingDirectory: capturedDirectory,
                launchCommand: launchCommand
            ),
            panelId: panel.id
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID) -C '\(capturedDirectory)'",
            cwd: capturedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            restoreWorkingDirectorySelection: .exact(trustedRemoteDirectory),
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: store.workspaceId,
                surfaceID: panel.id,
                persistentPTYSessionID: "dock-remote-pty"
            ))
        )

        #expect(store.setSurfaceResumeBinding(binding, panelId: panel.id))
        let storedBinding = try #require(store.surfaceResumeBinding(panelId: panel.id))
        let retainedSnapshot = try #require(
            store.restoredAgentLifecycle.snapshotsByPanelId[panel.id]
        )
        #expect(storedBinding.cwd == trustedRemoteDirectory)
        #expect(storedBinding.launchCommand?.workingDirectory == nil)
        #expect(storedBinding.launchCommand?.arguments.contains(capturedDirectory) == false)
        #expect(retainedSnapshot.workingDirectory == trustedRemoteDirectory)
        #expect(retainedSnapshot.launchCommand?.workingDirectory == nil)
        #expect(retainedSnapshot.launchCommand?.arguments.contains(capturedDirectory) == false)
        #expect(
            retainedSnapshot.restoreWorkingDirectorySelection == .exact(trustedRemoteDirectory)
        )
    }

    @Test
    func dockFreshRemoteSelectionWinsAfterRetainedSnapshotClears() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel
        let remoteContext = SurfaceResumeRemoteContext(
            workspaceID: store.workspaceId,
            surfaceID: panel.id,
            persistentPTYSessionID: "dock-remote-pty"
        )
        let sessionID = "dock-cleared-snapshot-session"
        let previous = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID) -C '/home/remote/old-project'",
            cwd: "/home/remote/old-project",
            checkpointId: sessionID,
            source: "agent-hook",
            restoreWorkingDirectorySelection: .exact("/home/remote/old-project"),
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            launchFlavor: .persistentSSH(remoteContext),
            updatedAt: 1
        )
        #expect(store.setSurfaceResumeBinding(previous, panelId: panel.id))
        store.restoredAgentLifecycle.clearSessionRestore(panelId: panel.id)

        let fresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID) -C '/home/remote/new-project'",
            cwd: "/home/remote/new-project",
            checkpointId: sessionID,
            source: "agent-hook",
            restoreWorkingDirectorySelection: .exact("/home/remote/new-project"),
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            launchFlavor: .persistentSSH(remoteContext),
            updatedAt: 2
        )
        #expect(store.setSurfaceResumeBinding(fresh, panelId: panel.id))
        let stored = try #require(store.surfaceResumeBinding(panelId: panel.id))
        #expect(stored.cwd == "/home/remote/new-project")
        #expect(
            stored.restoreWorkingDirectorySelection == .exact("/home/remote/new-project")
        )
    }

    @Test
    func managedSnapshotDropsCapturedCwdForExactNilSelection() throws {
        let capturedDirectory = "/Users/austin/local-codex-project"
        let sessionID = "exact-nil-cwd-session"
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "codex",
            arguments: ["codex", "resume", sessionID, "-C", capturedDirectory],
            workingDirectory: capturedDirectory
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID) -C '\(capturedDirectory)'",
            cwd: capturedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            restoreWorkingDirectorySelection: .exact(nil)
        )

        let snapshot = try #require(
            binding.managedRestorableAgentSnapshot(
                replacing: nil,
                previousBinding: nil
            )
        )
        #expect(snapshot.workingDirectory == nil)
        #expect(snapshot.launchCommand?.workingDirectory == nil)
        #expect(snapshot.launchCommand?.arguments.contains(capturedDirectory) == false)
    }

    @Test
    func compatibilityForkHonorsExactNilRestoreSelection() throws {
        let capturedDirectory = "/Users/austin/local-codex-project"
        let sessionID = "exact-nil-fork-session"
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: capturedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "resume", sessionID, "-C", capturedDirectory],
                workingDirectory: capturedDirectory
            ),
            restoreWorkingDirectorySelection: .exact(nil)
        )

        let forkCommand = try #require(
            agent.forkCommand(restoringWorkingDirectory: "/remote/ignored")
        )
        #expect(forkCommand.contains(capturedDirectory) == false)
        #expect(forkCommand.contains("/remote/ignored") == false)
    }

    @Test
    func restoreClaimRequiresExactBindingGeneration() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 30
        )

        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))
        #expect(!workspace.claimSurfaceResumeBinding(
            panelId: panelID,
            expectedCheckpointID: "parent-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 31
        ))
        #expect(workspace.surfaceResumeRestoreClaimsByPanelId[panelID] == nil)
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == binding)
    }

    @Test
    func workspacePanelTeardownReleasesRestoreClaim() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume teardown-session",
            checkpointId: "teardown-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 40
        )

        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))
        #expect(workspace.claimSurfaceResumeBinding(
            panelId: panelID,
            expectedCheckpointID: "teardown-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 40
        ))
        workspace.teardownAllPanels()

        #expect(workspace.surfaceResumeRestoreClaimsByPanelId.isEmpty)
    }

    @Test
    func workspaceReconciliationCannotReplaceClaimedCodexBinding() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let parent = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 50
        )
        let detectedChild = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume child-session",
            checkpointId: "child-session",
            source: "process-detected",
            autoResume: true,
            updatedAt: 51
        )

        #expect(workspace.setSurfaceResumeBinding(parent, panelId: panelID))
        #expect(workspace.claimSurfaceResumeBinding(
            panelId: panelID,
            expectedCheckpointID: "parent-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 50
        ))
        workspace.reconcileSurfaceResumeBindings(
            using: SurfaceResumeBindingIndex(bindingsByPanel: [
                .init(workspaceId: workspace.id, panelId: panelID): detectedChild,
            ]),
            restorableAgentIndex: .empty
        )

        #expect(workspace.surfaceResumeBinding(panelId: panelID) == parent)
    }
}
