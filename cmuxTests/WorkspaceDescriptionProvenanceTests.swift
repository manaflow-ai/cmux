import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for custom-description provenance (issue #6753). An agent's
/// `set-description` summary and a human's hand-typed note share the same
/// `customDescription` field; provenance lets a sidebar context reset wipe the
/// stale agent summary while leaving user-authored notes intact. Legacy
/// descriptions that predate provenance decode as user-owned and survive.
@MainActor
@Suite struct WorkspaceDescriptionProvenanceTests {

    // MARK: - Provenance recording

    @Test func setDescriptionRecordsProvenance() {
        let workspace = Workspace(title: "Terminal")

        workspace.setCustomDescription("My hand-typed note")
        #expect(workspace.customDescription == "My hand-typed note")
        #expect(workspace.effectiveCustomDescriptionSource == .user)

        workspace.setCustomDescription("Agent summary text", source: .agent)
        #expect(workspace.customDescription == "Agent summary text")
        #expect(workspace.effectiveCustomDescriptionSource == .agent)
    }

    @Test func clearingDescriptionResetsProvenance() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomDescription("Agent summary text", source: .agent)

        workspace.setCustomDescription(nil)
        #expect(workspace.customDescription == nil)
        #expect(workspace.customDescriptionSource == nil)
        #expect(workspace.effectiveCustomDescriptionSource == nil)

        // An all-whitespace write clears too, and resets provenance.
        workspace.setCustomDescription("Agent summary text", source: .agent)
        workspace.setCustomDescription("   \n  ", source: .agent)
        #expect(workspace.customDescription == nil)
        #expect(workspace.customDescriptionSource == nil)
    }

    @Test func descriptionAssignedDirectlyWithoutSetterIsUserOwned() {
        let workspace = Workspace(title: "Terminal")
        // Simulate a description that arrived without provenance (legacy
        // restore): direct assignment bypasses the setter.
        workspace.customDescription = "Carried note"
        #expect(workspace.effectiveCustomDescriptionSource == .user)
    }

    // MARK: - Sidebar context reset (the issue #6753 regression)

    @Test func resetSidebarContextClearsAgentDescription() {
        let workspace = Workspace(title: "Terminal")
        // An agent wrote the description via `set-description` (CLI / control
        // message). Resetting the workspace's sidebar context — what HQ cleanup
        // and `reset_sidebar` run after resetting a clone to main and closing
        // the agent session — must wipe the stale agent summary.
        workspace.setCustomDescription(
            "Built and launched the current branch in the booted iOS simulator.",
            source: .agent
        )

        workspace.resetSidebarContext(reason: "test")

        #expect(workspace.customDescription == nil)
        #expect(workspace.customDescriptionSource == nil)
    }

    @Test func resetSidebarContextPreservesUserDescription() {
        let workspace = Workspace(title: "Terminal")
        // A human typed this note via Edit Workspace Description. A context
        // reset must NOT nuke it.
        workspace.setCustomDescription("Remember: this clone tracks the release branch.")

        workspace.resetSidebarContext(reason: "test")

        #expect(workspace.customDescription == "Remember: this clone tracks the release branch.")
        #expect(workspace.effectiveCustomDescriptionSource == .user)
    }

    @Test func resetSidebarContextPreservesLegacyDescriptionWithoutProvenance() {
        let workspace = Workspace(title: "Terminal")
        // A description restored from a pre-provenance snapshot has no source;
        // it is treated as user-owned and must survive the reset (we cannot
        // prove an agent wrote it).
        workspace.customDescription = "Legacy description without provenance"

        workspace.resetSidebarContext(reason: "test")

        #expect(workspace.customDescription == "Legacy description without provenance")
    }

    // MARK: - Multi-entrypoint: TabManager / set_description control message

    @Test func agentSetDescriptionViaTabManagerIsClearedOnReset() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        // Mirrors the `set_description` control message path
        // (TerminalController -> TabManager.setCustomDescription(source: .agent)).
        manager.setCustomDescription(tabId: workspace.id, description: "agent summary text", source: .agent)
        #expect(workspace.effectiveCustomDescriptionSource == .agent)

        workspace.resetSidebarContext(reason: "test")
        #expect(workspace.customDescription == nil)
    }

    @Test func userSetDescriptionViaTabManagerSurvivesReset() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        // Mirrors the Edit Workspace Description UI path (defaults to .user).
        manager.setCustomDescription(tabId: workspace.id, description: "human note")
        #expect(workspace.effectiveCustomDescriptionSource == .user)

        workspace.resetSidebarContext(reason: "test")
        #expect(workspace.customDescription == "human note")
    }

    // MARK: - Snapshot round-trip

    @Test func snapshotRoundTripPreservesDescriptionProvenance() throws {
        var snapshot = SessionWorkspaceSnapshot(
            processTitle: "zsh",
            customTitle: nil,
            customTitleSource: nil,
            customDescription: "Agent summary text",
            customDescriptionSource: .agent,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
        let decoded = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded.customDescriptionSource == .agent)

        // Restoring an agent-sourced description carries the provenance, so a
        // later reset still wipes it.
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomDescription(decoded.customDescription, source: decoded.customDescriptionSource ?? .user)
        #expect(workspace.effectiveCustomDescriptionSource == .agent)
        workspace.resetSidebarContext(reason: "test")
        #expect(workspace.customDescription == nil)

        // Legacy shape: encoding a nil source omits the key, which is exactly
        // what snapshots persisted before provenance look like on disk.
        snapshot.customDescriptionSource = nil
        let legacyDecoded = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(legacyDecoded.customDescriptionSource == nil)

        // Restore semantics: absent provenance restores as user-owned and
        // survives a reset.
        let legacyWorkspace = Workspace(title: "Terminal")
        legacyWorkspace.setCustomDescription(
            legacyDecoded.customDescription,
            source: legacyDecoded.customDescriptionSource ?? .user
        )
        #expect(legacyWorkspace.effectiveCustomDescriptionSource == .user)
        legacyWorkspace.resetSidebarContext(reason: "test")
        #expect(legacyWorkspace.customDescription == "Agent summary text")
    }
}
