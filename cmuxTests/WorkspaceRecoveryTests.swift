import CmuxSettings
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
        store: WorkspaceCustomizationStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "WorkspaceCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (
            WorkspaceCustomizationStore(
                defaults: defaults,
                storageKey: "test.customizations",
                legacyStorageKey: "test.legacy-customizations"
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
        appDelegate.mainWindowLifecycleCoordinator.register(
            sourceContext,
            lookupKey: ObjectIdentifier(sourceContext)
        )
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
    func closedRestoreKeepsAutomaticSnapshotTitleProvenance() throws {
        let directory = "/tmp/automatic-history-title"
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

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
            workspaceCustomizationStore: fixture.store
        )
        let historyStore = ClosedItemHistoryStore(loadPersisted: false)
        historyStore.push(.workspace(entry))

        #expect(destinationManager.reopenMostRecentlyClosedWorkspace(from: historyStore))
        let reopened = try #require(destinationManager.selectedWorkspace)
        #expect(reopened.customTitle == "Automatic Snapshot Title")
        #expect(reopened.effectiveCustomTitleSource == .auto)
        #expect(fixture.store.customization(for: reopened.stableId) == nil)
    }

    @Test
    func failedClosedRestoreLeavesNoWorkspaceOrRecoveryRecord() throws {
        let directory = "/tmp/failed-history-restore"
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

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
            workspaceCustomizationStore: fixture.store
        )
        let tabsBeforeRestore = destinationManager.tabs.map(\.id)

        #expect(!destinationManager.restoreClosedWorkspace(entry))
        #expect(destinationManager.tabs.map(\.id) == tabsBeforeRestore)
        if let stableId = snapshot.stableId {
            #expect(fixture.store.customization(for: stableId) == nil)
        }
    }

    @Test
    func freshWorkspaceCreationDoesNotCloneRenamedSiblingIdentity() throws {
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
        // Read settings from the fixture suite, not UserDefaults.standard:
        // app-host test processes on one machine share the standard domain,
        // so another run's inheritance toggle would change the directory here.
        let manager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: fixture.defaults),
            workspaceCustomizationStore: store
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
    func stableWorkspaceJournalRecoversStaleTitleColorAndClears() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store

        let sourceManager = TabManager(
            initialWorkingDirectory: "/tmp/stable-workspace-journal",
            autoWelcomeIfNeeded: false,
            workspaceCustomizationStore: store
        )
        let sourceWorkspace = try #require(sourceManager.selectedWorkspace)
        #expect(sourceManager.setCustomTitle(
            tabId: sourceWorkspace.id,
            title: "Renamed Label"
        ))
        sourceManager.setTabColor(tabId: sourceWorkspace.id, color: "#AABBCC")
        #expect(
            store.customization(for: sourceWorkspace.stableId) ==
                WorkspaceCustomization(
                    customTitle: .value("Renamed Label"),
                    customColor: .value("#AABBCC")
                )
        )
        var staleSnapshot = sourceWorkspace.sessionSnapshot(includeScrollback: false)
        staleSnapshot.customTitle = "Stale Snapshot Label"
        staleSnapshot.customColor = "#112233"

        let restoredManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceCustomizationStore: store
        )
        restoredManager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [staleSnapshot]
        ))
        let restoredWorkspace = try #require(restoredManager.selectedWorkspace)
        #expect(restoredWorkspace.customTitle == "Renamed Label")
        #expect(restoredWorkspace.customColor == "#AABBCC")

        restoredManager.clearCustomTitle(tabId: restoredWorkspace.id)
        restoredManager.setTabColor(tabId: restoredWorkspace.id, color: nil)
        var staleClearedSnapshot = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        staleClearedSnapshot.customTitle = "Resurrected Label"
        staleClearedSnapshot.customColor = "#FFFFFF"

        let clearedManager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: store)
        clearedManager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [staleClearedSnapshot]
        ))
        let clearedWorkspace = try #require(clearedManager.selectedWorkspace)
        #expect(clearedWorkspace.customTitle == nil)
        #expect(clearedWorkspace.customColor == nil)
    }

    @Test(arguments: [Workspace.CustomTitleSource.auto, .remote], [false, true])
    func latestTitleWriteSurvivesRecovery(
        source: Workspace.CustomTitleSource,
        restoreClosed: Bool
    ) throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "User Title"))
        if source == .auto {
            manager.clearCustomTitle(tabId: workspace.id)
        }
        manager.setTabColor(tabId: workspace.id, color: "#123456")
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Latest Title", source: source))
        // A later color write must preserve the title's recovery provenance.
        manager.setTabColor(tabId: workspace.id, color: "#ABCDEF")
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let restored = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)

        if restoreClosed {
            #expect(restored.restoreClosedWorkspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspace.id,
                windowId: nil,
                workspaceIndex: 0,
                snapshot: snapshot
            )))
        } else {
            restored.restoreSessionSnapshot(SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [snapshot]
            ))
        }

        let recovered = try #require(restored.selectedWorkspace)
        #expect(recovered.customTitle == "Latest Title")
        #expect(recovered.customTitleSource == source)
        #expect(recovered.customColor == "#ABCDEF")
    }

    @Test(arguments: [Workspace.CustomTitleSource.auto, .remote])
    func latestTitleRecoversOverStaleUserSnapshot(source: Workspace.CustomTitleSource) throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Old User Title"))
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        if source == .auto {
            manager.clearCustomTitle(tabId: workspace.id)
        }
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Latest Title", source: source))

        let restored = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        restored.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [snapshot]
        ))
        #expect(restored.selectedWorkspace?.customTitle == "Latest Title")
        #expect(restored.selectedWorkspace?.customTitleSource == source)
    }

    @Test(arguments: [Workspace.CustomTitleSource.auto, .remote])
    func newerUserRenameRecoversOverNonUserSnapshot(source: Workspace.CustomTitleSource) throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Snapshot Title", source: source))
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "New User Title"))
        // Rejected automatic writes must not replace the recovery record.
        #expect(!manager.setCustomTitle(tabId: workspace.id, title: "Rejected", source: .auto))

        let restored = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        restored.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [snapshot]
        ))
        #expect(restored.selectedWorkspace?.customTitle == "New User Title")
        #expect(restored.selectedWorkspace?.customTitleSource == .user)
    }

    @Test(arguments: [Workspace.CustomTitleSource.auto, .remote], [false, true])
    func legacyTitleJournalDoesNotOverrideNonUserSnapshot(
        source: Workspace.CustomTitleSource,
        cleared: Bool
    ) throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(workspace.setCustomTitle("Snapshot Title", source: source))
        let customization = WorkspaceCustomization(
            customTitle: cleared ? .cleared : .value("Old User Title"),
            customColor: .value("#ABCDEF")
        )
        // Reproduce the on-disk journal written before title provenance existed.
        let data = try JSONEncoder().encode(customization)
        var fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields.removeValue(forKey: "customTitleSource")
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "nextRevision": 1,
            "entries": [workspace.stableId.uuidString: ["revision": 1, "customization": fields]]
        ]), forKey: "test.customizations")

        let restored = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        restored.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [workspace.sessionSnapshot(includeScrollback: false)]
        ))
        #expect(restored.selectedWorkspace?.customTitle == "Snapshot Title")
        #expect(restored.selectedWorkspace?.customTitleSource == source)
        #expect(restored.selectedWorkspace?.customColor == "#ABCDEF")
    }

    @Test
    func closingWorkspaceDropsCustomizationJournal() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        _ = manager.addWorkspace(select: false)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Closed Title"))
        manager.setTabColor(tabId: workspace.id, color: "#ABCDEF")
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        manager.closeWorkspace(workspace, recordHistory: false)
        #expect(fixture.store.customization(for: workspace.stableId) == nil)
        #expect(manager.restoreClosedWorkspace(ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: snapshot
        )))
        #expect(manager.selectedWorkspace?.customTitle == "Closed Title")
        #expect(manager.selectedWorkspace?.customColor == "#ABCDEF")
    }

    @Test
    func titleAndColorRecoveryFieldsRemainIndependent() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store

        let manager = TabManager(
            initialWorkingDirectory: "/tmp/independent-fields",
            autoWelcomeIfNeeded: false,
            workspaceCustomizationStore: store
        )
        let workspace = try #require(manager.selectedWorkspace)
        workspace.setCustomColor("#123456")
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Only Title Recorded"))
        #expect(
            store.customization(for: workspace.stableId) ==
                WorkspaceCustomization(
                    customTitle: .value("Only Title Recorded"),
                    customColor: .absent
                )
        )

        let restoredManager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: store)
        restoredManager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [workspace.sessionSnapshot(includeScrollback: false)]
        ))
        #expect(restoredManager.selectedWorkspace?.customTitle == "Only Title Recorded")
        #expect(restoredManager.selectedWorkspace?.customColor == "#123456")
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
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let explicitlyNamed = manager.addWorkspace(
            title: "CLI Label",
            workingDirectory: "/tmp/explicit-project",
            inheritWorkingDirectory: false,
            select: false
        )
        #expect(explicitlyNamed.customTitle == "CLI Label")
        #expect(explicitlyNamed.effectiveCustomTitleSource == .user)
        #expect(explicitlyNamed.customColor == nil)

        let laterManager = TabManager(autoWelcomeIfNeeded: false)
        laterManager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [explicitlyNamed.sessionSnapshot(includeScrollback: false)]
        ))
        #expect(laterManager.selectedWorkspace?.customTitle == "CLI Label")
    }

}
