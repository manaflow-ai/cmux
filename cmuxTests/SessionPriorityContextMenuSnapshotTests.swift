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

    private func withSetting(_ enabled: Bool?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.defaultsKey)
        if let enabled { defaults.set(enabled, forKey: Self.defaultsKey) } else { defaults.removeObject(forKey: Self.defaultsKey) }
        defer {
            if let previous { defaults.set(previous, forKey: Self.defaultsKey) } else { defaults.removeObject(forKey: Self.defaultsKey) }
        }
        body()
    }

    private func menuSnapshot(_ state: SessionPriorityMenuState) -> SidebarWorkspaceContextMenuSnapshot {
        SidebarWorkspaceContextMenuSnapshot(
            targetWorkspaceIds: [],
            remoteTargetWorkspaceIds: [],
            allRemoteTargetsConnecting: false,
            allRemoteTargetsDisconnected: false,
            pinState: nil,
            groupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            canCreateEmptyGroup: true,
            eligibleGroupTargetIds: [],
            allEligibleTargetsGroupId: nil,
            hasGroupedEligibleTarget: false,
            todoStatusLanes: [],
            sessionPriorityEnabled: state.enabled,
            claudeDifficultyOverride: state.difficultyOverride,
            sessionPriorityAdjustableManual: state.adjustableManual,
            canMarkRead: false,
            canMarkUnread: false,
            hasLatestNotification: false,
            allNotificationsMuted: false,
            hasManualCustomColor: false,
            notifications: []
        )
    }

    @Test
    func snapshotCarriesSessionPriorityFields() {
        withSetting(true) {
            let workspace = Workspace()
            workspace.sessionPriorityState.difficultyOverride = .hard
            var state = SessionPriorityMenuState(workspace: workspace)
            #expect(state.enabled)
            #expect(state.difficultyOverride == .hard)
            #expect(!state.adjustableManual)

            workspace.sessionPriorityState.isManual = true
            state = SessionPriorityMenuState(workspace: workspace)
            #expect(state.adjustableManual)

            let snapshot = menuSnapshot(state)
            #expect(snapshot.sessionPriorityEnabled)
            #expect(snapshot.claudeDifficultyOverride == .hard)
            #expect(snapshot.sessionPriorityAdjustableManual)
            #expect(snapshot != menuSnapshot(.disabled))
        }
    }

    @Test
    func menuSectionHiddenWhenDisabled() {
        withSetting(false) {
            let workspace = Workspace()
            workspace.sessionPriorityState.difficultyOverride = .hard
            workspace.sessionPriorityState.isManual = true
            #expect(!SessionPriorityMenuState(workspace: workspace).enabled)
            #expect(!menuSnapshot(SessionPriorityMenuState(workspace: workspace)).sessionPriorityEnabled)
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
}
