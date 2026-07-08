import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Per-pane agent status rows (sidebar): several agents in one workspace must
/// each keep their own row instead of collapsing into one last-write-wins
/// status pill per agent type.
@MainActor
struct PerAgentSidebarStatusRowTests {
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
    func testIdenticalPanelStatusReportDoesNotReplaceStoredEntry() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        let first = makeEntry(key: "claude_code", value: "Running", timestamp: Date(timeIntervalSince1970: 100))
        workspace.recordPanelStatusEntry(first, panelId: panelId)
        let repeated = makeEntry(key: "claude_code", value: "Running", timestamp: Date(timeIntervalSince1970: 200))
        workspace.recordPanelStatusEntry(repeated, panelId: panelId)
        // Same display content, newer timestamp: dropped so agent heartbeats
        // do not invalidate the sidebar snapshot.
        #expect(workspace.statusEntriesByPanelId[panelId]?["claude_code"] == first)

        let changed = makeEntry(key: "claude_code", value: "Idle", timestamp: Date(timeIntervalSince1970: 300))
        workspace.recordPanelStatusEntry(changed, panelId: panelId)
        #expect(workspace.statusEntriesByPanelId[panelId]?["claude_code"] == changed)
    }

    @Test
    func testAmbiguousWorkspaceStatusIsNotAttributedDuringTransfer() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "claude_code.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        // Only the workspace-level last-write-wins slot has text; either pane
        // could have written it, so it must not ride along with a transfer.
        workspace.statusEntries["claude_code"] = makeEntry(key: "claude_code", value: "Running")

        let runtimeState = try #require(workspace.agentRuntimeState(forPanelId: secondPanelId))
        #expect(runtimeState.statusEntries["claude_code"] == nil)
    }

    @Test
    func testTwoAgentsOfSameTypeKeepSeparateRows() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "claude_code.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: firstPanelId)
        workspace.recordPanelStatusEntry(
            makeEntry(key: "claude_code", value: "Claude is waiting for your input"),
            panelId: secondPanelId
        )
        // Workspace-level slot only kept the most recent write.
        workspace.statusEntries["claude_code"] = makeEntry(
            key: "claude_code",
            value: "Claude is waiting for your input"
        )

        let rows = workspace.sidebarAgentStatusRows()
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.panelId)) == [firstPanelId, secondPanelId])
        let valuesByPanel = Dictionary(uniqueKeysWithValues: rows.map { ($0.panelId, $0.value) })
        #expect(valuesByPanel[firstPanelId] == "Running")
        #expect(valuesByPanel[secondPanelId] == "Claude is waiting for your input")
    }

    @Test
    func testSoleOwnerFallsBackToWorkspaceEntry() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.recordAgentPID(key: "claude_code.only", pid: 111, panelId: panelId, refreshPorts: false)
        workspace.statusEntries["claude_code"] = makeEntry(key: "claude_code", value: "Running")

        let rows = workspace.sidebarAgentStatusRows()
        #expect(rows.count == 1)
        #expect(rows.first?.panelId == panelId)
        #expect(rows.first?.value == "Running")
    }

    @Test
    func testSharedKeyWithoutPanelEntriesUsesPerPanelLifecycleNotWorkspaceText() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "claude_code.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.setAgentLifecycle(key: "claude_code", panelId: firstPanelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "claude_code", panelId: secondPanelId, lifecycle: .needsInput)
        workspace.statusEntries["claude_code"] = makeEntry(key: "claude_code", value: "Running")

        let rows = workspace.sidebarAgentStatusRows()
        #expect(rows.count == 2)
        let byPanel = Dictionary(uniqueKeysWithValues: rows.map { ($0.panelId, $0) })
        // The ambiguous workspace-level text must not be attributed to either pane.
        #expect(byPanel[firstPanelId]?.value == nil)
        #expect(byPanel[secondPanelId]?.value == nil)
        // Nor its decorations: the last writer's icon/color must not bleed
        // onto the other pane's row.
        #expect(byPanel[firstPanelId]?.icon == nil)
        #expect(byPanel[secondPanelId]?.icon == nil)
        #expect(byPanel[firstPanelId]?.color == nil)
        #expect(byPanel[secondPanelId]?.color == nil)
        #expect(byPanel[firstPanelId]?.lifecycle == .running)
        #expect(byPanel[secondPanelId]?.lifecycle == .needsInput)
    }

    @Test
    func testRowCarriesReportedValueFormat() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.recordAgentPID(key: "claude_code", pid: 111, panelId: panelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(
            SidebarStatusEntry(key: "claude_code", value: "**bold** status", format: .markdown),
            panelId: panelId
        )

        // The row must carry the reported value's format so markdown statuses
        // keep their inline rendering after moving out of the metadata rows.
        let row = try #require(workspace.sidebarAgentStatusRows().first)
        #expect(row.value == "**bold** status")
        #expect(row.format == .markdown)
    }

    @Test
    func testBareSharedPIDKeyHookSequenceKeepsBothPanesRows() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        // Mirrors the real Claude Code hook sequence, which shares ONE bare
        // PID key per agent type across all panes of a workspace
        // (`set_agent_pid claude_code <pid> --panel ...` then
        // `set_status claude_code ... --pid --panel ...`). Bare-key ownership
        // migrates to the last reporting pane, so the panel-scoped entry must
        // keep the earlier pane's row alive.
        workspace.recordAgentPID(key: "claude_code", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: firstPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: firstPanelId, lifecycle: .running)

        workspace.recordAgentPID(key: "claude_code", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(
            makeEntry(key: "claude_code", value: "Claude is waiting for your input"),
            panelId: secondPanelId
        )
        workspace.setAgentLifecycle(key: "claude_code", panelId: secondPanelId, lifecycle: .needsInput)

        let rows = workspace.sidebarAgentStatusRows()
        #expect(rows.count == 2)
        let valuesByPanel = Dictionary(uniqueKeysWithValues: rows.map { ($0.panelId, $0.value) })
        #expect(valuesByPanel[firstPanelId] == "Running")
        #expect(valuesByPanel[secondPanelId] == "Claude is waiting for your input")
        let rowsByPanel = Dictionary(uniqueKeysWithValues: rows.map { ($0.panelId, $0) })
        #expect(rowsByPanel[firstPanelId]?.lifecycle == .running)
        #expect(rowsByPanel[secondPanelId]?.lifecycle == .needsInput)
    }

    @Test
    func testAgentReplacementOnSamePanelKeepsFreshPanelEntry() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.recordAgentPID(key: "claude_code.old", pid: 111, panelId: panelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Old session"), panelId: panelId)

        // A new session replacing the agent on the same panel: PID recording
        // runs first (evicting the stale runtime, which clears its panel
        // entry), then the new report's panel-scoped write. This is the upsert
        // order the control-socket path uses; writing the panel copy first
        // would let the eviction delete the fresh entry.
        workspace.recordAgentPID(key: "claude_code.new", pid: 222, panelId: panelId, refreshPorts: false)
        #expect(workspace.statusEntriesByPanelId[panelId]?["claude_code"] == nil)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "New session"), panelId: panelId)

        #expect(workspace.statusEntriesByPanelId[panelId]?["claude_code"]?.value == "New session")
        #expect(workspace.sidebarAgentStatusRows().first?.value == "New session")
    }

    @Test
    func testClearingAgentPIDRemovesThatPanelsRow() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "claude_code.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: firstPanelId)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Idle"), panelId: secondPanelId)

        #expect(
            workspace.clearAgentPID(key: "claude_code.first", panelId: firstPanelId, clearStatus: true, refreshPorts: false)
        )

        let rows = workspace.sidebarAgentStatusRows()
        #expect(rows.map(\.panelId) == [secondPanelId])
        #expect(workspace.statusEntriesByPanelId[firstPanelId]?["claude_code"] == nil)
        #expect(workspace.statusEntriesByPanelId[secondPanelId]?["claude_code"]?.value == "Idle")
    }

    @Test
    func testDetachedRuntimeTransferCarriesPanelScopedEntry() throws {
        let source = Workspace()
        let panelId = try #require(source.focusedPanelId)
        source.recordAgentPID(key: "claude_code.moved", pid: 111, panelId: panelId, refreshPorts: false)
        source.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: panelId)

        let runtimeState = try #require(source.agentRuntimeState(forPanelId: panelId))
        #expect(runtimeState.statusEntries["claude_code"]?.value == "Running")

        let destination = Workspace()
        destination.adoptDetachedAgentRuntimeState(runtimeState)
        #expect(destination.statusEntriesByPanelId[panelId]?["claude_code"]?.value == "Running")
        #expect(destination.statusEntries["claude_code"]?.value == "Running")
    }

    @Test
    func testClosingPanelDropsPanelScopedEntries() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: secondPanelId)

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

        #expect(workspace.statusEntriesByPanelId[secondPanelId] == nil)
        #expect(workspace.sidebarAgentStatusRows().isEmpty)
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
