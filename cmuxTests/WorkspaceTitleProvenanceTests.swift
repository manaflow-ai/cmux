import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for custom-title provenance: auto-naming writes must never
/// overwrite user-set titles, clearing must reset provenance, and provenance
/// must round-trip through session snapshots (with legacy snapshots that
/// predate provenance decoding as user-owned).
@MainActor
@Suite struct WorkspaceTitleProvenanceTests {

    // MARK: - Workspace titles

    @Test func autoWriteOnUntitledWorkspaceLands() {
        let workspace = Workspace(title: "Terminal")
        let applied = workspace.setCustomTitle("Fix auth bug", source: .auto)
        #expect(applied)
        #expect(workspace.title == "Fix auth bug")
        #expect(workspace.customTitle == "Fix auth bug")
        #expect(workspace.effectiveCustomTitleSource == .auto)
    }

    @Test func autoWriteOverUserTitleIsRejected() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("My Project")
        let applied = workspace.setCustomTitle("Fix auth bug", source: .auto)
        #expect(!applied)
        #expect(workspace.title == "My Project")
        #expect(workspace.effectiveCustomTitleSource == .user)
    }

    @Test func userWriteOverAutoTitleLandsAndClaimsOwnership() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)
        let applied = workspace.setCustomTitle("Release prep")
        #expect(applied)
        #expect(workspace.title == "Release prep")
        #expect(workspace.effectiveCustomTitleSource == .user)
        // The workspace is now user-owned: further auto writes must be rejected.
        #expect(!workspace.setCustomTitle("Something else", source: .auto))
    }

    @Test func autoWriteCanRefreshAutoTitle() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)
        let applied = workspace.setCustomTitle("Debug login flow", source: .auto)
        #expect(applied)
        #expect(workspace.title == "Debug login flow")
        #expect(workspace.effectiveCustomTitleSource == .auto)
    }

    @Test func autoWriteNeverClears() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)
        #expect(!workspace.setCustomTitle(nil, source: .auto))
        #expect(!workspace.setCustomTitle("   ", source: .auto))
        #expect(workspace.title == "Fix auth bug")
    }

    @Test func clearingUserTitleRevertsToProcessTitleAndAllowsAutoWrite() {
        let workspace = Workspace(title: "Terminal")
        workspace.applyProcessTitle("zsh")
        workspace.setCustomTitle("My Project")
        workspace.setCustomTitle(nil)
        #expect(workspace.title == "zsh")
        #expect(workspace.customTitle == nil)
        #expect(workspace.effectiveCustomTitleSource == nil)
        #expect(workspace.setCustomTitle("Fix auth bug", source: .auto))
        #expect(workspace.effectiveCustomTitleSource == .auto)
    }

    @Test func carriedTitleWithoutProvenanceIsTreatedAsUserOwned() {
        let workspace = Workspace(title: "Terminal")
        // Simulate a custom title that arrived without provenance (legacy
        // restore, carried panel move): direct assignment bypasses the setter.
        workspace.customTitle = "Carried Title"
        #expect(workspace.effectiveCustomTitleSource == .user)
        #expect(!workspace.setCustomTitle("Fix auth bug", source: .auto))
        #expect(workspace.customTitle == "Carried Title")
    }

    // MARK: - Panel titles

    @Test func panelProvenanceMirrorsWorkspaceRules() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Fix auth bug", source: .auto))
        #expect(workspace.panelCustomTitles[panelId] == "Fix auth bug")
        #expect(workspace.panelCustomTitleSources[panelId] == .auto)

        // User rename wins and claims ownership.
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Build Pane"))
        #expect(workspace.panelCustomTitleSources[panelId] == .user)
        #expect(!workspace.setPanelCustomTitle(panelId: panelId, title: "Other", source: .auto))
        #expect(workspace.panelCustomTitles[panelId] == "Build Pane")

        // Clearing resets provenance and re-opens the panel to auto naming.
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: nil))
        #expect(workspace.panelCustomTitles[panelId] == nil)
        #expect(workspace.panelCustomTitleSources[panelId] == nil)
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Refreshed", source: .auto))
        #expect(workspace.panelCustomTitleSources[panelId] == .auto)
    }

    @Test func panelAutoWriteRejectedForCarriedTitleWithoutProvenance() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        // Simulate a carried title (move/respawn flows write the dictionary
        // directly when no provenance traveled with the title).
        workspace.panelCustomTitles[panelId] = "Carried Tab"
        #expect(!workspace.setPanelCustomTitle(panelId: panelId, title: "Other", source: .auto))
        #expect(workspace.panelCustomTitles[panelId] == "Carried Tab")
    }

    // MARK: - Snapshot round-trip

    @Test func workspaceSnapshotRoundTripPreservesProvenance() throws {
        var snapshot = SessionWorkspaceSnapshot(
            processTitle: "zsh",
            customTitle: "Fix auth bug",
            customTitleSource: .auto,
            customDescription: nil,
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
        #expect(decoded.customTitleSource == .auto)

        // Legacy shape: encoding a nil source omits the key, which is exactly
        // what snapshots persisted before provenance look like on disk.
        snapshot.customTitleSource = nil
        let legacyDecoded = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(legacyDecoded.customTitleSource == nil)

        // Restore semantics: absent provenance restores as user-owned.
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle(legacyDecoded.customTitle, source: legacyDecoded.customTitleSource ?? .user)
        #expect(workspace.effectiveCustomTitleSource == .user)
    }
}
