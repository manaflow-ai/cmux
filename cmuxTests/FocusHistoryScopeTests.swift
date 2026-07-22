import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FocusHistoryScopeTests {
    private func withPaneHistoryManager(_ body: (TabManager) throws -> Void) throws {
        let suiteName = "FocusHistoryScopeTests.paneHistory.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(true, for: SettingCatalog().app.focusHistoryIncludesPanesAndTabs)
        try body(TabManager(settings: settings))
    }

    @Test func panesAndTabsSettingNavigatesWithinWorkspacePanels() throws {
        try withPaneHistoryManager { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let firstPanelId = try #require(workspace.focusedPanelId)
            let secondPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

            workspace.focusPanel(firstPanelId)
            workspace.focusPanel(secondPanelId)

            #expect(manager.canNavigateBack)
            manager.navigateBack()
            #expect(workspace.focusedPanelId == firstPanelId)
            #expect(manager.canNavigateForward)
        }
    }

    @Test func panesAndTabsSettingSkipsClosedPanelThatResolvesToCurrentPanel() throws {
        try withPaneHistoryManager { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let closedPanelId = try #require(workspace.focusedPanelId)
            let fallbackPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

            workspace.focusPanel(closedPanelId)
            _ = workspace.closePanel(closedPanelId, force: true)
            drainMainQueue()

            #expect(workspace.focusedPanelId == fallbackPanelId)
            #expect(!manager.canNavigateBack)
            let revision = manager.focusHistoryRevision
            manager.navigateBack()
            #expect(workspace.focusedPanelId == fallbackPanelId)
            #expect(manager.focusHistoryRevision == revision)
        }
    }

    @Test func panesAndTabsSettingInvalidatesClosedPanelHistory() throws {
        try withPaneHistoryManager { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let closedPanelId = try #require(workspace.focusedPanelId)
            let fallbackPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

            workspace.focusPanel(closedPanelId)
            workspace.focusPanel(fallbackPanelId)
            #expect(manager.canNavigateBack)
            let revision = manager.focusHistoryRevision

            _ = workspace.closePanel(closedPanelId, force: true)

            #expect(manager.focusHistoryRevision > revision)
            #expect(!manager.canNavigateBack)
        }
    }

    @Test func panesAndTabsSettingInvalidatesClosedPaneHistory() throws {
        try withPaneHistoryManager { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let leftPanelId = try #require(workspace.focusedPanelId)
            let leftPaneId = try #require(workspace.paneId(forPanelId: leftPanelId))
            let rightPanel = try #require(
                workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal)
            )

            workspace.focusPanel(leftPanelId)
            workspace.focusPanel(rightPanel.id)
            #expect(manager.canNavigateBack)
            let revision = manager.focusHistoryRevision

            #expect(workspace.bonsplitController.closePane(leftPaneId))
            #expect(manager.focusHistoryRevision > revision)
            #expect(!manager.canNavigateBack)
        }
    }

    @Test func ghosttyFocusMapsSurfaceToPanelWithPanesAndTabsSetting() throws {
        try withPaneHistoryManager { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let secondPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
            let secondSurfaceId = try #require(workspace.surfaceIdFromPanelId(secondPanelId))
            #expect(secondSurfaceId.uuid != secondPanelId)

            let firstPanelId = try #require(workspace.panels.keys.first { $0 != secondPanelId })
            workspace.focusPanel(firstPanelId)
            let revision = manager.focusHistoryRevision

            NotificationCenter.default.post(
                name: .ghosttyDidFocusSurface,
                object: nil,
                userInfo: [
                    GhosttyNotificationKey.tabId: workspace.id,
                    GhosttyNotificationKey.surfaceId: secondSurfaceId.uuid,
                ]
            )
            drainMainQueue()

            #expect(manager.focusHistoryRevision > revision)
        }
    }

    @Test func panesAndTabsHistoryMenuReflectsRenamedWorkspaceAndPanel() throws {
        try withPaneHistoryManager { manager in
            let firstWorkspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(firstWorkspace.focusedPanelId)
            firstWorkspace.setCustomTitle("Renamed Workspace")
            firstWorkspace.setPanelCustomTitle(panelId: panelId, title: "Renamed Pane")

            _ = manager.addWorkspace(select: true)

            let item = try #require(manager.focusHistoryMenuSnapshot(direction: .back).items.first)
            #expect(item.workspaceTitle == "Renamed Workspace")
            #expect(item.panelTitle == "Renamed Pane")
            #expect(FocusHistoryMenuFormatter.title(for: item) == "Renamed Workspace - Renamed Pane")
        }
    }

    @Test func workspacesOnlySettingSkipsPanelsInCurrentWorkspace() throws {
        let suiteName = "FocusHistoryScopeTests.workspacesOnly.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(false, for: SettingCatalog().app.focusHistoryIncludesPanesAndTabs)
        let manager = TabManager(settings: settings)
        let firstWorkspace = try #require(manager.selectedWorkspace)
        let pane = try #require(firstWorkspace.bonsplitController.allPaneIds.first)
        let firstPanelId = try #require(firstWorkspace.focusedPanelId)
        let secondPanelId = try #require(firstWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        firstWorkspace.focusPanel(firstPanelId)
        firstWorkspace.focusPanel(secondPanelId)

        #expect(!manager.canNavigateBack)
        #expect(!manager.navigateBack())

        let secondWorkspace = manager.addWorkspace(select: true)
        #expect(manager.navigateBack())
        #expect(manager.selectedTabId == firstWorkspace.id)
        #expect(manager.navigateForward())
        #expect(manager.selectedTabId == secondWorkspace.id)
    }

    @Test func scopeChangeInvalidatesAvailability() throws {
        let suiteName = "FocusHistoryScopeTests.scopeChange.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let scopeKey = SettingCatalog().app.focusHistoryIncludesPanesAndTabs
        settings.set(true, for: scopeKey)
        let manager = TabManager(settings: settings)
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let firstPanelId = try #require(workspace.focusedPanelId)
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.focusPanel(firstPanelId)
        workspace.focusPanel(secondPanelId)
        #expect(manager.canNavigateBack)

        let enabledRevision = manager.focusHistoryRevision
        settings.set(false, for: scopeKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(manager.focusHistoryRevision > enabledRevision)
        #expect(!manager.canNavigateBack)

        let disabledRevision = manager.focusHistoryRevision
        settings.set(true, for: scopeKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(manager.focusHistoryRevision > disabledRevision)
        #expect(manager.canNavigateBack)
    }

    @Test func restoredWorkspaceDockUsesInjectedSetting() throws {
        let suiteName = "FocusHistoryScopeTests.restoredWorkspace.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(true, for: SettingCatalog().app.focusHistoryIncludesPanesAndTabs)
        let source = TabManager(settings: settings)
        let snapshot = source.sessionSnapshot(includeScrollback: false)

        let restored = TabManager(settings: settings)
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try #require(restored.tabs.first)
        #expect(restoredWorkspace.dockSplit.focusHistoryIncludesPanesAndTabs)
    }
}
