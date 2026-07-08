import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Session persistence for per-pane agent status rows: panel-scoped entries
/// and lifecycles must survive relaunch bound to the restored pane, and any
/// panel-scoped change must dirty the session autosave fingerprint.
@MainActor
struct PerAgentSidebarStatusPersistenceTests {
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
    func testRestoredPanelSnapshotSeedsRowWithPaneBinding() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        let terminal = SessionTerminalPanelSnapshot(
            agentStatusEntries: [
                SessionStatusEntrySnapshot(
                    key: "claude_code",
                    value: "Claude is waiting for your input",
                    icon: "exclamationmark.bubble.fill",
                    color: "#FF9F0A",
                    timestamp: 1_000
                )
            ],
            agentLifecyclesByStatusKey: ["claude_code": "running"]
        )
        workspace.restorePanelScopedAgentStatus(terminal: terminal, panelId: panelId)

        let row = try #require(workspace.sidebarAgentStatusRows().first)
        // The restored row is bound to the live pane, so clicking it can
        // focus that pane immediately after relaunch.
        #expect(row.panelId == panelId)
        #expect(row.value == "Claude is waiting for your input")
        // Captured "running" must not survive restore: the resumed agent sits
        // at its prompt, so a restored Running pill would stick until the
        // next hook fires.
        #expect(row.lifecycle == .unknown)

        // The seeded state round-trips back out into the next snapshot.
        #expect(workspace.panelScopedAgentStatusSnapshots(panelId: panelId)?.first?.key == "claude_code")
        #expect(workspace.panelScopedAgentLifecycleSnapshots(panelId: panelId)?["claude_code"] == "unknown")
    }

    @Test
    func testRestoreSessionSnapshotSeedsPanelScopedRowsAfterEphemeralClears() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.recordPanelStatusEntry(
            makeEntry(key: "codex", value: "Reviewing PR", timestamp: Date(timeIntervalSince1970: 500)),
            panelId: panelId
        )
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .needsInput)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        let oldToNewPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(oldToNewPanelIds[panelId])

        // restoreSessionSnapshot clears statusEntries/agent PIDs/lifecycles
        // AFTER restorePane, so the seed must run after those clears. Seeding
        // during panel creation shipped exactly this bug: the clears wiped
        // the rows before the sidebar ever saw them.
        let row = try #require(restored.sidebarAgentStatusRows().first)
        #expect(row.panelId == restoredPanelId)
        #expect(row.statusKey == "codex")
        #expect(row.value == "Reviewing PR")
        #expect(row.lifecycle == .needsInput)
    }

    @Test
    func testPanelScopedStatusValueChangeDirtiesAutosaveFingerprint() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)

        workspace.recordPanelStatusEntry(
            makeEntry(key: "claude_code", value: "Running", timestamp: Date(timeIntervalSince1970: 100)),
            panelId: panelId
        )
        let runningFingerprint = manager.sessionAutosaveFingerprint()

        // Value-only change: the entry count is unchanged, so a count-based
        // fingerprint never goes dirty and the autosave keeps persisting the
        // stale row text until an unrelated change happens to land.
        workspace.recordPanelStatusEntry(
            makeEntry(key: "claude_code", value: "Waiting for input", timestamp: Date(timeIntervalSince1970: 200)),
            panelId: panelId
        )
        #expect(manager.sessionAutosaveFingerprint() != runningFingerprint)

        let beforeLifecycleChange = manager.sessionAutosaveFingerprint()
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
        #expect(manager.sessionAutosaveFingerprint() != beforeLifecycleChange)
    }
}
