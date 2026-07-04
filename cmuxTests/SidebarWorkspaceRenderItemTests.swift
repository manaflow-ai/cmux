import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar workspace render items")
struct SidebarWorkspaceRenderItemTests {
    @Test func hiddenGroupAnchorDoesNotRenderGroupHeader() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let childId = originalIds[1]

        let groupId = try #require(manager.createWorkspaceGroup(
            name: "Cross-workstream group",
            childWorkspaceIds: [childId]
        ))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let visibleTabs = manager.tabs.filter { $0.id == childId }
        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: visibleTabs,
            groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        )

        #expect(!visibleTabs.map(\.id).contains(group.anchorWorkspaceId))
        #expect(items.count == 1)
        #expect(items.map(\.rowWorkspaceId) == [childId])
        guard case .workspace(let workspace, let renderGroupId) = try #require(items.first) else {
            Issue.record("Expected the visible child to render as a workspace row")
            return
        }
        #expect(workspace.id == childId)
        #expect(renderGroupId == nil)
        #expect(SidebarWorkspaceRenderItem.workspaceGroupIdsByWorkspaceId(items)[childId] == nil)
    }

    @Test func visibleGroupChildCarriesRenderGroupId() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let childId = manager.tabs[1].id

        let groupId = try #require(manager.createWorkspaceGroup(
            name: "Visible group",
            childWorkspaceIds: [childId]
        ))
        let visibleTabs = manager.tabs.filter { $0.groupId == groupId }
        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: visibleTabs,
            groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        )
        let childItem = try #require(items.first { item in
            if case .workspace(let workspace, _) = item {
                return workspace.id == childId
            }
            return false
        })

        guard case .workspace(let workspace, let renderGroupId) = childItem else {
            Issue.record("Expected the visible child to render as a workspace row")
            return
        }
        #expect(workspace.id == childId)
        #expect(renderGroupId == groupId)
        #expect((SidebarWorkspaceRenderItem.workspaceGroupIdsByWorkspaceId(items)[childId] ?? nil) == groupId)
    }
}
