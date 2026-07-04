import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar workspace render stale anchors")
struct SidebarWorkspaceRenderItemStaleAnchorTests {
    private func makeTabManager(workspaceCount: Int = 3) -> TabManager {
        let manager = TabManager()
        for _ in 0..<workspaceCount {
            manager.addWorkspace(autoWelcomeIfNeeded: false)
        }
        return manager
    }

    private func renderItems(from manager: TabManager) -> [SidebarWorkspaceRenderItem] {
        SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs,
            groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        )
    }

    @Test func renderItemsPromoteMembersWhenGroupAnchorIsMissing() throws {
        let manager = makeTabManager()
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(name: "Stale", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        manager.tabs.removeAll { $0.id == group.anchorWorkspaceId }
        let items = renderItems(from: manager)
        let renderedGroupIds = items.compactMap { item -> UUID? in
            guard case .groupHeader(let group, _, _) = item else { return nil }
            return group.id
        }
        let workspaceRows = items.compactMap { item -> (UUID, Int)? in
            guard case .workspace(let workspace, let depth) = item else { return nil }
            return (workspace.id, depth)
        }

        #expect(!renderedGroupIds.contains(groupId))
        #expect(workspaceRows.contains { id, depth in id == originalIds[1] && depth == 0 })
        #expect(workspaceRows.contains { id, depth in id == originalIds[2] && depth == 0 })
    }

    @Test func renderItemsPromoteNestedChildGroupWhenParentAnchorIsMissing() throws {
        let manager = makeTabManager()
        let originalIds = manager.tabs.map(\.id)
        let parentId = try #require(manager.createWorkspaceGroup(name: "Parent", childWorkspaceIds: [
            originalIds[0],
        ]))
        let childId = try #require(manager.createWorkspaceGroup(
            name: "Child",
            childWorkspaceIds: [
                originalIds[1],
            ],
            parentGroupId: parentId
        ))
        let parent = try #require(manager.workspaceGroups.first { $0.id == parentId })

        manager.tabs.removeAll { $0.id == parent.anchorWorkspaceId }
        let items = renderItems(from: manager)
        let groupRows = items.compactMap { item -> (UUID, Int)? in
            guard case .groupHeader(let group, _, let depth) = item else { return nil }
            return (group.id, depth)
        }
        let workspaceRows = items.compactMap { item -> (UUID, Int)? in
            guard case .workspace(let workspace, let depth) = item else { return nil }
            return (workspace.id, depth)
        }

        #expect(!groupRows.contains { id, _ in id == parentId })
        #expect(groupRows.contains { id, depth in id == childId && depth == 0 })
        #expect(workspaceRows.contains { id, depth in id == originalIds[0] && depth == 0 })
        #expect(workspaceRows.contains { id, depth in id == originalIds[1] && depth == 1 })
    }
}
