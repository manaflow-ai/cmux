import AppKit
import CmuxSettings
import CmuxWorkspaces
import Foundation
import Observation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct HistoryMenuCoordinatorTests {
    private func withPaneHistoryManager(_ body: (TabManager) throws -> Void) throws {
        let suiteName = "HistoryMenuCoordinatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(true, for: SettingCatalog().app.focusHistoryIncludesPanesAndTabs)
        try body(TabManager(settings: settings))
    }

    @Test
    func identicalProjectionDoesNotPublish() throws {
        try withPaneHistoryManager { manager in
            let center = NotificationCenter()
            let coordinator = HistoryMenuCoordinator(
                center: center,
                closedItemHistoryStore: ClosedItemHistoryStore(fileURL: nil, loadPersisted: false),
                managerProvider: { manager },
                mainMenuProvider: { nil },
                actions: .unavailable
            )
            coordinator.refreshIfNeeded()
            let firstState = coordinator.state
            var publicationCount = 0
            withObservationTracking {
                _ = coordinator.state
            } onChange: {
                publicationCount += 1
            }

            coordinator.refreshIfNeeded()

            #expect(coordinator.state == firstState)
            #expect(publicationCount == 0)

            _ = manager.addWorkspace(select: true)
            center.post(name: .tabManagerFocusHistoryRevisionDidChange, object: manager)

            #expect(coordinator.state != firstState)
            #expect(publicationCount == 1)
        }
    }

    @Test
    func mainMenuTrackingRefreshesCurrentTitles() throws {
        try withPaneHistoryManager { manager in
            let center = NotificationCenter()
            let mainMenu = NSMenu()
            let trackedMenu = NSMenu()
            let trackedItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
            trackedItem.submenu = trackedMenu
            mainMenu.addItem(trackedItem)
            let firstWorkspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(firstWorkspace.focusedPanelId)
            firstWorkspace.setCustomTitle("Before Workspace")
            firstWorkspace.setPanelCustomTitle(panelId: panelId, title: "Before Pane")
            _ = manager.addWorkspace(select: true)

            let coordinator = HistoryMenuCoordinator(
                center: center,
                closedItemHistoryStore: ClosedItemHistoryStore(fileURL: nil, loadPersisted: false),
                managerProvider: { manager },
                mainMenuProvider: { mainMenu },
                actions: .unavailable
            )
            coordinator.refreshIfNeeded()
            #expect(coordinator.state.recentlyFocusedItems.first?.workspaceTitle == "Before Workspace")

            let revisionBeforeRename = manager.focusHistoryRevision
            firstWorkspace.setCustomTitle("After Workspace")
            firstWorkspace.setPanelCustomTitle(panelId: panelId, title: "After Pane")
            #expect(manager.focusHistoryRevision == revisionBeforeRename)
            #expect(coordinator.state.recentlyFocusedItems.first?.workspaceTitle == "Before Workspace")

            center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
            #expect(coordinator.state.recentlyFocusedItems.first?.workspaceTitle == "Before Workspace")

            center.post(name: NSMenu.didBeginTrackingNotification, object: trackedMenu)

            #expect(coordinator.state.recentlyFocusedItems.first?.workspaceTitle == "After Workspace")
            #expect(coordinator.state.recentlyFocusedItems.first?.panelTitle == "After Pane")
        }
    }
}
