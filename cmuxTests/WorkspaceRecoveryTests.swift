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

        let collisionManager = TabManager(autoWelcomeIfNeeded: false)
        collisionManager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [entry.snapshot]
        ))
        let collisionWorkspace = try #require(collisionManager.tabs.first {
            $0.customTitle == "Closed in Source"
        })
        let collisionPanelStableIds = Set(collisionWorkspace.panels.values.map(\.stableSurfaceId))
        _ = appDelegate.registerMainWindowContextForTesting(tabManager: collisionManager)

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
        let restoredWorkspace = try #require(destinationManager.selectedWorkspace)
        #expect(restoredWorkspace.customTitle == "Closed in Source")
        #expect(restoredWorkspace.id != collisionWorkspace.id)
        #expect(restoredWorkspace.stableId != collisionWorkspace.stableId)
        #expect(collisionPanelStableIds.isDisjoint(with: restoredWorkspace.panels.values.map(\.stableSurfaceId)))
    }

    @Test
    func closedRestoreKeepsAutomaticTitleProvenance() throws {
        let directory = "/tmp/automatic-history-title"
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

        let destinationManager = TabManager(autoWelcomeIfNeeded: false)
        let historyStore = ClosedItemHistoryStore(loadPersisted: false)
        historyStore.push(.workspace(entry))

        #expect(destinationManager.reopenMostRecentlyClosedWorkspace(from: historyStore))
        let reopened = try #require(destinationManager.selectedWorkspace)
        #expect(reopened.customTitle == "Automatic Snapshot Title")
        #expect(reopened.effectiveCustomTitleSource == .auto)
    }
    @Test
    func failedClosedRestoreLeavesNoWorkspaceBehind() throws {
        let directory = "/tmp/failed-history-restore"
        let sourceManager = TabManager(initialWorkingDirectory: directory, autoWelcomeIfNeeded: false)
        var snapshot = try #require(sourceManager.selectedWorkspace).sessionSnapshot(includeScrollback: false)
        snapshot.customTitle = "Failed Restore Label"
        snapshot.customTitleSource = .user
        snapshot.panels = []
        let entry = ClosedWorkspaceHistoryEntry(
            workspaceId: UUID(),
            windowId: nil,
            workspaceIndex: 0,
            snapshot: snapshot
        )
        let destinationManager = TabManager(autoWelcomeIfNeeded: false)
        let tabsBeforeRestore = destinationManager.tabs.map(\.id)

        #expect(!destinationManager.restoreClosedWorkspace(entry))
        #expect(destinationManager.tabs.map(\.id) == tabsBeforeRestore)
    }

    @Test
    func batchColorChangesApplyToEveryTargetWorkspace() throws {
        let manager = TabManager(
            initialWorkingDirectory: "/tmp/batch-first",
            autoWelcomeIfNeeded: false
        )
        let first = try #require(manager.selectedWorkspace)
        let second = manager.addWorkspace(
            workingDirectory: "/tmp/batch-second",
            select: false
        )
        let untouched = manager.addWorkspace(
            workingDirectory: "/tmp/batch-third",
            select: false
        )

        manager.applyWorkspaceColor(
            "#123456",
            toWorkspaceIds: [first.id, second.id]
        )

        #expect(first.customColor == "#123456")
        #expect(second.customColor == "#123456")
        #expect(untouched.customColor == nil)
    }

    @Test
    func explicitCreationTitleBecomesCustomTitleWithoutInheritedColor() throws {
        let directory = "/tmp/explicit-project"
        let manager = TabManager(autoWelcomeIfNeeded: false)

        let explicitlyNamed = manager.addWorkspace(
            title: "CLI Label",
            workingDirectory: directory,
            inheritWorkingDirectory: false,
            select: false
        )
        #expect(explicitlyNamed.customTitle == "CLI Label")
        #expect(explicitlyNamed.effectiveCustomTitleSource == .user)
        #expect(explicitlyNamed.customColor == nil)
    }

    @Test
    func newWorkspaceDoesNotCloneRenamedSiblingIdentity() throws {
        let directory = "/tmp/identity-clone-project"
        let manager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false
        )
        let renamed = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: renamed.id, title: "Renamed Task"))
        manager.setTabColor(tabId: renamed.id, color: "#AABBCC")

        // Cmd+T-style creation: the working directory is inherited from the
        // selected workspace, not requested by the user.
        let inherited = manager.addWorkspace(select: false)
        #expect(inherited.customTitle == nil)
        #expect(inherited.customColor == nil)

        // Same directory requested explicitly (CLI --cwd, open-in-workspace).
        let explicit = manager.addWorkspace(
            workingDirectory: directory,
            inheritWorkingDirectory: false,
            select: false
        )
        #expect(explicit.customTitle == nil)
        #expect(explicit.customColor == nil)
    }

    @Test
    func sessionRestoreKeepsDistinctIdentitiesForSameDirectoryWorkspaces() throws {
        let directory = "/tmp/identity-restore-project"
        let manager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false
        )
        let first = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: first.id, title: "Task One"))
        manager.setTabColor(tabId: first.id, color: "#111111")
        let second = manager.addWorkspace(
            workingDirectory: directory,
            inheritWorkingDirectory: false,
            select: false
        )
        #expect(manager.setCustomTitle(tabId: second.id, title: "Task Two"))
        manager.setTabColor(tabId: second.id, color: "#222222")

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let restoredManager = TabManager(autoWelcomeIfNeeded: false)
        restoredManager.restoreSessionSnapshot(snapshot)

        let restoredTitles = restoredManager.tabs.map(\.customTitle)
        #expect(restoredTitles.contains("Task One"))
        #expect(restoredTitles.contains("Task Two"))
        let restoredColors = restoredManager.tabs.map(\.customColor)
        #expect(restoredColors.contains("#111111"))
        #expect(restoredColors.contains("#222222"))
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
