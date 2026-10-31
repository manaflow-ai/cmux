import CMUXAgentLaunch
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Persistence coverage for per-workspace Claude difficulty and the manual
/// priority flag, plus the live-state precedence rules.
///
/// Serialized: one test swaps a `SessionPriorityCoordinatorHook` closure and puts back the one
/// the app installed.
@Suite(.serialized)
struct SessionPrioritySnapshotTests {
    private func makeSnapshot() -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
    }

    @Test
    func fieldsRoundTrip() throws {
        var snapshot = makeSnapshot()
        snapshot.claudeDifficultyOverride = "hard"
        snapshot.claudeDifficultyAuto = "easy"
        snapshot.sessionPriorityManual = true
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.claudeDifficultyOverride == "hard")
        #expect(decoded.claudeDifficultyAuto == "easy")
        #expect(decoded.sessionPriorityManual == true)
        #expect(decoded.restoredClaudeDifficultyOverride == .hard)
        #expect(decoded.restoredClaudeDifficultyAuto == .easy)
    }

    @Test
    func legacyManifestDecodesToDefaults() throws {
        let data = try JSONEncoder().encode(makeSnapshot())
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.claudeDifficultyOverride == nil)
        #expect(decoded.claudeDifficultyAuto == nil)
        #expect(decoded.sessionPriorityManual == nil)
        #expect(decoded.restoredClaudeDifficultyOverride == nil)
        #expect(decoded.restoredClaudeDifficultyAuto == nil)
    }

    @Test
    func garbageRawDecodesToNil() throws {
        var snapshot = makeSnapshot()
        snapshot.claudeDifficultyOverride = "impossible"
        snapshot.claudeDifficultyAuto = ""
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.restoredClaudeDifficultyOverride == nil)
        #expect(decoded.restoredClaudeDifficultyAuto == nil)
    }

    @MainActor
    @Test
    func defaultStateWritesNoFields() throws {
        let workspace = Workspace()
        var snapshot = makeSnapshot()
        snapshot.captureSessionPriorityState(from: workspace)
        let json = try #require(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        #expect(!json.contains("claudeDifficultyOverride"))
        #expect(!json.contains("claudeDifficultyAuto"))
        #expect(!json.contains("sessionPriorityManual"))
    }

    @MainActor
    @Test
    func captureAndRestoreThroughWorkspace() {
        let workspace = Workspace()
        workspace.sessionPriorityState.difficultyOverride = .hard
        workspace.sessionPriorityState.autoDifficulty = .easy
        workspace.sessionPriorityState.isManual = true
        var snapshot = makeSnapshot()
        snapshot.captureSessionPriorityState(from: workspace)
        #expect(snapshot.claudeDifficultyOverride == "hard")
        #expect(snapshot.claudeDifficultyAuto == "easy")
        #expect(snapshot.sessionPriorityManual == true)

        let restored = Workspace()
        restored.restoreSessionPriorityState(from: snapshot)
        #expect(restored.sessionPriorityState.difficultyOverride == .hard)
        #expect(restored.sessionPriorityState.autoDifficulty == .easy)
        #expect(restored.sessionPriorityState.isManual)
    }

    @MainActor
    @Test
    func effectiveDifficultyPrecedence() {
        let state = SessionPriorityWorkspaceState()
        #expect(state.effectiveDifficulty == .normal)
        #expect(state.difficultySource == .default)
        state.autoDifficulty = .easy
        #expect(state.effectiveDifficulty == .easy)
        #expect(state.difficultySource == .auto)
        state.difficultyOverride = .hard
        #expect(state.effectiveDifficulty == .hard)
        #expect(state.difficultySource == .override)
        state.difficultyOverride = nil
        #expect(state.effectiveDifficulty == .easy)
    }

    @MainActor
    @Test
    func noOpMutationsDoNotNotify() {
        let workspace = Workspace()
        var notified = 0
        let installed = SessionPriorityCoordinatorHook.workspaceStateDidChange
        defer { SessionPriorityCoordinatorHook.workspaceStateDidChange = installed }
        SessionPriorityCoordinatorHook.workspaceStateDidChange = { _ in notified += 1 }
        workspace.setClaudeDifficultyOverride(nil)
        workspace.setSessionPriorityManual(false)
        #expect(notified == 0)
        workspace.setClaudeDifficultyOverride(.hard)
        workspace.setClaudeDifficultyOverride(.hard)
        workspace.setAutoClaudeDifficulty(.easy)
        workspace.setAutoClaudeDifficulty(.easy)
        workspace.setSessionPriorityManual(true)
        workspace.setSessionPriorityManual(true)
        #expect(notified == 3)
    }

    /// The priority row is derived state the coordinator rebuilds while the setting is on, so a
    /// saved one never comes back with the workspace, on or off. The autosave keeps it, and
    /// restore drops it with every other status row.
    @MainActor
    @Test
    func restoredWorkspaceCarriesNoPriorityRow() {
        let workspace = Workspace()
        workspace.setStatusEntry(
            SidebarStatusEntry(
                key: SessionPriorityStatusRow.key,
                value: "Urgent · Normal · high · applied",
                icon: "hare.fill",
                priority: SessionPriorityStatusRow.priority
            ),
            key: SessionPriorityStatusRow.key,
            panelId: nil
        )
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.statusEntries.contains { $0.key == SessionPriorityStatusRow.key })

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        #expect(restored.statusEntries[SessionPriorityStatusRow.key] == nil)
    }
}
