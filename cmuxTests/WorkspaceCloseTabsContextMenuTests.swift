import Foundation
import Testing
import Bonsplit
import CmuxSettings
@testable import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
extension TerminalSurface {
    @MainActor
    func setNeedsConfirmCloseOverrideForTesting(_ value: Bool?) {
        closeConfirmationOverride = value
    }
}
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceCloseTabsContextMenuTests {
    private let closeWorkspaceOnLastSurfaceKey = "closeWorkspaceOnLastSurfaceShortcut"

    @Test
    func closeOthersClosesAllTargetedTabsWhenEveryPanelNeedsConfirmation() throws {
        try withCleanClosedHistory {
            let fixture = try makeWorkspaceWithFourConfirmingTabs()
            let anchorTabId = fixture.tabIds[1]

            try invoke(.closeOthers, anchorTabId: anchorTabId, fixture: fixture)

            assertRemainingTabs([anchorTabId], in: fixture)
        }
    }

    @Test
    func closeOthersRecordsTargetedTabsInRecentlyClosedHistory() throws {
        try withCleanClosedHistory {
            let fixture = try makeWorkspaceWithFourConfirmingTabs()
            let anchorTabId = fixture.tabIds[1]

            try invoke(.closeOthers, anchorTabId: anchorTabId, fixture: fixture)

            let closedTitles = ClosedItemHistoryStore.shared.menuSnapshot().items.reversed().map(\.title)
            #expect(closedTitles == ["Tab 1", "Tab 3", "Tab 4"])
        }
    }

    @Test
    func closeToRightClosesAllTargetedTabsWhenEveryPanelNeedsConfirmation() throws {
        try withCleanClosedHistory {
            let fixture = try makeWorkspaceWithFourConfirmingTabs()
            let anchorTabId = fixture.tabIds[0]

            try invoke(.closeToRight, anchorTabId: anchorTabId, fixture: fixture)

            assertRemainingTabs([anchorTabId], in: fixture)
        }
    }

    @Test
    func closeToLeftClosesAllTargetedTabsWhenEveryPanelNeedsConfirmation() throws {
        try withCleanClosedHistory {
            let fixture = try makeWorkspaceWithFourConfirmingTabs()
            let anchorTabId = fixture.tabIds[3]

            try invoke(.closeToLeft, anchorTabId: anchorTabId, fixture: fixture)

            assertRemainingTabs([anchorTabId], in: fixture)
        }
    }

    @Test
    func sharedCloseHistoryPathRecordsDirectTabActionCloses() throws {
        try withCleanClosedHistory {
            let fixture = try makeWorkspaceWithFourConfirmingTabs()
            let tabId = fixture.tabIds[2]

            #expect(fixture.workspace.requestCloseTabRecordingHistory(tabId, force: true))
            drainMainQueue()

            let entry = try #require(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
            #expect(entry.title == "Tab 3")
            #expect(entry.detail == "Tab")
        }
    }

    @Test
    func tabCloseButtonKeepOpenRecordsClosedSurfaceHistoryForLastSurface() throws {
        try withCleanClosedHistory {
            try withManager(closeWorkspaceOnLastSurface: false) { manager in
                let workspace = manager.addWorkspace()
                manager.selectWorkspace(workspace)

                let panelId = try #require(workspace.focusedPanelId)
                let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId))
                workspace.setPanelCustomTitle(panelId: panelId, title: "Closed Last Surface")
                manager.confirmCloseHandler = { _, _, _ in true }

                workspace.markTabCloseButtonClose(surfaceId: surfaceId)
                _ = workspace.closePanel(panelId)
                drainMainQueue()
                drainMainQueue()
                drainMainQueue()

                #expect(workspace.panels[panelId] == nil)
                #expect(workspace.panels.count == 1)

                let item = try #require(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
                #expect(item.title == "Closed Last Surface")
                #expect(item.detail == "Tab")
            }
        }
    }

    @Test
    func repeatedCloseAttemptDuringPendingConfirmationPreservesRecentlyClosedHistory() throws {
        try withCleanClosedHistory {
            let fixture = try makeWorkspaceWithFourConfirmingTabs()
            let tabId = fixture.tabIds[2]

            var promptCount = 0
            var repeatedCloseAttempted = false
            fixture.manager.confirmCloseHandler = { _, _, _ in
                promptCount += 1
                if !repeatedCloseAttempted {
                    repeatedCloseAttempted = true
                    #expect(!fixture.workspace.requestCloseTabRecordingHistory(tabId, force: false))
                }
                return true
            }

            #expect(!fixture.workspace.requestCloseTabRecordingHistory(tabId, force: false))
            drainMainQueue()
            drainMainQueue()
            drainMainQueue()

            #expect(promptCount == 1)
            #expect(repeatedCloseAttempted)
            #expect(fixture.workspace.panelIdFromSurfaceId(tabId) == nil)

            let entry = try #require(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
            #expect(entry.title == "Tab 3")
            #expect(entry.detail == "Tab")
        }
    }

    private struct Fixture {
        let manager: TabManager
        let workspace: Workspace
        let paneId: PaneID
        let tabIds: [TabID]
    }

    private func makeWorkspaceWithFourConfirmingTabs() throws -> Fixture {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))

        _ = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        _ = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        _ = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))

        let tabIds = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        #expect(tabIds.count == 4, "Precondition: fixture should start with four tabs in one pane")

        for (index, tabId) in tabIds.enumerated() {
            let panelId = try #require(workspace.panelIdFromSurfaceId(tabId))
            workspace.setPanelCustomTitle(panelId: panelId, title: "Tab \(index + 1)")
            let terminalPanel = try #require(workspace.terminalPanel(for: panelId))
            terminalPanel.updateShellActivityState(.commandRunning)
        }

        return Fixture(manager: manager, workspace: workspace, paneId: paneId, tabIds: tabIds)
    }

    private func withManager(
        closeWorkspaceOnLastSurface: Bool,
        run: (TabManager) throws -> Void
    ) throws {
        let suiteName = "WorkspaceCloseTabsContextMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(closeWorkspaceOnLastSurface, forKey: closeWorkspaceOnLastSurfaceKey)
        try run(TabManager(settings: UserDefaultsSettingsClient(defaults: defaults)))
    }

    private func invoke(_ action: TabContextAction, anchorTabId: TabID, fixture: Fixture) throws {
        var promptCount = 0
        fixture.manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return true
        }

        let anchorTab = try #require(fixture.workspace.bonsplitController.tab(anchorTabId))
        fixture.workspace.splitTabBar(
            fixture.workspace.bonsplitController,
            didRequestTabContextAction: action,
            for: anchorTab,
            inPane: fixture.paneId
        )
        drainMainQueue()
        drainMainQueue()

        #expect(promptCount == 1, "Expected one confirmation prompt for \(action)")
    }

    private func assertRemainingTabs(_ expected: [TabID], in fixture: Fixture) {
        let remaining = fixture.workspace.bonsplitController.tabs(inPane: fixture.paneId).map(\.id)
        #expect(remaining == expected)
        for closedTabId in fixture.tabIds where !expected.contains(closedTabId) {
            #expect(
                fixture.workspace.panelIdFromSurfaceId(closedTabId) == nil,
                "Expected targeted tab \(closedTabId) to be removed"
            )
        }
    }

    private func withCleanClosedHistory(_ body: () throws -> Void) rethrows {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }
        try body()
    }
}
