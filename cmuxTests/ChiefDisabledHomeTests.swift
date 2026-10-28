import AppKit
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
