import AppKit
import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct SessionPriorityContextMenuSnapshotTests {
    private static let defaultsKey = "sessionPriorityEnabled"

    private func withSetting(_ enabled: Bool?, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.defaultsKey)
        if let enabled { defaults.set(enabled, forKey: Self.defaultsKey) } else { defaults.removeObject(forKey: Self.defaultsKey) }
        defer {
            if let previous { defaults.set(previous, forKey: Self.defaultsKey) } else { defaults.removeObject(forKey: Self.defaultsKey) }
        }
        try body()
    }

    /// The context menu snapshot the sidebar builds for a row whose input carries `state`.
    private func menuSnapshot(_ state: SessionPriorityMenuState) throws -> SidebarWorkspaceContextMenuSnapshot {
        let workspaceId = UUID()
        let suiteName = "SessionPriorityContextMenuSnapshotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var input = SidebarWorkspaceContextMenuTargetAggregateTests.rowInput(
            workspaceId: workspaceId,
            groupId: nil,
            unreadCount: 0,
            isMultiSelected: false,
            isRemote: false,
            remoteState: .disconnected,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults)
        )
        input.sessionPriorityMenu = state
        let list = SidebarWorkspaceRowsSnapshot(
            workspaceRowsById: [workspaceId: input],
            groupRowsById: [:],
            selectedContextTargetIds: [],
            anchorWorkspaceIds: [],
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            canCreateEmptyGroup: true,
            notificationIndex: SidebarWorkspaceNotificationIndex(notifications: [])
        )
        return input.rowSnapshot(list: list).contextMenu
    }

    @Test
    func snapshotCarriesSessionPriorityFields() throws {
        try withSetting(true) {
            let workspace = Workspace()
            workspace.sessionPriorityState.difficultyOverride = .hard
            var state = SessionPriorityMenuState(workspace: workspace)
            #expect(state.enabled)
            #expect(state.difficultyOverride == .hard)
            #expect(!state.adjustableManual)

            workspace.sessionPriorityState.isManual = true
            state = SessionPriorityMenuState(workspace: workspace)
            #expect(state.adjustableManual)

            let snapshot = try menuSnapshot(state)
            #expect(snapshot.sessionPriorityEnabled)
            #expect(snapshot.claudeDifficultyOverride == .hard)
            #expect(snapshot.sessionPriorityAdjustableManual)
            let disabled = try menuSnapshot(.disabled)
            #expect(!disabled.sessionPriorityEnabled)
            #expect(disabled.claudeDifficultyOverride == nil)
            #expect(!disabled.sessionPriorityAdjustableManual)
        }
    }

    /// The row reads its menu values from the workspace's sidebar snapshot, built outside
    /// rendering, so a change must show up in a freshly built snapshot.
    @Test
    func workspaceSidebarSnapshotCarriesTheMenuValues() throws {
        let suiteName = "SessionPriorityContextMenuSnapshotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try withSetting(true) {
            let workspace = Workspace()
            @MainActor func menu() -> SessionPriorityMenuState {
                SidebarWorkspaceSnapshotFactory(
                    workspace: workspace,
                    settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
                    showsAgentActivity: false
                ).makeSnapshot().sessionPriorityMenu
            }
            #expect(menu() == SessionPriorityMenuState(enabled: true))
            workspace.setClaudeDifficultyOverride(.hard)
            workspace.setSessionPriorityManual(true)
            #expect(menu() == SessionPriorityMenuState(enabled: true, difficultyOverride: .hard, adjustableManual: true))
        }
    }

    @Test
    func menuSectionHiddenWhenDisabled() throws {
        try withSetting(false) {
            let workspace = Workspace()
            workspace.sessionPriorityState.difficultyOverride = .hard
            workspace.sessionPriorityState.isManual = true
            #expect(!SessionPriorityMenuState(workspace: workspace).enabled)
            let snapshot = try menuSnapshot(SessionPriorityMenuState(workspace: workspace))
            #expect(!snapshot.sessionPriorityEnabled)
        }
    }

    @Test
    func manualItemFlipsBetweenDontAdjustAndAdjustAutomatically() {
        let off = SessionPriorityActions.manualItemTitle(adjustableManual: false)
        let on = SessionPriorityActions.manualItemTitle(adjustableManual: true)
        #expect(off != on)
        #expect(SessionPriorityActions.difficultyChoices.count == 4)
        #expect(SessionPriorityActions.difficultyChoices.first! == nil)
    }

    /// The first change after subscribing is delivered synchronously; a second one
    /// inside the 50 ms coalescing window would only arrive as the trailing edge,
    /// so each change gets its own workspace.
    private func rowRefreshCount(afterChanging change: (Workspace) -> Void) -> Int {
        let workspace = Workspace()
        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink { publishCount += 1 }
        defer { cancellable.cancel() }
        publishCount = 0
        change(workspace)
        return publishCount
    }

    @Test
    func sidebarRowRefreshesWhenDifficultyOverrideChanges() {
        #expect(rowRefreshCount { $0.setClaudeDifficultyOverride(.hard) } >= 1)
    }

    @Test
    func sidebarRowRefreshesWhenManualFlagChanges() {
        #expect(rowRefreshCount { $0.setSessionPriorityManual(true) } >= 1)
    }

    /// A restore (a reopened session) brings back the override and the manual flag the row
    /// freezes into its menu, so the row rebuilds then too.
    @Test
    func sidebarRowRefreshesWhenARestoreBringsBackTheMenuValues() {
        let saved = Workspace()
        saved.sessionPriorityState.difficultyOverride = .hard
        saved.sessionPriorityState.isManual = true
        let snapshot = saved.sessionSnapshot(includeScrollback: false)

        #expect(rowRefreshCount { $0.restoreSessionPriorityState(from: snapshot) } >= 1)
    }

    @Test
    func sidebarRowStaysWhenNothingChanges() {
        #expect(rowRefreshCount { $0.setClaudeDifficultyOverride(nil) } == 0)
        #expect(rowRefreshCount { $0.setSessionPriorityManual(false) } == 0)
    }
}
