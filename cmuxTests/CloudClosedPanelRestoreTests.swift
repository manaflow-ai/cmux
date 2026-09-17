import Bonsplit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudClosedPanelRestoreTests {
    @Test("Closing a deferred Cloud browser keeps the last pane empty until reopen")
    func deferredBrowserReopensWithoutTerminal() throws {
        try withManager { manager in
            let workspace = manager.addWorkspace(initialSurface: .browser, autoWelcomeIfNeeded: false)
            let browserID = try #require(workspace.focusedPanelId)
            let resource = SurfaceResourceID(machine: .cloud(UUID().uuidString), kind: .browser, key: "browser-1")
            let record = SurfaceProjectionRecord(
                panelID: browserID, resource: resource,
                remoteWorkspaceID: "remote-workspace", remoteTabID: "remote-tab"
            )
            var snapshot = workspace.sessionSnapshot(includeScrollback: false)
            snapshot.surfaceProjections = [record]
            let remap = workspace.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
            let deferredID = try #require(remap[browserID])
            #expect(workspace.panels[deferredID] is DeferredBrowserPanel)
            workspace.markCloseHistoryEligible(panelId: deferredID)
            #expect(workspace.closePanel(deferredID, force: true))
            #expect(workspace.panels.isEmpty)
            #expect(workspace.bonsplitController.allPaneIds.count == 1)
            #expect(manager.reopenMostRecentlyClosedItem())
            let restoredID = try #require(workspace.focusedPanelId)
            #expect(workspace.panels.count == 1)
            #expect(workspace.panels[restoredID]?.panelType == .browser)
            let projection = try #require(SurfaceCatalog.shared.projection(forPanel: restoredID))
            #expect(projection.resource == resource)
            #expect(projection.remoteWorkspaceID == "remote-workspace")
            #expect(projection.remoteTabID == "remote-tab")
        }
    }

    @Test("History remaps layout-only references and persists the revision")
    func anchorRemappingIncludesLayoutOnlyReferences() throws {
        try withManager { manager in
            let workspace = manager.addWorkspace(initialSurface: .browser, autoWelcomeIfNeeded: false)
            let snapshot = try #require(workspace.sessionSnapshot(includeScrollback: false).panels.first)
            let oldID = UUID(), newID = UUID()
            let layout = SessionWorkspaceLayoutSnapshot.split(SessionSplitLayoutSnapshot(
                orientation: .vertical, dividerPosition: 0.35,
                first: .pane(SessionPaneLayoutSnapshot(panelIds: [oldID], selectedPanelId: oldID, isFullWidthTabMode: true)),
                second: .pane(SessionPaneLayoutSnapshot(panelIds: [snapshot.id], selectedPanelId: snapshot.id))
            ))
            let store = ClosedItemHistoryStore(loadPersisted: false)
            store.push(.panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id, paneId: UUID(), tabIndex: 0,
                snapshot: snapshot, layout: layout
            )))
            let revision = store.revision
            store.remapPanelAnchorIds(from: oldID, to: newID)
            #expect(store.revision == revision + 1)
            #expect(store.restoreFirstRestorable { entry in
                guard case .panel(let panel) = entry,
                      case .split(let split)? = panel.layout,
                      case .pane(let first) = split.first else {
                    Issue.record("Expected saved nested layout")
                    return false
                }
                #expect(first.panelIds == [newID])
                #expect(first.selectedPanelId == newID)
                #expect(first.isFullWidthTabMode == true)
                #expect(split.dividerPosition == 0.35)
                return true
            })
        }
    }

    @Test("Reopen retains panes and tabs created after the history snapshot")
    func unrelatedTopologySurvivesReopen() throws {
        try withManager { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let sourceID = try #require(workspace.focusedPanelId)
            let browserID = try #require(manager.newBrowserSplit(
                tabId: workspace.id, fromPanelId: sourceID,
                orientation: .horizontal, url: URL(string: "about:blank")
            ))
            workspace.markCloseHistoryEligible(panelId: browserID)
            #expect(workspace.closePanel(browserID, force: true))
            let addedID = try #require(workspace.newTerminalSplit(
                from: sourceID, orientation: .vertical, focus: false
            )?.id)
            let addedPane = try #require(workspace.paneId(forPanelId: addedID))
            let addedTab = try #require(workspace.newTerminalSurface(inPane: addedPane, focus: false)?.id)
            let sourcePane = try #require(workspace.paneId(forPanelId: sourceID))
            #expect(manager.reopenMostRecentlyClosedItem())
            #expect(workspace.paneId(forPanelId: sourceID) == sourcePane)
            #expect(workspace.paneId(forPanelId: addedID) == addedPane)
            #expect(workspace.paneId(forPanelId: addedTab) == addedPane)
            #expect(workspace.panels.values.filter { $0.panelType == .browser }.count == 1)
            #expect(workspace.panels.count == 4)
        }
    }

    @Test("Reopen from another workspace restores the collapsed browser split")
    func collapsedBrowserSplitReopensInItsOwnPane() throws {
        try withManager { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let sourceID = try #require(workspace.focusedPanelId)
            let browserID = try #require(manager.newBrowserSplit(
                tabId: workspace.id, fromPanelId: sourceID,
                orientation: .horizontal, url: URL(string: "about:blank")
            ))
            #expect(workspace.closePanel(browserID, force: true))
            let panelIDsBeforeReopen = Set(workspace.panels.keys)
            let other = manager.addWorkspace()
            #expect(manager.selectedTabId == other.id)
            #expect(manager.reopenMostRecentlyClosedBrowserPanel())
            let newIDs = Set(workspace.panels.keys).subtracting(panelIDsBeforeReopen)
            #expect(newIDs.count == 1)
            let reopenedID = try #require(newIDs.first)
            #expect(workspace.panels[reopenedID] is BrowserPanel)
            #expect(manager.selectedTabId == workspace.id)
            #expect(workspace.focusedPanelId == reopenedID)
            #expect(workspace.bonsplitController.allPaneIds.count == 2)
            let sourcePane = try #require(workspace.paneId(forPanelId: sourceID))
            let browserPane = try #require(workspace.paneId(forPanelId: reopenedID))
            #expect(sourcePane != browserPane)
        }
    }

    private func withManager(_ body: (TabManager) throws -> Void) throws {
        let suite = "CloudClosedPanelRestoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "closeWorkspaceOnLastSurfaceShortcut")
        let settings = AppCatalogSection()
        defaults.set(false, forKey: settings.warnBeforeClosingTab.userDefaultsKey)
        defaults.set(false, forKey: settings.warnBeforeClosingTabXButton.userDefaultsKey)
        let manager = TabManager(settings: UserDefaultsSettingsClient(defaults: defaults), closeTabWarningDefaults: defaults)
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            for workspace in manager.tabs {
                for panelID in workspace.panels.keys {
                    SurfaceCatalog.shared.endProjections(panelID: panelID, reason: .replaced)
                }
            }
            manager.finalizeAllWorkspacesForWindowClose()
            ClosedItemHistoryStore.shared.removeAll()
            defaults.removePersistentDomain(forName: suite)
        }
        try body(manager)
    }
}
