import AppKit
import CmuxControlSocket
import CmuxHomeCore
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `chief.enabled: false` releases Chief Home: the Home group unpins, the Home
/// workspace and its Chief pane close, and nothing keeps them pinned
/// (https://github.com/manaflow-ai/cmux/issues/26003).
@MainActor
@Suite("Chief disabled releases Home", .serialized)
struct ChiefDisabledHomeTests {
    /// Restores `chief.enabled` after a test changes it.
    private struct ChiefEnabledOverride {
        let key = ChiefCatalogSection().enabled.userDefaultsKey
        let original: Any?

        init(_ enabled: Bool) {
            original = UserDefaults.standard.object(forKey: key)
            ChiefSettings.setEnabled(enabled)
        }

        func restore() {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    @Test func disablingChiefLetsTheHomeGroupUnpinAndHomeClose() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let home = try #require(ChiefHomeNavigation.ensureHome(in: manager))
        let groupId = try #require(home.groupId)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.isPinned == true)

        // Enabled: Home stays the pinned, protected anchor.
        manager.setWorkspaceGroupPinned(groupId: groupId, isPinned: false)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.isPinned == true)
        #expect(!manager.canCloseWorkspace(home, allowPinned: true))

        ChiefSettings.setEnabled(false)
        manager.setWorkspaceGroupPinned(groupId: groupId, isPinned: false)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.isPinned == false)
        #expect(manager.canCloseWorkspace(home, allowPinned: true))
        manager.closeWorkspace(home, recordHistory: false)
        #expect(!manager.tabs.contains { $0.id == home.id })
    }

    @Test func disabledChiefLetsTheHomePaneClose() throws {
        let setting = ChiefEnabledOverride(false)
        defer { setting.restore() }
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let home = try #require(workspace.newChiefSurface(inPane: paneId, isHome: true, focus: false))
        #expect(workspace.closePanel(home.id, force: true))
    }

    @Test func removeHomeClosesHomeAndUnpinsItsGroupWhenChiefIsOff() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let home = try #require(ChiefHomeNavigation.ensureHome(in: manager))
        let groupId = try #require(home.groupId)
        let member = try #require(manager.tabs.first { !$0.holdsChiefHomePane })
        manager.addWorkspaceToGroup(workspaceId: member.id, groupId: groupId)

        // Enabled: removal is a no-op.
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(manager.tabs.contains { $0.id == home.id })

        ChiefSettings.setEnabled(false)
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(!manager.tabs.contains { $0.holdsChiefHomePane })
        #expect(manager.tabs.contains { $0.id == member.id })
        #expect(manager.workspaceGroups.allSatisfy {
            $0.externalID != ChiefHomeNavigation.homeGroupExternalID || !$0.isPinned
        })
        #expect(ChiefHomeNavigation.ensureHome(in: manager) == nil)
    }

    @Test func removeHomeLeavesAWorkspaceWhenHomeWasTheOnlyOne() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let home = try #require(ChiefHomeNavigation.ensureHome(in: manager))
        for workspace in manager.tabs where workspace.id != home.id {
            manager.closeWorkspace(workspace, recordHistory: false)
        }
        #expect(manager.tabs.map(\.id) == [home.id])

        ChiefSettings.setEnabled(false)
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(manager.tabs.count == 1)
        #expect(!manager.tabs.contains { $0.holdsChiefHomePane })
        #expect(manager.selectedWorkspace != nil)
    }

    @Test func disabledChiefServiceDoesNotStart() {
        let setting = ChiefEnabledOverride(false)
        defer { setting.restore() }
        ChiefService.shared.start()
        #expect(ChiefService.shared.storeIfStarted == nil)
        #expect(ChiefService.shared.store == nil)
    }

    @Test func anUnavailableBuildIsDisabledWhateverTheSettingSays() throws {
        let defaults = try #require(UserDefaults(suiteName: "ChiefAvailability-\(UUID().uuidString)"))
        ChiefSettings.setEnabled(true, in: defaults)
        #expect(!ChiefSettings.isEnabled(in: defaults, isAvailable: false))
        #expect(ChiefSettings.isEnabled(in: defaults, isAvailable: true))
        ChiefSettings.setEnabled(false, in: defaults)
        #expect(!ChiefSettings.isEnabled(in: defaults, isAvailable: true))
    }

    @Test func theChiefFlagIsRegistered() {
        #expect(CmuxFeatureFlags.allFlags.contains { $0.key == CmuxFeatureFlags.chiefFlag.key })
    }

    @Test func removeHomeClearsChiefPanesOutsideHome() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let mixed = try #require(manager.addWorkspaceIfActive(select: false))
        let mixedPane = try #require(mixed.bonsplitController.focusedPaneId)
        let chiefTab = try #require(mixed.newChiefSurface(inPane: mixedPane, focus: false))
        let terminal = try #require(mixed.panels.values.first { !($0 is ChiefPanel) })

        let chiefOnly = try #require(manager.addWorkspaceIfActive(select: false))
        let chiefOnlyPane = try #require(chiefOnly.bonsplitController.focusedPaneId)
        _ = try #require(chiefOnly.newChiefSurface(inPane: chiefOnlyPane, focus: false))
        for panel in chiefOnly.panels.values where !(panel is ChiefPanel) {
            _ = chiefOnly.closePanel(panel.id, force: true)
        }

        ChiefSettings.setEnabled(false)
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(mixed.panels[chiefTab.id] == nil)
        #expect(mixed.panels[terminal.id] != nil)
        #expect(!manager.tabs.contains { $0.id == chiefOnly.id })
    }

    @Test func removeHomeClearsChiefTabsFromADock() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let workspace = try #require(manager.addWorkspaceIfActive(select: false))
        let dock = try #require(workspace.dockSplit)
        dock.ensureLoaded()
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        let chiefTab = try #require(dock.newSurface(kind: .chief, inPane: pane, focus: false))

        ChiefSettings.setEnabled(false)
        #expect(dock.newSurface(kind: .chief, inPane: pane, focus: false) == nil)
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(dock.panels[chiefTab] == nil)
        #expect(manager.tabs.contains { $0.id == workspace.id })
    }

    @Test func unpinningTheHomeGroupOverTheControlSeamIsProtectedWhileChiefIsOn() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let home = try #require(ChiefHomeNavigation.ensureHome(in: manager))
        let groupID = try #require(home.groupId)
        let previous = TerminalController.shared.tabManager
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: nil,
            surfaceID: nil,
            paneID: nil
        )

        let result = TerminalController.shared.controlSetWorkspaceGroupPinned(
            routing: routing,
            groupID: groupID,
            isPinned: false
        )

        guard case .protected = result else {
            Issue.record("expected .protected, got \(result)")
            return
        }
        #expect(manager.workspaceGroups.first { $0.id == groupID }?.isPinned == true)
    }

    @Test func removeHomeClosesAChiefOnlyWorkspaceWithAChiefDockTab() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let workspace = try #require(manager.addWorkspaceIfActive(select: false))
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        _ = try #require(workspace.newChiefSurface(inPane: pane, focus: false))
        for panel in workspace.panels.values where !(panel is ChiefPanel) {
            _ = workspace.closePanel(panel.id, force: true)
        }
        let dock = try #require(workspace.dockSplit)
        dock.ensureLoaded()
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
        _ = try #require(dock.newSurface(kind: .chief, inPane: dockPane, focus: false))

        ChiefSettings.setEnabled(false)
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(!manager.tabs.contains { $0.id == workspace.id })
    }

    @Test func removeChiefPanelsClosesAPinnedDockTabWithoutHistory() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let workspace = try #require(manager.addWorkspaceIfActive(select: false))
        let dock = try #require(workspace.dockSplit)
        dock.ensureLoaded()
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        let history = dock.closedItemHistoryStore

        // Control: an ordinary close of a Chief Dock tab enters closed-tab
        // history, so the empty-history check below is not vacuous.
        let userClosedTab = try #require(dock.newSurface(kind: .chief, inPane: pane, focus: false))
        #expect(dock.closePanel(userClosedTab))
        #expect(dock.panels[userClosedTab] == nil)
        #expect(history.menuSnapshot().totalItemCount == 1)
        history.removeAll()
        #expect(history.menuSnapshot().totalItemCount == 0)

        let chiefTab = try #require(dock.newSurface(kind: .chief, inPane: pane, focus: false))
        let tabId = try #require(dock.surfaceId(forPanelId: chiefTab))
        dock.bonsplitController.updateTab(tabId, isPinned: true)
        // A user close already in flight marks the tab history-eligible;
        // turning Chief off must still not record it.
        dock.markDockCloseHistoryEligible(panelId: chiefTab)

        ChiefSettings.setEnabled(false)
        dock.removeChiefPanels()
        #expect(dock.panels[chiefTab] == nil)
        #expect(dock.surfaceId(forPanelId: chiefTab) == nil)
        #expect(history.menuSnapshot().totalItemCount == 0)
    }

    @Test func reopeningAClosedChiefTabIsRefusedWhileChiefIsOff() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let history = ClosedItemHistoryStore.shared
        history.removeAll()
        defer { history.removeAll() }
        let manager = TabManager()
        let workspace = try #require(manager.addWorkspaceIfActive(select: false))
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let chief = try #require(workspace.newChiefSurface(inPane: pane, focus: false))
        workspace.markCloseHistoryEligible(panelId: chief.id)
        #expect(workspace.closePanel(chief.id, force: true))
        let item = try #require(history.menuSnapshot().items.first)
        let record = try #require(history.removeRecord(id: item.id)?.record)
        guard case .panel(let entry) = record.entry else {
            Issue.record("Expected closed-panel history for the Chief tab")
            return
        }

        ChiefSettings.setEnabled(false)
        #expect(workspace.restoreClosedPanel(entry) == nil)
        #expect(!workspace.holdsChiefPane)

        ChiefSettings.setEnabled(true)
        #expect(workspace.restoreClosedPanel(entry) != nil)
        #expect(workspace.holdsChiefPane)
    }

    @Test func openChiefShortcutIsHiddenAndNeverConflictsWhileChiefIsUnavailable() throws {
        #expect(KeyboardShortcutSettings.isOffered(.openChief, isChiefAvailable: true))
        #expect(!KeyboardShortcutSettings.isOffered(.openChief, isChiefAvailable: false))
        #expect(KeyboardShortcutSettings.isOffered(.newTab, isChiefAvailable: false))
        #expect(KeyboardShortcutSettings.unavailableSettingsActions(isChiefAvailable: false) == [.openChief])
        #expect(KeyboardShortcutSettings.unavailableSettingsActions(isChiefAvailable: true).isEmpty)

        // The app installs the Settings package's provider at launch, and it
        // follows the flag: off hides Open Chief, on offers every action.
        let flags = CmuxFeatureFlags.shared
        let originalOverride = flags.overrideValue(for: CmuxFeatureFlags.chiefFlag)
        defer { flags.setOverride(originalOverride, for: CmuxFeatureFlags.chiefFlag) }
        flags.setOverride(false, for: CmuxFeatureFlags.chiefFlag)
        try #require(!ChiefSettings.isAvailable)
        #expect(ShortcutAction.hostUnavailableActions == [.openChief])
        #expect(!ShortcutAction.settingsVisibleActions.contains(.openChief))
        flags.setOverride(true, for: CmuxFeatureFlags.chiefFlag)
        try #require(ChiefSettings.isAvailable)
        #expect(ShortcutAction.hostUnavailableActions.isEmpty)
        #expect(ShortcutAction.settingsVisibleActions.contains(.openChief))

        KeyboardShortcutSettings.resetShortcut(for: .openChief)
        defer { KeyboardShortcutSettings.resetShortcut(for: .openChief) }
        let chiefShortcut = KeyboardShortcutSettings.shortcut(for: .openChief)
        #expect(!chiefShortcut.isUnbound)
        #expect(KeyboardShortcutSettings.conflictingAction(
            for: chiefShortcut, excluding: .renameTab, isChiefAvailable: true
        ) == .openChief)
        #expect(KeyboardShortcutSettings.conflictingAction(
            for: chiefShortcut, excluding: .renameTab, isChiefAvailable: false
        ) != .openChief)
    }

    @Test func dockCreateRefusesChiefBeforeRevealWhileChiefIsOff() {
        #expect(TerminalController.dockAcceptsSurfaceType(.chief, chiefEnabled: true))
        #expect(!TerminalController.dockAcceptsSurfaceType(.chief, chiefEnabled: false))
        #expect(TerminalController.dockAcceptsSurfaceType(.terminal, chiefEnabled: false))
        #expect(TerminalController.dockAcceptsSurfaceType(.browser, chiefEnabled: false))
        #expect(!TerminalController.dockAcceptsSurfaceType(.notifications, chiefEnabled: true))
    }

    @Test func recentlyClosedHidesChiefOnlyRecordsWhileChiefIsOff() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let mixed = try #require(manager.addWorkspaceIfActive(select: false))
        let pane = try #require(mixed.bonsplitController.allPaneIds.first)
        _ = try #require(mixed.newChiefSurface(inPane: pane, focus: false))
        let home = try #require(ChiefHomeNavigation.ensureHome(in: manager))
        let mixedSnapshot = mixed.sessionSnapshot(includeScrollback: false)
        let homeSnapshot = home.sessionSnapshot(includeScrollback: false)
        #expect(!mixedSnapshot.holdsOnlyChiefPanels)
        #expect(homeSnapshot.holdsOnlyChiefPanels)
        let chiefPanel = try #require(mixedSnapshot.panels.first { $0.type == .chief })
        let terminalPanel = try #require(mixedSnapshot.panels.first { $0.type != .chief })

        let store = ClosedItemHistoryStore(capacity: 100, loadPersisted: false)
        let chiefTab = ClosedItemHistoryRecord(entry: .panel(ClosedPanelHistoryEntry(
            workspaceId: mixed.id, paneId: pane.id, tabIndex: 0, snapshot: chiefPanel
        )))
        let terminalTab = ClosedItemHistoryRecord(entry: .panel(ClosedPanelHistoryEntry(
            workspaceId: mixed.id, paneId: pane.id, tabIndex: 0, snapshot: terminalPanel
        )))
        let homeWorkspace = ClosedItemHistoryRecord(entry: .workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: home.id, windowId: nil, workspaceIndex: 0, snapshot: homeSnapshot
        )))
        let mixedWorkspace = ClosedItemHistoryRecord(entry: .workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: mixed.id, windowId: nil, workspaceIndex: 0, snapshot: mixedSnapshot
        )))
        for record in [terminalTab, mixedWorkspace, chiefTab, homeWorkspace] { store.push(record) }
        #expect(store.menuSnapshot().totalItemCount == 4)

        ChiefSettings.setEnabled(false)
        let offered = Set(store.menuSnapshot().items.map(\.id))
        #expect(offered == [terminalTab.id, mixedWorkspace.id])
        #expect(store.menuSnapshot(maxItemCount: 1).items.map(\.id) == [mixedWorkspace.id])
        // Reopen skips the hidden Chief records instead of trying them first.
        var tried: [UUID] = []
        let reopened = store.restoreFirstRestorable { entry in
            if case .workspace(let workspace) = entry { tried.append(workspace.workspaceId) }
            return true
        }
        #expect(reopened)
        #expect(tried == [mixed.id])
        #expect(store.canReopen)

        ChiefSettings.setEnabled(true)
        #expect(store.menuSnapshot().totalItemCount == 3)
    }

    @Test func reopeningAChiefOnlyWorkspaceAddsNothingWhileChiefIsOff() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let source = TabManager()
        let home = try #require(ChiefHomeNavigation.ensureHome(in: source))
        let entry = ClosedWorkspaceHistoryEntry(
            workspaceId: home.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: home.sessionSnapshot(includeScrollback: false)
        )

        ChiefSettings.setEnabled(false)
        let manager = TabManager()
        let before = manager.tabs.map(\.id)
        let selectedBefore = manager.selectedTabId
        #expect(!manager.restoreClosedWorkspace(entry))
        #expect(manager.tabs.map(\.id) == before)
        #expect(manager.selectedTabId == selectedBefore)
    }

    @Test func reopeningAClosedWorkspaceDropsItsChiefPanesWhileChiefIsOff() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let source = TabManager()
        let mixed = try #require(source.addWorkspaceIfActive(select: false))
        let pane = try #require(mixed.bonsplitController.allPaneIds.first)
        _ = try #require(mixed.newChiefSurface(inPane: pane, focus: false))
        #expect(mixed.panels.values.contains { !($0 is ChiefPanel) })
        let home = try #require(ChiefHomeNavigation.ensureHome(in: source))
        let mixedEntry = ClosedWorkspaceHistoryEntry(
            workspaceId: mixed.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: mixed.sessionSnapshot(includeScrollback: false)
        )
        let homeEntry = ClosedWorkspaceHistoryEntry(
            workspaceId: home.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: home.sessionSnapshot(includeScrollback: false)
        )

        ChiefSettings.setEnabled(false)
        let manager = TabManager()
        let countBefore = manager.tabs.count
        #expect(manager.restoreClosedWorkspace(mixedEntry))
        #expect(manager.tabs.count == countBefore + 1)
        #expect(!manager.restoreClosedWorkspace(homeEntry))
        #expect(manager.tabs.count == countBefore + 1)
        let anyChief = manager.tabs.contains { $0.holdsChiefPane }
        #expect(!anyChief)
    }

    @Test func removeHomeKeepsPanesTheUserAddedToHome() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let home = try #require(ChiefHomeNavigation.ensureHome(in: manager))
        let homePanes = home.panels.values.compactMap { $0 as? ChiefPanel }.filter { $0.isHome }
        let homePane = try #require(homePanes.first)
        let paneId = try #require(home.bonsplitController.focusedPaneId)
        let terminal = try #require(home.newTerminalSurface(inPane: paneId, focus: false))

        ChiefSettings.setEnabled(false)
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(manager.tabs.contains { $0.id == home.id })
        #expect(home.panels[homePane.id] == nil)
        #expect(home.panels[terminal.id] != nil)
        #expect(!home.holdsChiefHomePane)
    }

    @Test func removeHomeKeepsAHomeWorkspaceWithDockPanels() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let home = try #require(ChiefHomeNavigation.ensureHome(in: manager))
        let dock = try #require(home.dockSplit)
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
        let dockPanelID = try #require(dock.newSurface(kind: .terminal, inPane: dockPane, focus: false))

        ChiefSettings.setEnabled(false)
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(manager.tabs.contains { $0.id == home.id })
        #expect(!home.holdsChiefHomePane)
        #expect(home._dockSplit?.panels[dockPanelID] != nil)
    }

    @Test func removeHomeDoesNotHideConversations() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let key = ChiefHomeNavigation.hiddenConversationsKey
        let originalHidden = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(originalHidden, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let manager = TabManager()
        let home = try #require(ChiefHomeNavigation.ensureHome(in: manager))
        let paneId = try #require(home.bonsplitController.focusedPaneId)
        _ = try #require(home.newChiefSurface(inPane: paneId, conversationID: ConversationID("conv_keep"), focus: false))

        ChiefSettings.setEnabled(false)
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(!manager.tabs.contains { $0.id == home.id })
        #expect(UserDefaults.standard.stringArray(forKey: key) == nil)
    }

    @Test func removeHomeLeavesALaterUserPinAlone() throws {
        let setting = ChiefEnabledOverride(true)
        defer { setting.restore() }
        let manager = TabManager()
        let home = try #require(ChiefHomeNavigation.ensureHome(in: manager))
        let groupId = try #require(home.groupId)
        let member = try #require(manager.tabs.first { !$0.holdsChiefHomePane })
        manager.addWorkspaceToGroup(workspaceId: member.id, groupId: groupId)

        ChiefSettings.setEnabled(false)
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.isPinned == false)
        #expect(manager.setWorkspaceGroupPinned(groupId: groupId, isPinned: true))
        ChiefHomeNavigation.removeHome(in: manager)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.isPinned == true)
    }
}
