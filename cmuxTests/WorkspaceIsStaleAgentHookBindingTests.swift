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
}
