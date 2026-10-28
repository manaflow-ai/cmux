import AppKit
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
}
