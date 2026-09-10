import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// At relaunch the live-agent index is loaded off-main, so every agent restore
/// is deferred until it settles. On a Mac running several agents the hook
/// stores never stop changing, the settled refresh gives up, and the deferred
/// restores used to be cancelled into plain shells with retired bindings, which
/// is the "resumes once, never again" report in
/// https://github.com/manaflow-ai/cmux/issues/5473.
@MainActor
@Suite("Deferred agent resume without a settled index")
struct DeferredAgentResumeIndexFallbackTests {
    private func agentHookBinding(checkpoint: String) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Antigravity",
            kind: "antigravity",
            command: "cd -- '/tmp' 2>/dev/null || [ ! -d '/tmp' ] && 'agy' '--conversation' '\(checkpoint)'",
            cwd: "/tmp",
            checkpointId: checkpoint,
            source: "agent-hook",
            environment: nil,
            launchCommand: nil,
            permissionMode: nil,
            autoResume: true,
            resumeEvidenceProvenance: nil,
            updatedAt: 1_788_868_000
        )
    }

    @Test("A refresh that could not settle resolves against the most recent completed load")
    func unsettledRefreshFallsBackToLastKnownIndex() {
        let lastKnown = RestorableAgentSessionIndex.empty
        #expect(Workspace.deferredResumeIndex(refreshed: nil, lastKnown: lastKnown) != nil)
        #expect(Workspace.deferredResumeIndex(refreshed: nil, lastKnown: nil) == nil)
        let refreshed = RestorableAgentSessionIndex.empty
        #expect(Workspace.deferredResumeIndex(refreshed: refreshed, lastKnown: nil) != nil)
    }

    @Test("Cancelling for index unavailability keeps the binding auto-resumable")
    func indexUnavailabilityDoesNotRetireBindings() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = agentHookBinding(checkpoint: "6e8458c7-7970-41e0-8d3e-00beda48097b")
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.deferredAgentResumeRestoresByPanelId[panelId] = DeferredAgentResumeRestore(
            stablePanelID: panelId,
            restorableAgent: nil,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: false,
            workingDirectory: "/tmp",
            resumeWorkingDirectory: "/tmp"
        )

        workspace.clearDeferredAgentResumeRestores(retireBindings: false)

        #expect(workspace.deferredAgentResumeRestoresByPanelId[panelId] == nil)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .manualResumeAvailable)
        // The next relaunch may still auto-resume this session.
        #expect(workspace.surfaceResumeBindingsByPanelId[panelId]?.autoResume == true)
    }

    @Test("An index that has not caught up with a fresh hook record does not make its binding stale")
    func missingIndexEntryIsUnknownNotStale() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = agentHookBinding(checkpoint: "fbce5061-b13a-4c00-8000-000000000002")
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))

        // The scan finished before the hook wrote this session: no entry at all.
        #expect(
            !workspace.isStaleAgentHookBinding(
                binding,
                panelId: panelId,
                restorableAgentIndex: .empty
            )
        )
    }

    @Test("An index entry for the session with no live process still marks the binding stale")
    func exitedIndexEntryIsStale() throws {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-stale-binding-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = homeDirectory.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: homeDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let sessionId = "9836696c-cf40-4d00-8000-000000000003"
        let binding = agentHookBinding(checkpoint: sessionId)
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))

        // A hook record for this session that never carried a live PID.
        let store = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    sessionId: [
                        "sessionId": sessionId,
                        "workspaceId": workspace.id.uuidString,
                        "surfaceId": panelId.uuidString,
                        "cwd": "/tmp",
                        "launchCommand": [
                            "launcher": "antigravity",
                            "executablePath": "agy",
                            "arguments": ["agy", "--dangerously-skip-permissions"],
                            "workingDirectory": "/tmp",
                            "source": "agent-hook",
                        ],
                        "isRestorable": true,
                        "updatedAt": 1_788_868_000.0,
                    ],
                ],
            ],
            options: .sortedKeys
        )
        try store.write(
            to: stateDirectory.appendingPathComponent("antigravity-hook-sessions.json"),
            options: .atomic
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry.load(
                homeDirectory: homeDirectory.path,
                fileManager: fileManager
            ),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil }
        )
        #expect(index.entryForStablePanel(workspaceId: workspace.id, panelId: panelId) != nil)

        #expect(
            workspace.isStaleAgentHookBinding(
                binding,
                panelId: panelId,
                restorableAgentIndex: index
            )
        )
    }

    @Test("A positive ownership decision still retires the binding")
    func ownershipCancelRetiresBinding() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = agentHookBinding(checkpoint: "312c5284-0000-4000-8000-000000000001")
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.deferredAgentResumeRestoresByPanelId[panelId] = DeferredAgentResumeRestore(
            stablePanelID: panelId,
            restorableAgent: nil,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: false,
            workingDirectory: "/tmp",
            resumeWorkingDirectory: "/tmp"
        )

        workspace.clearDeferredAgentResumeRestores()

        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .manualResumeAvailable)
        #expect(workspace.surfaceResumeBindingsByPanelId[panelId]?.autoResume == false)
    }
}
