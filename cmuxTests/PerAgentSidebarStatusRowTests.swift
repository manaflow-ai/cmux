import CmuxSidebar
import XCTest

@testable import cmux

/// Per-pane agent status rows (sidebar): several agents in one workspace must
/// each keep their own row instead of collapsing into one last-write-wins
/// status pill per agent type.
final class PerAgentSidebarStatusRowTests: XCTestCase {
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

    @MainActor
    func testIdenticalPanelStatusReportDoesNotReplaceStoredEntry() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        let first = makeEntry(key: "claude_code", value: "Running", timestamp: Date(timeIntervalSince1970: 100))
        workspace.recordPanelStatusEntry(first, panelId: panelId)
        let repeated = makeEntry(key: "claude_code", value: "Running", timestamp: Date(timeIntervalSince1970: 200))
        workspace.recordPanelStatusEntry(repeated, panelId: panelId)
        // Same display content, newer timestamp: dropped so agent heartbeats
        // do not invalidate the sidebar snapshot.
        XCTAssertEqual(workspace.statusEntriesByPanelId[panelId]?["claude_code"], first)

        let changed = makeEntry(key: "claude_code", value: "Idle", timestamp: Date(timeIntervalSince1970: 300))
        workspace.recordPanelStatusEntry(changed, panelId: panelId)
        XCTAssertEqual(workspace.statusEntriesByPanelId[panelId]?["claude_code"], changed)
    }

    @MainActor
    func testAmbiguousWorkspaceStatusIsNotAttributedDuringTransfer() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "claude_code.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        // Only the workspace-level last-write-wins slot has text; either pane
        // could have written it, so it must not ride along with a transfer.
        workspace.statusEntries["claude_code"] = makeEntry(key: "claude_code", value: "Running")

        let runtimeState = try XCTUnwrap(workspace.agentRuntimeState(forPanelId: secondPanelId))
        XCTAssertNil(runtimeState.statusEntries["claude_code"])
    }

    @MainActor
    func testTwoAgentsOfSameTypeKeepSeparateRows() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

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
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.panelId)), [firstPanelId, secondPanelId])
        let valuesByPanel = Dictionary(uniqueKeysWithValues: rows.map { ($0.panelId, $0.value) })
        XCTAssertEqual(valuesByPanel[firstPanelId], "Running")
        XCTAssertEqual(valuesByPanel[secondPanelId], "Claude is waiting for your input")
    }

    @MainActor
    func testSoleOwnerFallsBackToWorkspaceEntry() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.recordAgentPID(key: "claude_code.only", pid: 111, panelId: panelId, refreshPorts: false)
        workspace.statusEntries["claude_code"] = makeEntry(key: "claude_code", value: "Running")

        let rows = workspace.sidebarAgentStatusRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.panelId, panelId)
        XCTAssertEqual(rows.first?.value, "Running")
    }

    @MainActor
    func testSharedKeyWithoutPanelEntriesUsesPerPanelLifecycleNotWorkspaceText() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "claude_code.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.setAgentLifecycle(key: "claude_code", panelId: firstPanelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "claude_code", panelId: secondPanelId, lifecycle: .needsInput)
        workspace.statusEntries["claude_code"] = makeEntry(key: "claude_code", value: "Running")

        let rows = workspace.sidebarAgentStatusRows()
        XCTAssertEqual(rows.count, 2)
        let byPanel = Dictionary(uniqueKeysWithValues: rows.map { ($0.panelId, $0) })
        // The ambiguous workspace-level text must not be attributed to either pane.
        XCTAssertNil(byPanel[firstPanelId]?.value)
        XCTAssertNil(byPanel[secondPanelId]?.value)
        // Nor its decorations: the last writer's icon/color must not bleed
        // onto the other pane's row.
        XCTAssertNil(byPanel[firstPanelId]?.icon)
        XCTAssertNil(byPanel[secondPanelId]?.icon)
        XCTAssertNil(byPanel[firstPanelId]?.color)
        XCTAssertNil(byPanel[secondPanelId]?.color)
        XCTAssertEqual(byPanel[firstPanelId]?.lifecycle, .running)
        XCTAssertEqual(byPanel[secondPanelId]?.lifecycle, .needsInput)
    }

    @MainActor
    func testPanelEntryWithoutAgentPIDDoesNotCreateRow() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        // A bare panel-scoped text report with no recorded agent PID has no
        // deterministic owner to clear it, so it must not create a row.
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: panelId)
        XCTAssertTrue(workspace.sidebarAgentStatusRows().isEmpty)

        // Recording the PID makes the same entry visible; clearing the PID
        // without clearing status removes the row again (no stale rows).
        workspace.recordAgentPID(key: "claude_code.owner", pid: 111, panelId: panelId, refreshPorts: false)
        XCTAssertEqual(workspace.sidebarAgentStatusRows().map(\.panelId), [panelId])
        XCTAssertTrue(
            workspace.clearAgentPID(key: "claude_code.owner", panelId: panelId, clearStatus: false, refreshPorts: false)
        )
        XCTAssertTrue(workspace.sidebarAgentStatusRows().isEmpty)
    }

    @MainActor
    func testAgentReplacementOnSamePanelKeepsFreshPanelEntry() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.recordAgentPID(key: "claude_code.old", pid: 111, panelId: panelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Old session"), panelId: panelId)

        // A new session replacing the agent on the same panel: PID recording
        // runs first (evicting the stale runtime, which clears its panel
        // entry), then the new report's panel-scoped write. This is the upsert
        // order the control-socket path uses; writing the panel copy first
        // would let the eviction delete the fresh entry.
        workspace.recordAgentPID(key: "claude_code.new", pid: 222, panelId: panelId, refreshPorts: false)
        XCTAssertNil(workspace.statusEntriesByPanelId[panelId]?["claude_code"])
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "New session"), panelId: panelId)

        XCTAssertEqual(workspace.statusEntriesByPanelId[panelId]?["claude_code"]?.value, "New session")
        XCTAssertEqual(workspace.sidebarAgentStatusRows().first?.value, "New session")
    }

    @MainActor
    func testClearingAgentPIDRemovesThatPanelsRow() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "claude_code.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: firstPanelId)
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Idle"), panelId: secondPanelId)

        XCTAssertTrue(
            workspace.clearAgentPID(key: "claude_code.first", panelId: firstPanelId, clearStatus: true, refreshPorts: false)
        )

        let rows = workspace.sidebarAgentStatusRows()
        XCTAssertEqual(rows.map(\.panelId), [secondPanelId])
        XCTAssertNil(workspace.statusEntriesByPanelId[firstPanelId]?["claude_code"])
        XCTAssertEqual(workspace.statusEntriesByPanelId[secondPanelId]?["claude_code"]?.value, "Idle")
    }

    @MainActor
    func testDetachedRuntimeTransferCarriesPanelScopedEntry() throws {
        let source = Workspace()
        let panelId = try XCTUnwrap(source.focusedPanelId)
        source.recordAgentPID(key: "claude_code.moved", pid: 111, panelId: panelId, refreshPorts: false)
        source.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: panelId)

        let runtimeState = try XCTUnwrap(source.agentRuntimeState(forPanelId: panelId))
        XCTAssertEqual(runtimeState.statusEntries["claude_code"]?.value, "Running")

        let destination = Workspace()
        destination.adoptDetachedAgentRuntimeState(runtimeState)
        XCTAssertEqual(destination.statusEntriesByPanelId[panelId]?["claude_code"]?.value, "Running")
        XCTAssertEqual(destination.statusEntries["claude_code"]?.value, "Running")
    }

    @MainActor
    func testClosingPanelDropsPanelScopedEntries() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false)).id
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

        XCTAssertNil(workspace.statusEntriesByPanelId[secondPanelId])
        XCTAssertTrue(workspace.sidebarAgentStatusRows().isEmpty)
    }
}
