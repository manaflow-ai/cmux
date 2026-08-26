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

private extension HistoryMenuActions {
    static var unavailableForTests: HistoryMenuActions {
        HistoryMenuActions(
            reopenMostRecentlyClosedWorkspace: { _ in false },
            reopenMostRecentlyClosedItem: { _ in false },
            reopenClosedHistoryItem: { _, _ in false },
            reopenPreviousSession: { false }
        )
    }
}

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
            let closedHistory = ClosedItemHistoryStore(
                fileURL: nil,
                loadPersisted: false,
                notificationCenter: center
            )
            let coordinator = HistoryMenuCoordinator(
                center: center,
                closedItemHistoryStore: closedHistory,
                managerProvider: { manager },
                mainMenuProvider: { nil },
                actions: .unavailableForTests
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
            let itemBeforeRename = try #require(manager.recentlyFocusedFocusHistoryMenuItems(maxItemCount: 10).first)
            let closedHistory = ClosedItemHistoryStore(
                fileURL: nil,
                loadPersisted: false,
                notificationCenter: center
            )

            let coordinator = HistoryMenuCoordinator(
                center: center,
                closedItemHistoryStore: closedHistory,
                managerProvider: { manager },
                mainMenuProvider: { mainMenu },
                actions: .unavailableForTests
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
            #expect(coordinator.navigate(to: itemBeforeRename))
            #expect(manager.selectedTabId == firstWorkspace.id)
        }
    }

    @Test
    func closedHistoryRevisionRefreshesProjection() throws {
        try withPaneHistoryManager { manager in
            let center = NotificationCenter()
            let closedHistory = ClosedItemHistoryStore(
                fileURL: nil,
                loadPersisted: false,
                notificationCenter: center
            )
            let coordinator = HistoryMenuCoordinator(
                center: center,
                closedItemHistoryStore: closedHistory,
                managerProvider: { manager },
                mainMenuProvider: { nil },
                actions: .unavailableForTests
            )
            coordinator.refreshIfNeeded()
            #expect(coordinator.state.recentlyClosed.items.isEmpty)

            let workspace = try #require(manager.selectedWorkspace)
            var snapshot = workspace.sessionSnapshot(includeScrollback: false)
            snapshot.customTitle = "Closed Workspace"
            let recordID = UUID()
            closedHistory.push(ClosedItemHistoryRecord(
                id: recordID,
                closedAt: Date(timeIntervalSince1970: 1),
                entry: .workspace(ClosedWorkspaceHistoryEntry(
                    workspaceId: workspace.id,
                    windowId: nil,
                    workspaceIndex: 0,
                    snapshot: snapshot
                ))
            ))

            #expect(coordinator.state.recentlyClosed.items.map(\.id) == [recordID])
            #expect(coordinator.state.recentlyClosed.items.first?.title == "Closed Workspace")

            _ = closedHistory.removeRecord(id: recordID)
            #expect(coordinator.state.recentlyClosed.items.isEmpty)
        }
    }

    @Test
    func managedCloudVMRemovalRefreshesProjectionOnSignOut() throws {
        try withPaneHistoryManager { manager in
            let center = NotificationCenter()
            let closedHistory = ClosedItemHistoryStore(
                fileURL: nil,
                loadPersisted: false,
                notificationCenter: center
            )
            let coordinator = HistoryMenuCoordinator(
                center: center,
                closedItemHistoryStore: closedHistory,
                managerProvider: { manager },
                mainMenuProvider: { nil },
                actions: .unavailableForTests
            )
            coordinator.refreshIfNeeded()

            let workspace = try #require(manager.selectedWorkspace)
            var cloudSnapshot = workspace.sessionSnapshot(includeScrollback: false)
            cloudSnapshot.remote = SessionRemoteWorkspaceSnapshot(
                transport: .websocket,
                destination: "cloud-vm",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                preserveAfterTerminalExit: true,
                skipDaemonBootstrap: true,
                relayPort: nil,
                persistentDaemonSlot: "cmux-default-freestyle-sshd-v1",
                managedCloudVMID: "vm-history"
            )
            let recordID = UUID()
            closedHistory.push(ClosedItemHistoryRecord(
                id: recordID,
                closedAt: Date(timeIntervalSince1970: 1),
                entry: .workspace(ClosedWorkspaceHistoryEntry(
                    workspaceId: workspace.id,
                    windowId: nil,
                    workspaceIndex: 0,
                    snapshot: cloudSnapshot
                ))
            ))
            #expect(coordinator.state.recentlyClosed.items.map(\.id) == [recordID])

            closedHistory.removeManagedCloudVMRecords()

            #expect(coordinator.state.recentlyClosed.items.isEmpty)
        }
    }
}
