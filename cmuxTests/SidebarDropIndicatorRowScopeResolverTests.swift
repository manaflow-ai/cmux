import Foundation
import Testing

import CmuxFoundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SidebarDropIndicatorRowScopeResolverTests {
    @Test func parentGroupRowsIncludeExpandedChildFolderDescendants() throws {
        let scenario = try makeNestedGroupManager()
        let parent = try #require(scenario.manager.workspaceGroups.first { $0.id == scenario.parentId })
        let child = try #require(scenario.manager.workspaceGroups.first { $0.id == scenario.childId })
        let rowIds = rowIds(manager: scenario.manager, scope: .group(parent.id))
        let childAnchorIndex = try #require(rowIds.firstIndex(of: child.anchorWorkspaceId))
        let childMemberIndex = try #require(rowIds.firstIndex(of: scenario.originalIds[2]))
        let indicator = SidebarDropIndicator(tabId: child.anchorWorkspaceId, edge: .bottom)
        let predicate = SidebarTabDropIndicatorPredicate()

        #expect(childAnchorIndex < childMemberIndex)
        #expect(rowIds.last != child.anchorWorkspaceId)
        #expect(!predicate.bottomVisible(
            forTabId: child.anchorWorkspaceId,
            draggedTabId: scenario.originalIds[0],
            dropIndicator: indicator,
            tabIds: rowIds,
            indicatorScope: .group(parent.id)
        ))
        #expect(predicate.topVisible(
            forTabId: scenario.originalIds[2],
            draggedTabId: scenario.originalIds[0],
            dropIndicator: indicator,
            tabIds: rowIds
        ))
    }

    @Test func parentGroupRowsKeepCollapsedChildFolderAsFinalVisibleRow() throws {
        let scenario = try makeNestedGroupManager()
        let parent = try #require(scenario.manager.workspaceGroups.first { $0.id == scenario.parentId })
        let child = try #require(scenario.manager.workspaceGroups.first { $0.id == scenario.childId })
        scenario.manager.toggleWorkspaceGroupCollapsed(groupId: child.id)
        let rowIds = rowIds(manager: scenario.manager, scope: .group(parent.id))
        let indicator = SidebarDropIndicator(tabId: child.anchorWorkspaceId, edge: .bottom)

        #expect(rowIds.contains(child.anchorWorkspaceId))
        #expect(!rowIds.contains(scenario.originalIds[2]))
        #expect(rowIds.last == child.anchorWorkspaceId)
        #expect(SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: child.anchorWorkspaceId,
            draggedTabId: scenario.originalIds[0],
            dropIndicator: indicator,
            tabIds: rowIds,
            indicatorScope: .group(parent.id)
        ))
    }

    private func makeNestedGroupManager() throws -> (
        manager: TabManager,
        originalIds: [UUID],
        parentId: UUID,
        childId: UUID
    ) {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let parentId = try #require(manager.createWorkspaceGroup(name: "Hotels", childWorkspaceIds: [
            originalIds[1],
        ]))
        let childId = try #require(manager.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [
                originalIds[2],
            ],
            parentGroupId: parentId
        ))
        return (manager, originalIds, parentId, childId)
    }

    private func rowIds(
        manager: TabManager,
        scope: SidebarWorkspaceReorderDropIndicatorScope
    ) -> [UUID] {
        SidebarDropIndicatorRowScopeResolver(
            tabs: manager.tabs,
            workspaceGroups: manager.workspaceGroups,
            workspaceRenderItems: SidebarWorkspaceRenderItem.renderItems(
                tabs: manager.tabs,
                groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
            ),
            topLevelWorkspaceRowIds: []
        ).rowIds(for: scope)
    }
}
