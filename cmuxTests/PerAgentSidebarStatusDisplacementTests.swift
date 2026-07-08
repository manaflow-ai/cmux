import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Bare shared PID key displacement and same-pane agent replacement: a
/// claude-style hook reports ONE bare key per agent type per workspace, so
/// ownership moves between panes; displaced panes must keep their own rows,
/// workspace-scoped clears must reap synthesized displacement keys, and a
/// different agent replacing a no-pid panel-scoped status must drop it.
@MainActor
struct PerAgentSidebarStatusDisplacementTests {
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
    func testDisplacedBareKeyPaneKeepsRowWithItsOwnPid() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        // Pane A reports first with the bare shared key (real claude hook shape).
        workspace.recordAgentPID(key: "claude_code", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.setAgentLifecycle(key: "claude_code", panelId: firstPanelId, lifecycle: .running)
        // Pane B's report displaces A's bare-key ownership.
        workspace.recordAgentPID(key: "claude_code", pid: 222, panelId: secondPanelId, refreshPorts: false)

        let rows = workspace.sidebarAgentStatusRows()
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.panelId)) == [firstPanelId, secondPanelId])
        // A's runtime moved to a synthesized key with its own pid intact, so
        // the liveness sweep still owns its cleanup.
        let synthesizedKey = Workspace.synthesizedDisplacedPIDKey(statusKey: "claude_code", panelId: firstPanelId)
        #expect(workspace.agentPIDs[synthesizedKey] == 111)
        #expect(workspace.agentPIDs["claude_code"] == 222)
        #expect(workspace.agentLifecycleStatesByPanelId[firstPanelId]?["claude_code"] == .running)

        // A reports again: the bare key returns to A, the synthesized key is
        // reaped, and A's panel-scoped entry survives the key-shape change.
        workspace.recordPanelStatusEntry(makeEntry(key: "claude_code", value: "Running"), panelId: firstPanelId)
        workspace.recordAgentPID(key: "claude_code", pid: 111, panelId: firstPanelId, refreshPorts: false)
        #expect(workspace.agentPIDs[synthesizedKey] == nil)
        #expect(workspace.statusEntriesByPanelId[firstPanelId]?["claude_code"]?.value == "Running")
        // The key-shape change is the SAME runtime re-keying, not an exit:
        // the pane's lifecycle must survive too, or the state dot and summary
        // counts go blank until the next lifecycle hook.
        #expect(workspace.agentLifecycleStatesByPanelId[firstPanelId]?["claude_code"] == .running)
        #expect(workspace.sidebarAgentStatusRows().count == 2)
    }

    @Test
    func testWorkspaceScopedStatusClearReapsDisplacedRuntimes() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "claude_code", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.setAgentLifecycle(key: "claude_code", panelId: firstPanelId, lifecycle: .running)
        workspace.recordAgentPID(key: "claude_code", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.setAgentLifecycle(key: "claude_code", panelId: secondPanelId, lifecycle: .running)
        #expect(workspace.sidebarAgentStatusRows().count == 2)

        // The `clear_status <key>` contract: remove the key from the WHOLE
        // workspace. The displaced pane's synthesized runtime and both panes'
        // lifecycles must go too, or its row reappears with lifecycle text.
        _ = workspace.statusEntries.removeValue(forKey: "claude_code")
        _ = workspace.clearPanelStatusEntries(statusKey: "claude_code")
        workspace.clearAgentRuntimes(forStatusKey: "claude_code", refreshPorts: false)

        #expect(workspace.sidebarAgentStatusRows().isEmpty)
        let synthesizedKey = Workspace.synthesizedDisplacedPIDKey(statusKey: "claude_code", panelId: firstPanelId)
        #expect(workspace.agentPIDs[synthesizedKey] == nil)
        #expect(workspace.agentPIDs["claude_code"] == nil)
        #expect(workspace.agentPIDPanelIdsByKey.isEmpty)
        #expect(workspace.agentPIDKeysByPanelId.isEmpty)
        #expect(workspace.agentLifecycleStatesByPanelId[firstPanelId]?["claude_code"] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[secondPanelId]?["claude_code"] == nil)
    }

    @Test
    func testDifferentAgentReplacesNoPIDPanelScopedStatus() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        // codex reported only a panel-scoped status (set_status --panel with
        // no --pid) plus a lifecycle; it never recorded a pid on the pane.
        workspace.statusEntries["codex"] = makeEntry(key: "codex", value: "Old codex text")
        workspace.recordPanelStatusEntry(makeEntry(key: "codex", value: "Old codex text"), panelId: panelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)

        // claude replaces it on the same pane: the stale codex entry,
        // lifecycle, and orphaned workspace-level slot must all go, or the
        // pane's row keeps showing the dead agent's text (a nil claude entry
        // loses to any codex entry in the row chooser).
        workspace.recordAgentPID(key: "claude_code", pid: 111, panelId: panelId, refreshPorts: false)

        let rows = workspace.sidebarAgentStatusRows()
        #expect(rows.map(\.statusKey) == ["claude_code"])
        #expect(workspace.statusEntriesByPanelId[panelId]?["codex"] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == nil)
        #expect(workspace.statusEntries["codex"] == nil)
    }
}
