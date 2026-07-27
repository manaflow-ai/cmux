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
        launchFlavor: SurfaceResumeLaunchFlavor = .local,
        autoResume: Bool? = nil
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            command: "claude --resume session-1",
            kind: "claude",
            checkpointId: "session-1",
            source: "agent-hook",
            autoResume: autoResume,
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
    func bindingOnlyPromptIdleKeepsDurableAgentHookBindingUntilLivenessScanPrunes() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = Self.agentHookBinding(autoResume: true)
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.restoredAgentResumeStatesByPanelId[panelId] = .observedAgentCommandRunning

        workspace.updateBindingOnlyRestoredAgentResumeState(panelId: panelId, shellState: .promptIdle)

        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == nil)
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.checkpointId == "session-1")

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )

        #expect(snapshot.panels.first?.terminal?.resumeBinding == nil)
        #expect(workspace.surfaceResumeBinding(panelId: panelId) == nil)
    }

    @Test
    func localAgentHookBindingLivenessRequiresSameSurfaceAndCheckpoint() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = Self.agentHookBinding(autoResume: true)

        let matchingIndex = try Self.indexWithDetectedSession(
            workspaceId: workspace.id,
            panelId: panelId,
            sessionId: "session-1"
        )
        #expect(workspace.isStaleAgentHookBinding(
            binding,
            panelId: panelId,
            restorableAgentIndex: matchingIndex
        ) == false)

        let neighborIndex = try Self.indexWithDetectedSession(
            workspaceId: workspace.id,
            panelId: UUID(),
            sessionId: "session-1"
        )
        #expect(workspace.isStaleAgentHookBinding(
            binding,
            panelId: panelId,
            restorableAgentIndex: neighborIndex
        ) == true)

        let mismatchedCheckpointIndex = try Self.indexWithDetectedSession(
            workspaceId: workspace.id,
            panelId: panelId,
            sessionId: "session-2"
        )
        #expect(workspace.isStaleAgentHookBinding(
            binding,
            panelId: panelId,
            restorableAgentIndex: mismatchedCheckpointIndex
        ) == true)
    }

    private static func indexWithDetectedSession(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String
    ) throws -> RestorableAgentSessionIndex {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-liveness-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        return RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId): (
                    snapshot: SessionRestorableAgentSnapshot(kind: .claude, sessionId: sessionId),
                    updatedAt: 1_777_777_777,
                    processIDs: [424_242],
                    agentProcessIDs: [424_242],
                    sessionIDSource: .explicit
                ),
            ],
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { _ in nil }
        )
    }
}
