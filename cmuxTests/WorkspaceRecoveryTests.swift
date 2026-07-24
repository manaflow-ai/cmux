import CmuxSettings
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias AppStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias AppStoredShortcut = cmux.StoredShortcut
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceRecoveryTests {
    private func makeCustomizationStore() throws -> (
        store: WorkspaceDirectoryCustomizationStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "WorkspaceDirectoryCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (
            WorkspaceDirectoryCustomizationStore(
                defaults: defaults,
                storageKey: "test.customizations"
            ),
            defaults,
            suiteName
        )
    }

    @Test
    func closedHistoryPushesMostRecentFirstAndBoundsCapacity() throws {
        #expect(ClosedItemHistoryStore.defaultWorkspaceCapacity == 100)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let baseSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(baseSnapshot.panels.first)
        let historyStore = ClosedItemHistoryStore(
            workspaceCapacity: 2,
            loadPersisted: false
        )

        historyStore.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        for index in 1...3 {
            var snapshot = baseSnapshot
            snapshot.customTitle = "Closed \(index)"
            historyStore.push(.workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: UUID(),
                windowId: nil,
                workspaceIndex: index,
                snapshot: snapshot
            )))
        }

        let menuSnapshot = historyStore.menuSnapshot()
        #expect(menuSnapshot.totalItemCount == 3)
        #expect(
            menuSnapshot.items
                .filter {
                    $0.detail == String(
                        localized: "menu.history.recentlyClosed.kind.workspace",
                        defaultValue: "Workspace"
                    )
                }
                .map(\.title) == ["Closed 3", "Closed 2"]
        )
    }

    @Test
    func repeatedWorkspaceReopenSkipsNewerPanelHistoryAndIsAdditive() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let historyStore = ClosedItemHistoryStore(capacity: 10, loadPersisted: false)
        let keptWorkspace = manager.addWorkspace(
            title: "Kept",
            workingDirectory: "/tmp/kept",
            select: false
        )

        let firstClosed = manager.addWorkspace(
            title: "First Closed",
            workingDirectory: "/tmp/first-closed",
            select: false
        )
        manager.setTabColor(tabId: firstClosed.id, color: "#112233")
        let firstEntry = ClosedWorkspaceHistoryEntry(
            workspaceId: firstClosed.id,
            windowId: nil,
            workspaceIndex: try #require(manager.tabs.firstIndex { $0.id == firstClosed.id }),
            snapshot: firstClosed.sessionSnapshot(includeScrollback: false)
        )
        manager.closeWorkspace(firstClosed, recordHistory: false)
        historyStore.push(.workspace(firstEntry))

        let secondClosed = manager.addWorkspace(
            title: "Second Closed",
            workingDirectory: "/tmp/second-closed",
            select: false
        )
        manager.setTabColor(tabId: secondClosed.id, color: "#445566")
        let secondEntry = ClosedWorkspaceHistoryEntry(
            workspaceId: secondClosed.id,
            windowId: nil,
            workspaceIndex: try #require(manager.tabs.firstIndex { $0.id == secondClosed.id }),
            snapshot: secondClosed.sessionSnapshot(includeScrollback: false)
        )
        manager.closeWorkspace(secondClosed, recordHistory: false)
        historyStore.push(.workspace(secondEntry))

        let keptPanelSnapshot = try #require(
            keptWorkspace.sessionSnapshot(includeScrollback: false).panels.first
        )
        historyStore.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: keptWorkspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: keptPanelSnapshot
        )))

        let preexistingWorkspaceIds = Set(manager.tabs.map(\.id))
        #expect(manager.reopenMostRecentlyClosedWorkspace(from: historyStore))
        #expect(manager.selectedWorkspace?.customTitle == "Second Closed")
        #expect(manager.selectedWorkspace?.customColor == "#445566")
        #expect(manager.selectedWorkspace?.currentDirectory == "/tmp/second-closed")
        #expect(preexistingWorkspaceIds.isSubset(of: Set(manager.tabs.map(\.id))))
        #expect(manager.tabs.count == preexistingWorkspaceIds.count + 1)

        #expect(manager.reopenMostRecentlyClosedWorkspace(from: historyStore))
        #expect(manager.selectedWorkspace?.customTitle == "First Closed")
        #expect(manager.selectedWorkspace?.customColor == "#112233")
        #expect(manager.selectedWorkspace?.currentDirectory == "/tmp/first-closed")
        #expect(preexistingWorkspaceIds.isSubset(of: Set(manager.tabs.map(\.id))))
        #expect(manager.tabs.count == preexistingWorkspaceIds.count + 2)
        #expect(historyStore.menuSnapshot().items.map(\.detail) == [
            String(localized: "menu.history.recentlyClosed.kind.tab", defaultValue: "Tab")
        ])
    }

    @Test
    func appRestorePrefersTheActiveDestinationWithoutMutatingTheSourceWindow() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let sourceWindowId = UUID()
        let sourceManager = TabManager(autoWelcomeIfNeeded: false)
        sourceManager.windowId = sourceWindowId
        let closedWorkspace = sourceManager.addWorkspace(
            title: "Closed in Source",
            workingDirectory: "/tmp/source-window",
            select: false
        )
        let entry = ClosedWorkspaceHistoryEntry(
            workspaceId: closedWorkspace.id,
            windowId: sourceWindowId,
            workspaceIndex: try #require(
                sourceManager.tabs.firstIndex { $0.id == closedWorkspace.id }
            ),
            snapshot: closedWorkspace.sessionSnapshot(includeScrollback: false)
        )
        sourceManager.closeWorkspace(closedWorkspace, recordHistory: false)

        let sourceContext = AppDelegate.MainWindowContext(
            windowId: sourceWindowId,
            tabManager: sourceManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: nil,
            cmuxConfigStore: nil,
            window: nil
        )
        appDelegate.mainWindowContexts[ObjectIdentifier(sourceContext)] = sourceContext
        appDelegate.tabManager = sourceManager

        let destinationManager = TabManager(autoWelcomeIfNeeded: false)
        let sourceIdsBeforeRestore = Set(sourceManager.tabs.map(\.id))
        let destinationIdsBeforeRestore = Set(destinationManager.tabs.map(\.id))
        let historyStore = ClosedItemHistoryStore(loadPersisted: false)
        historyStore.push(.workspace(entry))

        #expect(appDelegate.reopenMostRecentlyClosedWorkspace(
            from: historyStore,
            preferredTabManager: destinationManager,
            shouldActivate: false
        ))
        #expect(Set(sourceManager.tabs.map(\.id)) == sourceIdsBeforeRestore)
        #expect(destinationIdsBeforeRestore.isSubset(of: Set(destinationManager.tabs.map(\.id))))
        #expect(destinationManager.tabs.count == destinationIdsBeforeRestore.count + 1)
        #expect(destinationManager.selectedWorkspace?.customTitle == "Closed in Source")
    }

    @Test
    func closedRestoreDoesNotTurnAnAutomaticSnapshotTitleIntoStickyUserIdentity() throws {
        let directory = "/tmp/automatic-history-title"
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.setCustomTitle("Sticky Label", for: directory)

        let sourceManager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false
        )
        let closedWorkspace = try #require(sourceManager.selectedWorkspace)
        #expect(sourceManager.setCustomTitle(
            tabId: closedWorkspace.id,
            title: "Automatic Snapshot Title",
            source: .auto
        ))
        let entry = ClosedWorkspaceHistoryEntry(
            workspaceId: closedWorkspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: closedWorkspace.sessionSnapshot(includeScrollback: false)
        )

        let destinationManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: fixture.store
        )
        let historyStore = ClosedItemHistoryStore(loadPersisted: false)
        historyStore.push(.workspace(entry))

        #expect(destinationManager.reopenMostRecentlyClosedWorkspace(from: historyStore))
        #expect(destinationManager.selectedWorkspace?.customTitle == "Sticky Label")
        #expect(fixture.store.customization(for: directory)?.customTitle == "Sticky Label")
    }

    @Test
    func directoryCustomizationPersistsAndNormalizesEquivalentPaths() throws {
        let suiteName = "WorkspaceDirectoryCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = WorkspaceDirectoryCustomizationStore(
            defaults: defaults,
            storageKey: "test.customizations"
        )
        firstStore.setCustomTitle("Project Alpha", for: "/tmp/project/../project")
        firstStore.setCustomColor("#123456", for: "/tmp/project")

        let reloadedStore = WorkspaceDirectoryCustomizationStore(
            defaults: defaults,
            storageKey: "test.customizations"
        )
        #expect(
            reloadedStore.customization(for: "/tmp/project/") ==
                WorkspaceDirectoryCustomization(
                    customTitle: "Project Alpha",
                    customColor: "#123456"
                )
        )
    }

    @Test
    func createRenameAndColorChangesShareOneStickyDirectoryRecord() throws {
        let directory = "/tmp/sticky-project"
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store
        store.setCustomTitle("Original Label", for: directory)
        store.setCustomColor("#112233", for: directory)

        let firstManager = TabManager(
            initialWorkingDirectory: "\(directory)/.",
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        let firstWorkspace = try #require(firstManager.selectedWorkspace)
        #expect(firstWorkspace.customTitle == "Original Label")
        #expect(firstWorkspace.customColor == "#112233")

        firstWorkspace.currentDirectory = "/tmp/sticky-project/subdirectory"
        #expect(firstManager.setCustomTitle(
            tabId: firstWorkspace.id,
            title: "Renamed Label"
        ))
        firstManager.setTabColor(tabId: firstWorkspace.id, color: "#AABBCC")

        let secondManager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        let secondWorkspace = try #require(secondManager.selectedWorkspace)
        #expect(secondWorkspace.customTitle == "Renamed Label")
        #expect(secondWorkspace.customColor == "#AABBCC")
        #expect(store.customization(for: firstWorkspace.currentDirectory) == nil)

        secondManager.clearCustomTitle(tabId: secondWorkspace.id)
        secondManager.setTabColor(tabId: secondWorkspace.id, color: nil)

        let clearedManager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        let clearedWorkspace = try #require(clearedManager.selectedWorkspace)
        #expect(clearedWorkspace.customTitle == nil)
        #expect(clearedWorkspace.customColor == nil)

        #expect(clearedManager.setCustomTitle(
            tabId: clearedWorkspace.id,
            title: "Automatic Title",
            source: .auto
        ))
        let afterAutomaticRename = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        #expect(afterAutomaticRename.selectedWorkspace?.customTitle == nil)
    }

    @Test
    func sessionRestoreAppliesStickyCustomizationToTheWorkspaceRoot() throws {
        let directory = "/tmp/session-sticky-project"
        let sourceManager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false
        )
        let snapshot = sourceManager.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.workspaces.first?.customizationDirectory == directory)

        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store
        store.setCustomTitle("Sticky Session Label", for: directory)
        store.setCustomColor("#778899", for: directory)
        let restoredManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )

        restoredManager.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try #require(restoredManager.selectedWorkspace)
        #expect(restoredWorkspace.customTitle == "Sticky Session Label")
        #expect(restoredWorkspace.customColor == "#778899")
        #expect(restoredWorkspace.customizationDirectory == store.directoryKey(for: directory))
    }

    @Test
    func explicitCreationTitleUpdatesStickyLabelAndPreservesStickyColor() throws {
        let directory = "/tmp/explicit-project"
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store
        store.setCustomTitle("Old Label", for: directory)
        store.setCustomColor("#445566", for: directory)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )

        let explicitlyNamed = manager.addWorkspace(
            title: "CLI Label",
            workingDirectory: directory,
            inheritWorkingDirectory: false,
            select: false
        )
        #expect(explicitlyNamed.customTitle == "CLI Label")
        #expect(explicitlyNamed.customColor == "#445566")

        let laterManager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        #expect(laterManager.selectedWorkspace?.customTitle == "CLI Label")
        #expect(laterManager.selectedWorkspace?.customColor == "#445566")
    }

    @Test
    func reopenWorkspaceShortcutIsCustomizableAndMappedToThePaletteCommand() throws {
        let expected = AppStoredShortcut(
            key: "t",
            command: true,
            shift: true,
            option: false,
            control: false
        )
        #expect(KeyboardShortcutSettings.Action.reopenClosedWorkspace.defaultShortcut == expected)
        #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(.reopenClosedWorkspace))
        let settingsAction = try #require(
            ShortcutAction(rawValue: KeyboardShortcutSettings.Action.reopenClosedWorkspace.rawValue)
        )
        #expect(
            settingsAction.defaultStroke ==
                CmuxSettings.ShortcutStroke(key: "t", command: true, shift: true)
        )
        #expect(settingsAction.group == .workspace)
        #expect(settingsAction.displayName == KeyboardShortcutSettings.Action.reopenClosedWorkspace.label)
        #expect(ShortcutAction.settingsVisibleActions.contains(settingsAction))
        #expect(ShortcutAction.reopenClosedBrowserPanel.defaultStroke == nil)
        #expect(KeyboardShortcutSettings.Action.reopenClosedBrowserPanel.defaultShortcut.isUnbound)
        #expect(
            ContentView.commandPaletteShortcutAction(
                forCommandID: "palette.reopenClosedWorkspace"
            ) == .reopenClosedWorkspace
        )
    }
}
