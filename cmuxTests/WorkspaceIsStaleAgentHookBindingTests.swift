import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #8446: `isStaleAgentHookBinding` must only judge
/// staleness for `.local` agent-hook bindings. `RestorableAgentSessionIndex`
/// is built from a local process scan, so a `.persistentSSH` binding's
/// remote-host process can never appear in it; treating that absence as
/// "stale" would prune every live remote agent-hook binding on the very next
/// reconciliation.
@MainActor
@Suite
struct WorkspaceIsStaleAgentHookBindingTests {
    private static let piSessionID = "019fbf0f-7fcd-70aa-9388-f44c4e27fa0c"
    private static let piSessionPath =
        "/Users/test/.pi/agent/sessions/--Users-test-project--/" +
        "2026-08-01T18-39-09-000Z_\(piSessionID).jsonl"

    private static func agentHookBinding(
        launchFlavor: SurfaceResumeLaunchFlavor
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume session-1",
            checkpointId: "session-1",
            source: "agent-hook",
            launchFlavor: launchFlavor
        )
    }

    private static func piAgentHookBinding() -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            kind: "pi",
            command: "pi --session \(piSessionID)",
            checkpointId: piSessionID,
            source: "agent-hook"
        )
    }

    private static func livePiIndex(
        workspaceId: UUID,
        panelId: UUID
    ) -> RestorableAgentSessionIndex {
        let key = RestorableAgentSessionIndex.PanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        return RestorableAgentSessionIndex.load(
            homeDirectory: "/tmp/cmux-pi-repeat-restore-empty-home",
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                key: (
                    snapshot: SessionRestorableAgentSnapshot(
                        kind: .custom("pi"),
                        sessionId: piSessionPath
                    ),
                    updatedAt: 1,
                    processIDs: [31_398],
                    agentProcessIDs: [31_398],
                    sessionIDSource: .explicit
                ),
            ],
            processIdentityProvider: { _ in nil }
        )
    }

    @Test
    func localAgentHookBindingWithNoLiveProcessIsStale() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let binding = Self.agentHookBinding(launchFlavor: .local)

        #expect(workspace.isStaleAgentHookBinding(binding, panelId: panelId) == true)
    }

    @Test
    func persistentSSHAgentHookBindingIsNeverConsideredStaleByLocalScan() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let remoteContext = SurfaceResumeRemoteContext(
            workspaceID: workspace.id,
            surfaceID: panelId,
            persistentPTYSessionID: "remote-pty-1"
        )
        let binding = Self.agentHookBinding(launchFlavor: .persistentSSH(remoteContext))

        // No local process can ever exist for a remote agent, so this must
        // NOT be reported as stale (that would delete a still-live remote
        // binding on the next reconciliation).
        #expect(workspace.isStaleAgentHookBinding(binding, panelId: panelId) == false)
    }

    @Test
    func staleAgentHookBindingIsRetainedForManualRestore() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = Self.agentHookBinding(launchFlavor: .local)
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))

        workspace.reconcileSurfaceResumeBindings(
            using: .empty,
            restorableAgentIndex: .empty
        )

        let retainedBinding = try #require(workspace.surfaceResumeBinding(panelId: panelId))
        #expect(retainedBinding.checkpointId == binding.checkpointId)
        #expect(retainedBinding.autoResume == false)
    }

    @Test
    func plainSSHProcessBindingSurvivesATransientMissedProcessScan() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "ssh",
            command: "'/usr/bin/ssh' 'tinybox'",
            cwd: "/Users/test",
            source: "process-detected",
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))

        workspace.reconcileSurfaceResumeBindings(
            using: .empty,
            restorableAgentIndex: .empty
        )

        #expect(workspace.surfaceResumeBinding(panelId: panelId) == binding)
        #expect(
            workspace.effectiveSurfaceResumeBinding(
                panelId: panelId,
                surfaceResumeBindingIndex: .empty
        ) == binding
        )
    }

    @Test
    func plainSSHProcessBindingIsRetiredAfterTheSSHChildExits() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "ssh",
            command: "'/usr/bin/ssh' 'tinybox'",
            source: "process-detected",
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))

        // One empty scan is a process-scan hiccup; the second is authoritative
        // absence after the observed SSH process has ended.
        workspace.reconcileSurfaceResumeBindings(using: .empty, restorableAgentIndex: .empty)
        #expect(workspace.surfaceResumeBinding(panelId: panelId) != nil)
        workspace.reconcileSurfaceResumeBindings(using: .empty, restorableAgentIndex: .empty)
        #expect(workspace.surfaceResumeBinding(panelId: panelId) == nil)
    }

    @Test
    func plainSSHProcessBindingIsClearedWhenShellReturnsToPrompt() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "ssh",
            command: "'/usr/bin/ssh' 'tinybox'",
            source: "process-detected",
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))

        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        #expect(workspace.surfaceResumeBinding(panelId: panelId) == nil)
    }

    @Test
    func reconciliationKeepsPiBindingAfterResumeScannerResolvesUUIDToSessionPath() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let binding = Self.piAgentHookBinding()
        let index = Self.livePiIndex(workspaceId: workspace.id, panelId: panelId)
        try #require(workspace.setSurfaceResumeBinding(binding, panelId: panelId))

        workspace.reconcileSurfaceResumeBindings(
            using: .empty,
            restorableAgentIndex: index
        )

        #expect(workspace.surfaceResumeBinding(panelId: panelId) == binding)
    }

    @Test
    func sessionRestoreMatchesPiBindingUUIDToDetectedSessionPath() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let binding = Self.piAgentHookBinding()
        let index = Self.livePiIndex(workspaceId: workspace.id, panelId: panelId)
        let detectedSnapshot = try #require(
            index.snapshot(workspaceId: workspace.id, panelId: panelId)
        )

        let restoredSnapshot = Workspace.restorableAgentForSessionRestore(
            detectedSnapshot,
            resumeBinding: binding
        )

        #expect(restoredSnapshot?.sessionId == Self.piSessionPath)
    }
}
