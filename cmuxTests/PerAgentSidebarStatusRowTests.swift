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
        XCTAssertEqual(byPanel[firstPanelId]?.lifecycle, .running)
        XCTAssertEqual(byPanel[secondPanelId]?.lifecycle, .needsInput)
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
