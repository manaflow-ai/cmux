import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An OSC 7501 program-status report printed in a pane mirrored by `cmux ssh-tmux`
/// reaches the sidebar and `program_status.changed`, as it does in a local pane
/// (https://github.com/manaflow-ai/cmux/issues/22082).
///
/// Ghostty parses the report on the pane's own surface and hands it to
/// `Workspace.applyProgramStatus` with that surface's id. A mirrored pane's surface
/// belongs to its window mirror, not to the workspace's `panels`, so every report
/// from one was dropped. Each mirrored pane now keeps its own records, like a
/// local pane, and the sidebar counts them for the workspace.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorProgramStatusTests {
    @Test func aReportFromAMirroredPaneReachesTheSidebarAndTheEventStream() throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let panes = try harness.surfaces()
        try #require(panes.count == 2, "the harness mirrors one window with two panes: \(panes)")
        let pane = panes[1]
        try #require(harness.workspace.panels[pane.surfaceID] == nil, "a mirrored pane is not a workspace panel")

        // What Ghostty's program-status callback does for a report on that pane.
        harness.workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, app: "cargo", message: "Building"),
            panelId: pane.surfaceID
        )

        let entry = try #require(
            harness.workspace.statusEntries[Workspace.programStatusKey],
            "the sidebar has no program status for the mirrored workspace"
        )
        #expect(entry.value == "cargo · Building")

        CmuxEventBus.shared.flushEventLogForTesting()
        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
                && $0["workspace_id"] as? String == harness.workspace.id.uuidString
        }
        #expect(events.count == 1)
        // The pane's own surface, the id `cmux list-surfaces` shows for it.
        #expect(events.last?["surface_id"] as? String == pane.surfaceID.uuidString)

        // The prompt coming back clears the transient record, as in a local pane.
        harness.workspace.applyProgramStatus(
            ProgramStatusReport(event: .promptStart, state: .idle),
            panelId: pane.surfaceID
        )
        #expect(harness.workspace.statusEntries[Workspace.programStatusKey] == nil)
    }

    /// Two panes of one tmux window keep separate records: the shell prompt
    /// returning in one pane does not clear an agent working in the other.
    @Test func panesInOneWindowKeepTheirOwnStatus() throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }
        let panes = try harness.surfaces()
        try #require(panes.count == 2)
        let workspace = harness.workspace

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, app: "claude", message: "Editing"),
            panelId: panes[0].surfaceID
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, app: "cargo", message: "Building"),
            panelId: panes[1].surfaceID
        )
        workspace.applyProgramStatus(ProgramStatusReport(event: .promptStart, state: .idle), panelId: panes[1].surfaceID)
        #expect(workspace.statusEntries[Workspace.programStatusKey]?.value == "claude · Editing")

        workspace.applyProgramStatus(ProgramStatusReport(state: .clear), panelId: panes[1].surfaceID)
        #expect(workspace.statusEntries[Workspace.programStatusKey]?.value == "claude · Editing")
    }

    /// The sidebar row shows whichever pane most needs the person, mirrored or
    /// not: a mirrored pane waiting for an answer outranks a local pane's build.
    @Test func theSidebarRowWeighsMirroredPanesAgainstLocalOnes() throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }
        let panes = try harness.surfaces()
        let workspace = harness.workspace
        // A workspace panel (here the mirror tab itself) reporting on its own.
        let localPanel = try #require(workspace.panels.keys.first)

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, app: "cargo", message: "Building"),
            panelId: localPanel
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .question, app: "claude", message: "Which branch?"),
            panelId: panes[0].surfaceID
        )
        let shown = workspace.sidebarStatusEntriesVisibleForDisplay()
            .first { $0.key == Workspace.programStatusKey }
        #expect(shown?.value == "claude · Which branch?")
    }

    /// Returning to the mirror tab dismisses its panes' finished records, and a
    /// pane tmux removes takes its records with it.
    @Test func focusAndPaneRemovalEndAMirroredPanesStatus() throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }
        let panes = try harness.surfaces()
        try #require(panes.count == 2)
        let workspace = harness.workspace
        let container = try #require(workspace.remoteTmuxControlPane(surfaceID: panes[0].surfaceID)?.containerPanelID)

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "lint", app: "cargo", message: "Lint clean"),
            panelId: panes[0].surfaceID
        )
        #expect(workspace.statusEntries[Workspace.programStatusKey] != nil)
        workspace.dismissCompletedProgramStatus(panelId: container)
        #expect(workspace.statusEntries[Workspace.programStatusKey] == nil)

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, app: "cargo", message: "Building"),
            panelId: panes[1].surfaceID
        )
        #expect(workspace.statusEntries[Workspace.programStatusKey] != nil)
        TerminalController.remoteTmuxControlSurfaceRemovalHandler(workspaceID: workspace.id)(panes[1].surfaceID)
        #expect(workspace.statusEntries[Workspace.programStatusKey] == nil)
    }

    /// The whole path: tmux sends the report as pane output, the mirror feeds it
    /// to the pane's surface, and Ghostty's parser reports it.
    @Test func aReportPrintedInAMirroredPaneReachesTheSidebar() async throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }
        let message = Data("mirror test".utf8).base64EncodedString()
        let report = Data("\u{1B}]7501;state=working:msg=\(message)\u{1B}\\".utf8)
        harness.connection.handleMessageForTesting(.output(paneId: 5, data: report))

        let deadline = Date().addingTimeInterval(5)
        while harness.workspace.statusEntries[Workspace.programStatusKey] == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let entry = try #require(
            harness.workspace.statusEntries[Workspace.programStatusKey],
            "a report printed in the mirrored pane never reached the sidebar"
        )
        #expect(entry.value.contains("mirror test"), "\(entry.value)")
    }

    /// A surface the workspace does not own in any way is still ignored.
    @Test func aReportFromAnUnknownSurfaceIsStillDropped() throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }
        harness.workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, app: "cargo", message: "Building"),
            panelId: UUID()
        )
        #expect(harness.workspace.statusEntries[Workspace.programStatusKey] == nil)
    }
}
