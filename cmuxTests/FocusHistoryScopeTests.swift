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
