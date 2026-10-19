import Foundation
import Testing
import SwiftUI

import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace group session snapshots", .serialized)
struct WorkspaceGroupSessionSnapshotTests {
    private func makeTabManager() -> TabManager {
        let suiteName = "cmux.workspace-group-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        return manager
    }

    @Test func sessionSnapshotRoundtripPreservesGroups() throws {
        let manager = makeTabManager()
        let child = manager.tabs[0].id
        let nonAnchor = manager.addWorkspace(autoWelcomeIfNeeded: false).id
        let groupId = manager.createWorkspaceGroup(
            name: "Round Trip",
            childWorkspaceIds: [child, nonAnchor],
            externalID: "repo:round-trip"
        )!
        let expandedChild = manager.addWorkspace(autoWelcomeIfNeeded: false).id
        let expandedGroupId = try #require(manager.createWorkspaceGroup(
            name: "Expanded",
            childWorkspaceIds: [expandedChild]
        ))
        manager.toggleWorkspaceGroupPinned(groupId: groupId)
        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        manager.setWorkspaceGroupColor(groupId: groupId, hex: "#123456")
        manager.setWorkspaceGroupIcon(groupId: groupId, symbol: "leaf.fill")

        var snapshot = manager.sessionSnapshot(includeScrollback: false)
        // A saved selection inside a collapsed group must not expand it on restore.
        let selectedIndex = try #require(manager.tabs.firstIndex { $0.id == nonAnchor })
        snapshot.selectedWorkspaceIndex = selectedIndex
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: encoded)
        let groups = try #require(decoded.workspaceGroups)
        let g = try #require(groups.first { $0.id == groupId })
        #expect(g.name == "Round Trip")
        #expect(g.isCollapsed == true)
        #expect(g.isPinned == true)
        #expect(g.customColor == "#123456")
        #expect(g.iconSymbol == "leaf.fill")
        #expect(g.externalID == "repo:round-trip")
        #expect(g.anchorWorkspaceProvenance == WorkspaceGroupAnchorProvenance.user.rawValue)
        #expect(groups.first { $0.id == expandedGroupId }?.isCollapsed == false)

        let restored = TabManager()
        restored.restoreSessionSnapshot(decoded)
        let restoredGroup = try #require(restored.workspaceGroups.first { $0.id == groupId })
        #expect(restoredGroup.name == "Round Trip")
        #expect(restoredGroup.isCollapsed == true)
        #expect(restoredGroup.isPinned == true)
        #expect(restoredGroup.customColor == "#123456")
        #expect(restoredGroup.iconSymbol == "leaf.fill")
        #expect(restoredGroup.externalID == "repo:round-trip")
        #expect(restoredGroup.anchorWorkspaceProvenance == .user)
        #expect(restored.workspaceGroups.first { $0.id == expandedGroupId }?.isCollapsed == false)
        #expect(restored.selectedTabId == restored.tabs[selectedIndex].id)
        #expect(restored.selectedTabId != restoredGroup.anchorWorkspaceId)
    }
}
