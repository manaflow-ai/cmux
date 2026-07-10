import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Continuation of `PerAgentSidebarStatusRowTests`, split to satisfy the
/// new-file length budget: bare-key exit-hook clears, dead-agent replacement,
/// and the rows summary accent.
@MainActor
struct PerAgentSidebarStatusRowClearingTests {
    private func makeEntry(
        key: String,
        value: String,
        timestamp: Date = Date()
    ) -> SidebarStatusEntry {
        SidebarStatusEntry(
            key: key,
            value: value,
            icon: "bolt.fill",
            color: "#4C8DFF",
            timestamp: timestamp
        )
    }

    @Test
    func testBareKeyExitHookFromNonOwnerPaneClearsOnlyThatPanesRow() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        // Real bare-key hook sequence: both panes report the shared
        // `claude_code` key, ownership migrates to the last reporter.
        workspace.recordAgentPID(key: "claude_code", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: firstPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: firstPanelId, lifecycle: .running)

        workspace.recordAgentPID(key: "claude_code", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Waiting"), panelId: secondPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: secondPanelId, lifecycle: .needsInput)

        // Pane A exits: its hook sends `clear_agent_pid claude_code --panel=A
        // --clear-status` although pane B now owns the key. The clear must
        // drop A's own row state without touching B's runtime.
        #expect(workspace.clearAgentPID(key: "claude_code", panelId: firstPanelId, clearStatus: true, refreshPorts: false))

        let rows = workspace.sidebarAgentStatusRows()
        #expect(rows.map(\.panelId) == [secondPanelId])
        #expect(workspace.statusEntriesByPanelId[firstPanelId]?["claude_code"] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[firstPanelId]?["claude_code"] == nil)
        #expect(workspace.agentPIDs["claude_code"] == 222)
        #expect(workspace.agentPIDPanelIdsByKey["claude_code"] == secondPanelId)
        #expect(workspace.statusEntriesByPanelId[secondPanelId]?["claude_code"]?.value == "Waiting")
    }

    @Test
    func testClosingPanelWithoutPIDClearsSoleOwnerWorkspaceStatus() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        // `set_status --panel` without `--pid`: the workspace slot and the
        // panel copy are both written, but there is no PID ownership for the
        // runtime cleanup to sweep.
        let entry = makeEntry(key: "claude_code", value: "Running")
        workspace.recordPanelStatusEntry(entry, panelId: secondPanelId)
        workspace.statusEntries["claude_code"] = entry

        _ = workspace.discardClosedPanelLifecycleState(
            panelId: secondPanelId,
            paneId: nil,
            panel: workspace.panels[secondPanelId],
            origin: "test",
            closePanel: false,
            publishSurfaceClosedEvent: false,
            clearSurfaceNotifications: false,
            requestTransferredRemoteCleanup: false
        )

        // The closed pane was the key's only plausible owner, so the stale
        // workspace-level slot must not survive to be adopted by a future
        // same-type agent pane through the sole-owner fallback.
        #expect(workspace.statusEntries["claude_code"] == nil)
    }

    @Test
    func testClosingPanelKeepsWorkspaceStatusWhenAnotherPaneOwnsKey() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        let entry = makeEntry(key: "claude_code", value: "Running")
        workspace.recordPanelStatusEntry(entry, panelId: firstPanelId)
        workspace.recordPanelStatusEntry(entry, panelId: secondPanelId)
        workspace.statusEntries["claude_code"] = entry

        _ = workspace.discardClosedPanelLifecycleState(
            panelId: secondPanelId,
            paneId: nil,
            panel: workspace.panels[secondPanelId],
            origin: "test",
            closePanel: false,
            publishSurfaceClosedEvent: false,
            clearSurfaceNotifications: false,
            requestTransferredRemoteCleanup: false
        )

        // The first pane still owns the key, so the workspace-level slot
        // stays for its sole-owner fallback.
        #expect(workspace.statusEntries["claude_code"]?.value == "Running")
        #expect(workspace.statusEntriesByPanelId[firstPanelId]?["claude_code"]?.value == "Running")
    }

    @Test
    func testAmbiguousSharedKeyRowDoesNotInheritWorkspaceSortFreshness() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "claude_code.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        // Only the second pane has a panel-scoped entry; the workspace slot
        // is newer and high-priority but ambiguous between the two panes.
        workspace.recordPanelStatusEntry(
            makeEntry(key: "claude_code", value: "Idle", timestamp: Date(timeIntervalSince1970: 100)),
            panelId: secondPanelId
        )
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            priority: 500,
            timestamp: Date(timeIntervalSince1970: 9_999)
        )

        let rows = workspace.sidebarAgentStatusRows()
        let rowsByPanel = Dictionary(uniqueKeysWithValues: rows.map { ($0.panelId, $0) })
        // The pane without its own entry must not borrow the ambiguous
        // workspace entry's freshness for sorting.
        #expect(rowsByPanel[firstPanelId]?.priority == 0)
        #expect(rowsByPanel[firstPanelId]?.timestamp == .distantPast)
        #expect(rows.first?.panelId == secondPanelId)
    }

    @Test
    func testAccordionSummaryCounts() {
        func row(lifecycle: AgentHibernationLifecycleState?) -> SidebarAgentStatusRow {
            SidebarAgentStatusRow(
                panelId: UUID(),
                statusKey: "claude_code",
                value: nil,
                icon: nil,
                color: nil,
                url: nil,
                format: .plain,
                lifecycle: lifecycle,
                paneLabel: nil,
                priority: 0,
                timestamp: Date(timeIntervalSince1970: 0)
            )
        }

        let summary = SidebarAgentStatusRowsSummary(rows: [
            row(lifecycle: .running),
            row(lifecycle: .needsInput),
            row(lifecycle: .idle),
        ])
        #expect(summary.agentCount == 3)
        #expect(summary.needsInputCount == 1)
        #expect(summary.runningCount == 1)
        #expect(summary.accentColorHex == "#FF9F0A")

        let runningOnly = SidebarAgentStatusRowsSummary(rows: [row(lifecycle: .running)])
        #expect(runningOnly.accentColorHex == "#4C8DFF")
        #expect(SidebarAgentStatusRowsSummary(rows: [row(lifecycle: .idle)]).accentColorHex == nil)
    }
}
