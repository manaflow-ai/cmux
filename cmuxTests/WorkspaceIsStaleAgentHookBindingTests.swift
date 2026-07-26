import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Agent-hook bindings are durable session identity. Process liveness controls
/// automatic launch through `wasAgentRunning`; it must not erase the binding.
@MainActor
@Suite
struct WorkspaceDurableAgentHookBindingTests {
    private static func agentHookBinding(
        launchFlavor: SurfaceResumeLaunchFlavor
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume session-1",
            checkpointId: "session-1",
            source: "agent-hook",
            launchFlavor: launchFlavor
        )
    }

    @Test
    func snapshotPreservesDurableAgentHookBindingWhenProcessScanIsEmpty() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = Self.agentHookBinding(launchFlavor: .local)
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )

        #expect(snapshot.panels.first?.terminal?.resumeBinding == binding)
        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)
    }

    @Test
    func snapshotPreservesPersistentSSHAgentHookBindingWhenLocalScanIsEmpty() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let remoteContext = SurfaceResumeRemoteContext(
            workspaceID: workspace.id,
            surfaceID: panelId,
            persistentPTYSessionID: "remote-pty-1"
        )
        let binding = Self.agentHookBinding(launchFlavor: .persistentSSH(remoteContext))
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )

        #expect(snapshot.panels.first?.terminal?.resumeBinding == binding)
        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)
    }
}
