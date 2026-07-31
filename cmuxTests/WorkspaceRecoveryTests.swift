import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
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
            window: nil,
            workspaceTerminalFontSizeArbiter:
                appDelegate.workspaceTerminalFontSizeArbiter
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

        let generated = destinationManager.addWorkspace(
            title: "Generated Title",
            titleSource: .auto,
            workingDirectory: directory,
            select: false
        )
        #expect(generated.customTitle == "Generated Title")
        #expect(fixture.store.customization(for: directory)?.customTitle == "Sticky Label")
    }
    @Test
    func failedClosedRestoreDoesNotPersistSnapshotCustomization() throws {
        let directory = "/tmp/failed-history-restore"
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.setCustomTitle("Existing Label", for: directory)

        let sourceManager = TabManager(initialWorkingDirectory: directory, autoWelcomeIfNeeded: false)
        var snapshot = try #require(sourceManager.selectedWorkspace).sessionSnapshot(includeScrollback: false)
        snapshot.customTitle = "Failed Restore Label"
        snapshot.customTitleSource = .user
        var panelSnapshot = try #require(snapshot.panels.first)
        panelSnapshot.type = .markdown
        panelSnapshot.terminal = nil
        panelSnapshot.browser = nil
        panelSnapshot.markdown = nil
        panelSnapshot.filePreview = nil
        panelSnapshot.rightSidebarTool = nil
        snapshot.panels = [panelSnapshot]
        snapshot.layout = .pane(SessionPaneLayoutSnapshot(
            panelIds: [panelSnapshot.id],
            selectedPanelId: panelSnapshot.id
        ))
        let entry = ClosedWorkspaceHistoryEntry(
            workspaceId: UUID(),
            windowId: nil,
            workspaceIndex: 0,
            snapshot: snapshot
        )
        let destinationManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: fixture.store
        )

        #expect(!destinationManager.restoreClosedWorkspace(entry))
        #expect(fixture.store.customization(for: directory)?.customTitle == "Existing Label")
        let defaultDirectory = "/tmp/failed-history-default-root"
        fixture.store.setCustomTitle("Home Label", for: defaultDirectory)
        let rootlessManager = TabManager(
            autoWelcomeIfNeeded: false,
            defaultWorkspaceWorkingDirectoryProvider: { defaultDirectory },
            workspaceDirectoryCustomizationStore: fixture.store
        )
        let rootlessWorkspace = try #require(rootlessManager.selectedWorkspace)
        #expect(rootlessWorkspace.customTitle == nil)
        rootlessManager.setTabColor(tabId: rootlessWorkspace.id, color: "#123456")
        #expect(
            fixture.store.customization(for: defaultDirectory) ==
                WorkspaceDirectoryCustomization(customTitle: "Home Label", customColor: "#123456")
        )
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
    func freshWorkspaceCreationDoesNotAdoptStickyDirectoryIdentityFromInheritedCwd() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-sticky-cmdn-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let directory = directoryURL.path
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store
        let manager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        let sourceWorkspace = try #require(manager.selectedWorkspace)

        #expect(manager.setCustomTitle(
            tabId: sourceWorkspace.id,
            title: "MY WORKSPACE"
        ))
        manager.applyWorkspaceColor(
            "#AABBCC",
            toWorkspaceIds: [sourceWorkspace.id]
        )
        #expect(
            store.customization(for: directory) ==
                WorkspaceDirectoryCustomization(
                    customTitle: "MY WORKSPACE",
                    customColor: "#AABBCC"
                )
        )

        let generated = manager.addWorkspace(select: false)
        #expect(generated.title == "Terminal 2")
        #expect(generated.currentDirectory == directory)
        #expect(generated.customTitle == nil)
        #expect(generated.customColor == nil)

        let explicitlyNamed = manager.addWorkspace(
            title: "Explicit Fresh",
            workingDirectory: directory,
            inheritWorkingDirectory: false,
            select: false
        )
        #expect(explicitlyNamed.customTitle == "Explicit Fresh")
        #expect(explicitlyNamed.customColor == nil)
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
        #expect(firstWorkspace.customTitle == nil)
        #expect(firstWorkspace.customColor == nil)
        #expect(firstWorkspace.customizationDirectory == store.directoryKey(for: directory))

        firstWorkspace.currentDirectory = "/tmp/sticky-project/subdirectory"
        #expect(firstManager.setCustomTitle(
            tabId: firstWorkspace.id,
            title: "Renamed Label"
        ))
        firstManager.setTabColor(tabId: firstWorkspace.id, color: "#AABBCC")
        #expect(
            store.customization(for: directory) ==
                WorkspaceDirectoryCustomization(
                    customTitle: "Renamed Label",
                    customColor: "#AABBCC"
                )
        )
        var staleSnapshot = firstWorkspace.sessionSnapshot(includeScrollback: false)
        staleSnapshot.customTitle = "Stale Snapshot Label"
        staleSnapshot.customColor = "#112233"

        let secondManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        secondManager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [staleSnapshot]
        ))
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
        clearedManager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [secondWorkspace.sessionSnapshot(includeScrollback: false)]
        ))
        let clearedWorkspace = try #require(clearedManager.selectedWorkspace)
        #expect(clearedWorkspace.customTitle == nil)
        #expect(clearedWorkspace.customColor == nil)

        #expect(clearedManager.setCustomTitle(
            tabId: clearedWorkspace.id,
            title: "Automatic Title",
            source: .auto
        ))
        let afterAutomaticRename = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        afterAutomaticRename.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [clearedWorkspace.sessionSnapshot(includeScrollback: false)]
        ))
        #expect(afterAutomaticRename.selectedWorkspace?.customTitle == nil)
    }

    @Test
    func batchColorChangesPersistForEveryWorkspaceRoot() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store
        store.setCustomTitle("First", for: "/tmp/batch-first")
        store.setCustomTitle("Second", for: "/tmp/batch-second")

        let manager = TabManager(
            initialWorkingDirectory: "/tmp/batch-first",
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        let first = try #require(manager.selectedWorkspace)
        let second = manager.addWorkspace(
            workingDirectory: "/tmp/batch-second",
            select: false
        )

        manager.applyWorkspaceColor(
            "#123456",
            toWorkspaceIds: [first.id, second.id]
        )

        #expect(store.customization(for: "/tmp/batch-first")?.customTitle == "First")
        #expect(store.customization(for: "/tmp/batch-first")?.customColor == "#123456")
        #expect(store.customization(for: "/tmp/batch-second")?.customTitle == "Second")
        #expect(store.customization(for: "/tmp/batch-second")?.customColor == "#123456")
    }

    @Test
    func sessionRestoreAppliesStickyCustomizationToTheWorkspaceRoot() throws {
        let directory = "/tmp/session-sticky-project"
        let sourceManager = TabManager(initialWorkingDirectory: directory, autoWelcomeIfNeeded: false)
        let sourceWorkspace = try #require(sourceManager.selectedWorkspace)
        #expect(sourceManager.setCustomTitle(tabId: sourceWorkspace.id, title: "Stale Snapshot Label"))
        sourceManager.setTabColor(tabId: sourceWorkspace.id, color: "#111111")
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
        #expect(explicitlyNamed.customColor == nil)
        #expect(
            store.customization(for: directory) ==
                WorkspaceDirectoryCustomization(
                    customTitle: "CLI Label",
                    customColor: "#445566"
                )
        )

        let laterManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: store
        )
        laterManager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [explicitlyNamed.sessionSnapshot(includeScrollback: false)]
        ))
        #expect(laterManager.selectedWorkspace?.customTitle == "CLI Label")
        #expect(laterManager.selectedWorkspace?.customColor == "#445566")
    }

}
