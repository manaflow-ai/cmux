import Foundation
import Testing

import CmuxFoundation
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace group model")
struct WorkspaceGroupTests {

    private func makeTabManager() -> TabManager {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        return manager
    }

    @Test func createGroupInsertsFreshAnchorAndGroupsChildren() throws {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let initialCount = manager.tabs.count

        let gid = manager.createWorkspaceGroup(name: "Test Group", childWorkspaceIds: children)
        #expect(gid != nil)
        #expect(manager.tabs.count == initialCount + 1)
        let groupId = try #require(gid)
        let group = try #require(manager.workspaceGroups.first(where: { $0.id == groupId }))
        #expect(group.name == "Test Group")
        #expect(!group.isCollapsed)
        #expect(!group.isPinned)
        #expect(manager.tabs.contains(where: { $0.id == group.anchorWorkspaceId }))

        let membersIds = manager.tabs.filter { $0.groupId == groupId }.map(\.id)
        #expect(membersIds.count == children.count + 1)
        #expect(membersIds.contains(group.anchorWorkspaceId))
        for childId in children {
            #expect(membersIds.contains(childId))
        }
    }

    @Test func createEmptyGroupInsertsAnchorOnlyGroup() throws {
        let manager = makeTabManager()
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: ""))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        #expect(group.name == "Group 1")
        #expect(manager.tabs.map(\.id) == [group.anchorWorkspaceId] + originalIds)
        #expect(manager.tabs.filter { $0.groupId == groupId }.map(\.id) == [group.anchorWorkspaceId])
        #expect(manager.selectedTabId == group.anchorWorkspaceId)
    }

    @Test func createGroupKeepsFirstChildPosition() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let children = Array(originalIds.suffix(2))

        let groupId = try #require(manager.createWorkspaceGroup(name: "Lower", childWorkspaceIds: children))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let reorderedIds = manager.tabs.map(\.id)

        #expect(reorderedIds[0] == originalIds[0])
        #expect(reorderedIds[1] == originalIds[1])
        #expect(reorderedIds[2] == group.anchorWorkspaceId)
        #expect(reorderedIds[3] == originalIds[2])
        #expect(reorderedIds[4] == originalIds[3])
    }

    @Test func draggingGroupHeaderReordersAmongTopLevelWorkspaces() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Middle", childWorkspaceIds: [originalIds[1]]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        #expect(manager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: group.anchorWorkspaceId) == [
            originalIds[0],
            group.anchorWorkspaceId,
            originalIds[2],
            originalIds[3],
        ])

        let moved = manager.reorderSidebarWorkspace(
            tabId: group.anchorWorkspaceId,
            toIndex: 2,
            isDragOperation: true
        )

        #expect(moved)
        #expect(manager.tabs.map(\.id) == [
            originalIds[0],
            originalIds[2],
            group.anchorWorkspaceId,
            originalIds[1],
            originalIds[3],
        ])
    }

    @Test func draggingWorkspaceAfterCollapsedGroupHeaderKeepsWorkspaceTopLevel() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Collapsed", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let reorderIds = manager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: originalIds[0],
            targetWorkspaceId: group.anchorWorkspaceId
        )
        let pinnedIds = manager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: originalIds[0],
            targetWorkspaceId: group.anchorWorkspaceId
        )
        let targetIndex = try #require(SidebarDropPlanner().targetIndex(
            draggedTabId: originalIds[0],
            targetTabId: group.anchorWorkspaceId,
            indicator: SidebarDropIndicator(tabId: group.anchorWorkspaceId, edge: .bottom),
            tabIds: reorderIds,
            pinnedTabIds: pinnedIds
        ))
        let moved = manager.reorderSidebarWorkspace(
            tabId: originalIds[0],
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: manager.sidebarReorderUsesTopLevelRows(
                forDraggedWorkspaceId: originalIds[0],
                targetWorkspaceId: group.anchorWorkspaceId
            )
        )

        #expect(moved)
        #expect(manager.tabs.first { $0.id == originalIds[0] }?.groupId == nil)
        #expect(manager.tabs.map(\.id) == [
            group.anchorWorkspaceId,
            originalIds[1],
            originalIds[2],
            originalIds[0],
            originalIds[3],
        ])
    }

    @Test func topLevelReorderPinnedClampReportsNoMove() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let pinnedWorkspace = try #require(manager.tabs.first { $0.id == originalIds[0] })
        manager.setPinned(pinnedWorkspace, pinned: true)
        let orderBefore = manager.tabs.map(\.id)

        let moved = manager.reorderSidebarWorkspace(
            tabId: originalIds[1],
            toIndex: 0,
            isDragOperation: true,
            usesTopLevelRows: true
        )

        #expect(!moved)
        #expect(manager.tabs.map(\.id) == orderBefore)
    }

    @Test func collapsedGroupRenderItemCarriesMemberCountWithoutRenderingChildren() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Collapsed", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs,
            groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        )

        var groupMemberCount = 0
        var visibleWorkspaceIds: [UUID] = []
        var visibleRowIds: [UUID] = []
        for item in items {
            visibleRowIds.append(item.rowWorkspaceId)
            switch item {
            case .groupHeader(let renderedGroup, let memberCount, _) where renderedGroup.id == groupId:
                groupMemberCount = memberCount
            case .groupHeader:
                break
            case .workspace(let workspace, _):
                visibleWorkspaceIds.append(workspace.id)
            }
        }

        #expect(groupMemberCount == 3)
        #expect(!visibleWorkspaceIds.contains(originalIds[1]))
        #expect(!visibleWorkspaceIds.contains(originalIds[2]))
        #expect(visibleRowIds == [
            originalIds[0],
            group.anchorWorkspaceId,
            originalIds[3],
        ])
    }

    @Test func renderItemsShowWorkspaceWithStaleGroupIdAsRootRow() {
        let manager = makeTabManager()
        let staleGroupId = UUID()
        let staleWorkspaceId = manager.tabs[0].id
        manager.tabs[0].groupId = staleGroupId

        let items = SidebarWorkspaceRenderItem.renderItems(tabs: manager.tabs, groupsById: [:])
        let visibleWorkspaceRows = items.compactMap { item -> (UUID, Int)? in
            guard case .workspace(let workspace, let depth) = item else { return nil }
            return (workspace.id, depth)
        }

        #expect(visibleWorkspaceRows.contains { id, depth in id == staleWorkspaceId && depth == 0 })
        #expect(items.first?.rowWorkspaceId == staleWorkspaceId)
    }

    @Test func nestedGroupRenderItemsRecurseWithDepthAndMixedLooseWorkspaces() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let hotelsId = try #require(manager.createWorkspaceGroup(name: "Hotels", childWorkspaceIds: [
            originalIds[1],
        ]))
        let marriottId = try #require(manager.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [
                originalIds[2],
            ],
            parentGroupId: hotelsId
        ))
        let hotels = try #require(manager.workspaceGroups.first { $0.id == hotelsId })
        let marriott = try #require(manager.workspaceGroups.first { $0.id == marriottId })
        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs,
            groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        )

        let projected = items.map { item -> (SidebarWorkspaceRenderItemID, UUID, Int) in
            (item.id, item.rowWorkspaceId, item.depth)
        }

        #expect(projected.contains(where: { $0 == (.group(hotelsId), hotels.anchorWorkspaceId, 0) }))
        #expect(projected.contains(where: { $0 == (.workspace(originalIds[1]), originalIds[1], 1) }))
        #expect(projected.contains(where: { $0 == (.group(marriottId), marriott.anchorWorkspaceId, 1) }))
        #expect(projected.contains(where: { $0 == (.workspace(originalIds[2]), originalIds[2], 2) }))
    }

    @Test func collapsedParentGroupRenderItemHidesDescendantFolderRows() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let hotelsId = try #require(manager.createWorkspaceGroup(name: "Hotels", childWorkspaceIds: [
            originalIds[1],
        ]))
        let marriottId = try #require(manager.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [
                originalIds[2],
            ],
            parentGroupId: hotelsId
        ))
        manager.toggleWorkspaceGroupCollapsed(groupId: hotelsId)
        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs,
            groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        )
        let groupIds = items.compactMap { item -> UUID? in
            guard case .groupHeader(let group, _, _) = item else { return nil }
            return group.id
        }
        let visibleWorkspaceIds = items.compactMap { item -> UUID? in
            guard case .workspace(let workspace, _) = item else { return nil }
            return workspace.id
        }

        #expect(groupIds.contains(hotelsId))
        #expect(!groupIds.contains(marriottId))
        #expect(!visibleWorkspaceIds.contains(originalIds[1]))
        #expect(!visibleWorkspaceIds.contains(originalIds[2]))
    }

    @Test func nestedGroupHeaderDoesNotUseRootTopLevelReorderSpace() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let parentId = try #require(manager.createWorkspaceGroup(name: "Hotels", childWorkspaceIds: [originalIds[0]]))
        let childId = try #require(manager.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [originalIds[1]],
            parentGroupId: parentId
        ))
        let parentAnchorId = try #require(manager.workspaceGroups.first { $0.id == parentId }?.anchorWorkspaceId)
        let childAnchorId = try #require(manager.workspaceGroups.first { $0.id == childId }?.anchorWorkspaceId)

        #expect(manager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: parentAnchorId,
            targetWorkspaceId: nil
        ))
        #expect(!manager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: childAnchorId,
            targetWorkspaceId: nil
        ))
    }

    @Test func droppingNestedGroupToRootEndPromotesWhenPlannedIndexIsUnchanged() throws {
        let manager = makeTabManager()
        let originalIds = manager.tabs.map(\.id)

        let parentId = try #require(manager.createWorkspaceGroup(name: "Hotels", childWorkspaceIds: [originalIds[0]]))
        let childId = try #require(manager.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [originalIds[1]],
            parentGroupId: parentId
        ))
        let childAnchorId = try #require(manager.workspaceGroups.first { $0.id == childId }?.anchorWorkspaceId)
        let usesTopLevelRows = manager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: childAnchorId,
            targetWorkspaceId: nil
        )
        let reorderIds = manager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: childAnchorId,
            targetWorkspaceId: nil,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedIds = manager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: childAnchorId,
            targetWorkspaceId: nil,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = manager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: childAnchorId,
            targetWorkspaceId: nil,
            usesTopLevelRows: usesTopLevelRows
        )
        let fromIndex = try #require(reorderIds.firstIndex(of: childAnchorId))
        let targetIndex = try #require(SidebarDropPlanner().targetIndex(
            draggedTabId: childAnchorId,
            targetTabId: nil,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
            tabIds: reorderIds,
            pinnedTabIds: pinnedIds,
            legalInsertionRange: legalInsertionRange
        ))

        #expect(usesTopLevelRows)
        #expect(targetIndex == fromIndex)
        #expect(manager.reorderSidebarWorkspace(
            tabId: childAnchorId,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: usesTopLevelRows
        ))
        #expect(manager.workspaceGroups.first { $0.id == childId }?.parentGroupId == nil)
    }

    @Test func groupHeaderEdgeDropUsesTopLevelIndicatorScope() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Collapsed", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let fullRowIds = manager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: originalIds[0])
        let headerTargetIds = manager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: originalIds[0],
            targetWorkspaceId: group.anchorWorkspaceId
        )
        let forcedTopLevelIds = manager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: originalIds[0],
            usesTopLevelRows: true
        )
        let indicator = SidebarDropIndicator(tabId: group.anchorWorkspaceId, edge: .bottom)

        #expect(headerTargetIds == [
            originalIds[0],
            group.anchorWorkspaceId,
            originalIds[3],
        ] + Array(originalIds.dropFirst(4)))
        #expect(forcedTopLevelIds == headerTargetIds)
        #expect(!SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: group.anchorWorkspaceId,
            draggedTabId: originalIds[0],
            dropIndicator: indicator,
            tabIds: forcedTopLevelIds,
            indicatorScope: .topLevel
        ))
        #expect(SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: originalIds[3],
            draggedTabId: originalIds[0],
            dropIndicator: indicator,
            tabIds: forcedTopLevelIds
        ))
        #expect(fullRowIds.contains(group.anchorWorkspaceId))
    }

    @Test func draggingGroupedChildAboveItsGroupPromotesToTopLevel() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Lower", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let draggedId = originalIds[1]
        let targetId = originalIds[0]
        let usesTopLevelRows = manager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedId,
            targetWorkspaceId: targetId
        )
        let reorderIds = manager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedId,
            targetWorkspaceId: targetId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedIds = manager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedId,
            targetWorkspaceId: targetId,
            usesTopLevelRows: usesTopLevelRows
        )
        let targetIndex = try #require(SidebarDropPlanner().targetIndex(
            draggedTabId: draggedId,
            targetTabId: targetId,
            indicator: SidebarDropIndicator(tabId: group.anchorWorkspaceId, edge: .top),
            tabIds: reorderIds,
            pinnedTabIds: pinnedIds
        ))

        let moved = manager.reorderSidebarWorkspace(
            tabId: draggedId,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: usesTopLevelRows
        )

        #expect(moved)
        #expect(manager.tabs.first { $0.id == draggedId }?.groupId == nil)
        #expect(manager.tabs.map(\.id) == [
            originalIds[0],
            draggedId,
            group.anchorWorkspaceId,
            originalIds[2],
            originalIds[3],
        ])
    }

    @Test func draggingGroupedChildToRootSlotAfterOwnGroupPromotesToTopLevel() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Middle", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let draggedId = originalIds[1]
        let rootAfterGroupId = originalIds[3]
        let reorderIds = manager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedId,
            targetWorkspaceId: rootAfterGroupId,
            usesTopLevelRows: true
        )
        let pinnedIds = manager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedId,
            targetWorkspaceId: rootAfterGroupId,
            usesTopLevelRows: true
        )
        let targetIndex = try #require(SidebarDropPlanner().targetIndex(
            draggedTabId: draggedId,
            targetTabId: rootAfterGroupId,
            indicator: SidebarDropIndicator(tabId: rootAfterGroupId, edge: .top),
            tabIds: reorderIds,
            pinnedTabIds: pinnedIds
        ))

        let moved = manager.reorderSidebarWorkspace(
            tabId: draggedId,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: true
        )

        #expect(moved)
        #expect(manager.tabs.first { $0.id == draggedId }?.groupId == nil)
        #expect(manager.tabs.filter { $0.groupId == groupId }.map(\.id) == [
            group.anchorWorkspaceId,
            originalIds[2],
        ])
        #expect(manager.tabs.map(\.id) == [
            originalIds[0],
            group.anchorWorkspaceId,
            originalIds[2],
            draggedId,
            rootAfterGroupId,
        ] + Array(originalIds.dropFirst(4)))
    }

    @Test func draggingPinnedGroupedChildToRootSlotAfterOwnUnpinnedGroupPromotesToPinnedTier() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Middle", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let draggedId = originalIds[1]
        let rootAfterGroupId = originalIds[3]
        manager.setPinned(try #require(manager.tabs.first { $0.id == draggedId }), pinned: true)
        let reorderIds = manager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedId,
            targetWorkspaceId: rootAfterGroupId,
            usesTopLevelRows: true
        )
        let pinnedIds = manager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedId,
            targetWorkspaceId: rootAfterGroupId,
            usesTopLevelRows: true
        )
        #expect(reorderIds == [
            draggedId,
            originalIds[0],
            group.anchorWorkspaceId,
            rootAfterGroupId,
        ] + Array(originalIds.dropFirst(4)))
        #expect(pinnedIds == [draggedId])
        let targetIndex = try #require(SidebarDropPlanner().targetIndex(
            draggedTabId: draggedId,
            targetTabId: rootAfterGroupId,
            indicator: SidebarDropIndicator(tabId: rootAfterGroupId, edge: .top),
            tabIds: reorderIds,
            pinnedTabIds: pinnedIds
        ))
        #expect(targetIndex == 0)

        let moved = manager.reorderSidebarWorkspace(
            tabId: draggedId,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: true
        )

        #expect(moved)
        #expect(manager.tabs.first { $0.id == draggedId }?.groupId == nil)
        #expect(manager.tabs.map(\.id) == [
            draggedId,
            originalIds[0],
            group.anchorWorkspaceId,
            originalIds[2],
            rootAfterGroupId,
        ] + Array(originalIds.dropFirst(4)))
    }

    @Test func createUnpinnedGroupFromPinnedGroupChildStaysBelowPinnedGroups() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let firstPinnedId = try #require(manager.createWorkspaceGroup(name: "Pinned A", childWorkspaceIds: [originalIds[1]]))
        manager.toggleWorkspaceGroupPinned(groupId: firstPinnedId)
        let secondPinnedId = try #require(manager.createWorkspaceGroup(name: "Pinned B", childWorkspaceIds: [originalIds[2]]))
        manager.toggleWorkspaceGroupPinned(groupId: secondPinnedId)

        let newGroupId = try #require(manager.createWorkspaceGroup(name: "Unpinned", childWorkspaceIds: [originalIds[1]]))
        let newGroup = try #require(manager.workspaceGroups.first { $0.id == newGroupId })
        let pinnedGroupIds = Set(manager.workspaceGroups.filter(\.isPinned).map(\.id))
        let lastPinnedIndex = try #require(manager.tabs.lastIndex { tab in
            tab.groupId.map { pinnedGroupIds.contains($0) } ?? false
        })
        let newGroupIndex = try #require(manager.tabs.firstIndex { $0.id == newGroup.anchorWorkspaceId })

        #expect(newGroupIndex > lastPinnedIndex)
    }

    @Test func movingGroupedChildToTopKeepsAnchorFirstWhenGroupIsAlreadyFirst() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "First", childWorkspaceIds: [
            originalIds[0],
            originalIds[1],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        manager.moveTabToTop(originalIds[1])

        #expect(manager.tabs.map(\.id) == [
            group.anchorWorkspaceId,
            originalIds[1],
            originalIds[0],
            originalIds[2],
        ])
    }

    @Test func movingUnpinnedGroupedChildToTopKeepsPinnedGroupFirst() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let pinnedGroupId = try #require(manager.createWorkspaceGroup(name: "Pinned", childWorkspaceIds: [originalIds[2]]))
        manager.toggleWorkspaceGroupPinned(groupId: pinnedGroupId)
        let pinnedGroup = try #require(manager.workspaceGroups.first { $0.id == pinnedGroupId })

        let unpinnedGroupId = try #require(manager.createWorkspaceGroup(name: "Unpinned", childWorkspaceIds: [
            originalIds[0],
            originalIds[1],
        ]))
        let unpinnedGroup = try #require(manager.workspaceGroups.first { $0.id == unpinnedGroupId })

        manager.moveTabToTop(originalIds[1])

        #expect(Array(manager.tabs.map(\.id).prefix(3)) == [
            pinnedGroup.anchorWorkspaceId,
            originalIds[2],
            unpinnedGroup.anchorWorkspaceId,
        ])
    }

    @Test func movingPinnedGroupedChildToTopUsesGroupPinTier() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let pinnedWorkspace = try #require(manager.tabs.first { $0.id == originalIds[0] })
        manager.setPinned(pinnedWorkspace, pinned: true)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Pinned Group", childWorkspaceIds: [
            originalIds[2],
        ]))
        manager.toggleWorkspaceGroupPinned(groupId: groupId)
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        manager.moveTabToTop(originalIds[2])

        #expect(Array(manager.tabs.map(\.id).prefix(3)) == [
            group.anchorWorkspaceId,
            originalIds[2],
            originalIds[0],
        ])
    }

    @Test func movingPinnedGroupedSelectionToTopUsesGroupPinTier() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let pinnedWorkspace = try #require(manager.tabs.first { $0.id == originalIds[0] })
        manager.setPinned(pinnedWorkspace, pinned: true)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Pinned Group", childWorkspaceIds: [
            originalIds[2],
        ]))
        manager.toggleWorkspaceGroupPinned(groupId: groupId)
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        manager.moveTabsToTop([originalIds[2]])

        #expect(Array(manager.tabs.map(\.id).prefix(3)) == [
            group.anchorWorkspaceId,
            originalIds[2],
            originalIds[0],
        ])
    }

    @Test func pinningGroupedWorkspaceKeepsItAtTopOfGroup() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
            originalIds[3],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let pinnedChild = try #require(manager.tabs.first { $0.id == originalIds[3] })

        manager.setPinned(pinnedChild, pinned: true)

        #expect(pinnedChild.groupId == groupId)
        #expect(manager.tabs.filter { $0.groupId == groupId }.map(\.id) == [
            group.anchorWorkspaceId,
            originalIds[3],
            originalIds[1],
            originalIds[2],
        ])
    }

    @Test func pinnedGroupedWorkspaceDoesNotPromoteUnpinnedGroup() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let globallyPinned = try #require(manager.tabs.first { $0.id == originalIds[0] })
        manager.setPinned(globallyPinned, pinned: true)

        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            originalIds[2],
            originalIds[3],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let pinnedChild = try #require(manager.tabs.first { $0.id == originalIds[3] })

        manager.setPinned(pinnedChild, pinned: true)

        #expect(manager.tabs.map(\.id) == [
            originalIds[0],
            originalIds[1],
            group.anchorWorkspaceId,
            originalIds[3],
            originalIds[2],
        ])
        #expect(!group.isPinned)
        #expect(pinnedChild.groupId == groupId)
    }

    @Test func draggingUnpinnedGroupedWorkspaceAbovePinnedGroupedWorkspaceShowsNoIndicator() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
            originalIds[3],
        ]))
        let pinnedChild = try #require(manager.tabs.first { $0.id == originalIds[2] })
        manager.setPinned(pinnedChild, pinned: true)

        let draggedUnpinnedId = originalIds[3]
        let tabIds = manager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedUnpinnedId,
            targetWorkspaceId: pinnedChild.id
        )
        let pinnedIds = manager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedUnpinnedId,
            targetWorkspaceId: pinnedChild.id
        )
        let legalInsertionRange = manager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedUnpinnedId,
            targetWorkspaceId: pinnedChild.id
        )

        #expect(manager.tabs.first { $0.id == draggedUnpinnedId }?.groupId == groupId)
        let indicator = SidebarDropPlanner().indicator(
            draggedTabId: draggedUnpinnedId,
            targetTabId: pinnedChild.id,
            tabIds: tabIds,
            pinnedTabIds: pinnedIds,
            legalInsertionRange: legalInsertionRange,
            pointerY: 2,
            targetHeight: 40
        )
        #expect(indicator == nil)
        #expect(SidebarDropPlanner().targetIndex(
            draggedTabId: draggedUnpinnedId,
            targetTabId: pinnedChild.id,
            indicator: SidebarDropIndicator(tabId: pinnedChild.id, edge: .top),
            tabIds: tabIds,
            pinnedTabIds: pinnedIds,
            legalInsertionRange: legalInsertionRange
        ) == tabIds.firstIndex(of: draggedUnpinnedId))
    }

    @Test func movingGroupMemberToTopKeepsScriptableGroupOrderInVisibleOrder() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let firstGroupId = try #require(manager.createWorkspaceGroup(name: "First", childWorkspaceIds: [originalIds[0]]))
        let firstGroup = try #require(manager.workspaceGroups.first { $0.id == firstGroupId })
        let secondGroupId = try #require(manager.createWorkspaceGroup(name: "Second", childWorkspaceIds: [originalIds[2]]))
        let secondGroup = try #require(manager.workspaceGroups.first { $0.id == secondGroupId })

        manager.moveTabToTopForNotification(originalIds[2])

        #expect(Array(manager.tabs.map(\.id).prefix(4)) == [
            secondGroup.anchorWorkspaceId,
            originalIds[2],
            firstGroup.anchorWorkspaceId,
            originalIds[0],
        ])
        #expect(Array(manager.workspaceGroups.map(\.id).prefix(2)) == [
            secondGroupId,
            firstGroupId,
        ])
    }

    @Test func addingWorkspaceToGroupPreservesGroupTopLevelPosition() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Middle", childWorkspaceIds: [originalIds[1]]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        manager.addWorkspaceToGroup(workspaceId: originalIds[3], groupId: groupId)

        #expect(manager.tabs.map(\.id) == [
            originalIds[0],
            group.anchorWorkspaceId,
            originalIds[1],
            originalIds[3],
            originalIds[2],
        ])
    }

    @Test func addingWorkspaceAboveGroupPreservesGroupTopLevelPosition() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "Lower", childWorkspaceIds: [originalIds[2]]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        manager.addWorkspaceToGroup(workspaceId: originalIds[0], groupId: groupId)

        #expect(manager.tabs.map(\.id) == [
            originalIds[1],
            group.anchorWorkspaceId,
            originalIds[0],
            originalIds[2],
            originalIds[3],
        ])
    }

    @Test func createWorkspaceInGroupAfterCurrentPlacesAfterReferenceMember() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
            originalIds[3],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        let inserted = try #require(manager.createWorkspaceInGroup(
            groupId: groupId,
            placement: .afterCurrent,
            referenceWorkspaceId: originalIds[2],
            select: false
        ))

        #expect(inserted.groupId == groupId)
        #expect(manager.tabs.filter { $0.groupId == groupId }.map(\.id) == [
            group.anchorWorkspaceId,
            originalIds[1],
            originalIds[2],
            inserted.id,
            originalIds[3],
        ])
    }

    @Test func createWorkspaceInGroupAfterCurrentAnchorReferenceFallsBackToTop() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        let inserted = try #require(manager.createWorkspaceInGroup(
            groupId: groupId,
            placement: .afterCurrent,
            referenceWorkspaceId: group.anchorWorkspaceId,
            select: false
        ))

        #expect(manager.tabs.filter { $0.groupId == groupId }.map(\.id) == [
            group.anchorWorkspaceId,
            inserted.id,
            originalIds[1],
            originalIds[2],
        ])
    }

    @Test func addingExistingWorkspaceToGroupHonorsPlacementReference() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)

        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        manager.addWorkspaceToGroup(
            workspaceId: originalIds[0],
            groupId: groupId,
            placement: .afterCurrent,
            referenceWorkspaceId: originalIds[1]
        )

        #expect(manager.tabs.filter { $0.groupId == groupId }.map(\.id) == [
            group.anchorWorkspaceId,
            originalIds[1],
            originalIds[0],
            originalIds[2],
        ])
    }

    @Test(arguments: [
        ("afterCurrent", WorkspaceGroupNewPlacement?.some(.afterCurrent)),
        ("after-current", WorkspaceGroupNewPlacement?.some(.afterCurrent)),
        ("after_current", WorkspaceGroupNewPlacement?.some(.afterCurrent)),
        ("top", WorkspaceGroupNewPlacement?.some(.top)),
        ("end", WorkspaceGroupNewPlacement?.some(.end)),
        ("middle", nil),
    ])
    func workspaceGroupNewPlacementParsesConfigSpellings(
        input: String,
        expected: WorkspaceGroupNewPlacement?
    ) {
        #expect(WorkspaceGroupNewPlacement(rawString: input) == expected)
    }

    @Test func removeNonAnchorPreservesGroup() {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        let firstChild = children[0]

        manager.removeWorkspaceFromGroup(workspaceId: firstChild)

        #expect(manager.workspaceGroups.first(where: { $0.id == groupId }) != nil)
        #expect(manager.tabs.first(where: { $0.id == firstChild })?.groupId == nil)
    }

    @Test func removeAnchorViaRemoveWorkspaceFromGroupDissolves() throws {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        let group = try #require(manager.workspaceGroups.first(where: { $0.id == groupId }))

        manager.removeWorkspaceFromGroup(workspaceId: group.anchorWorkspaceId)

        #expect(manager.workspaceGroups.first(where: { $0.id == groupId }) == nil)
        #expect(manager.tabs.allSatisfy { $0.groupId == nil })
    }

    @Test func closingAnchorWorkspaceDissolvesGroup() throws {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        let anchorCloseKey = SettingCatalog().workspaceGroups.anchorCloseSuppressed
        let settings = UserDefaultsSettingsClient(defaults: .standard)
        settings.set(true, for: anchorCloseKey)
        defer { settings.reset(anchorCloseKey) }
        let group = try #require(manager.workspaceGroups.first(where: { $0.id == groupId }))
        let anchor = try #require(manager.tabs.first(where: { $0.id == group.anchorWorkspaceId }))

        manager.closeWorkspace(anchor)

        #expect(!manager.tabs.contains(where: { $0.id == anchor.id }))
        #expect(manager.workspaceGroups.first(where: { $0.id == groupId }) == nil)
        #expect(manager.tabs.allSatisfy { $0.groupId == nil })
    }

    @Test func ungroupKeepsAllWorkspaces() {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        let allIdsBefore = Set(manager.tabs.map(\.id))

        manager.ungroupWorkspaceGroup(groupId: groupId)

        #expect(manager.workspaceGroups.first(where: { $0.id == groupId }) == nil)
        #expect(Set(manager.tabs.map(\.id)) == allIdsBefore)
        #expect(manager.tabs.allSatisfy { $0.groupId == nil })
    }

    @Test func deleteClosesMembersAndRemovesGroup() {
        let manager = makeTabManager()
        // Add an outsider so closeWorkspace's `tabs.count <= 1` guard never fires.
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let groupChildren = Array(manager.tabs.prefix(2)).map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: groupChildren)!
        let memberIdsBefore = Set(manager.tabs.filter { $0.groupId == groupId }.map(\.id))
        #expect(!memberIdsBefore.isEmpty)

        let closed = manager.deleteWorkspaceGroup(groupId: groupId)

        #expect(closed == memberIdsBefore.count)
        #expect(manager.workspaceGroups.first(where: { $0.id == groupId }) == nil)
        #expect(memberIdsBefore.allSatisfy { id in
            !manager.tabs.contains(where: { $0.id == id })
        })
    }

    @Test func deleteKeepsLastWorkspaceUngrouped() {
        // When the group contains every workspace in the window,
        // closeWorkspace refuses to drop the last tab. The lingering tab must
        // be detached from the group so the user isn't left with a stale
        // groupId pointing at a removed group.
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        let groupSize = manager.tabs.filter { $0.groupId == groupId }.count

        let closed = manager.deleteWorkspaceGroup(groupId: groupId)

        #expect(manager.tabs.count == 1)
        #expect(closed == groupSize - 1)
        #expect(manager.workspaceGroups.first(where: { $0.id == groupId }) == nil)
        #expect(manager.tabs.allSatisfy { $0.groupId == nil })
    }

    @Test func pinnedWorkspaceCannotJoinGroupViaCreate() {
        let manager = makeTabManager()
        let pinnedWs = manager.tabs[0]
        manager.setPinned(pinnedWs, pinned: true)

        let unpinnedWs = manager.tabs.first(where: { !$0.isPinned })!
        let groupId = manager.createWorkspaceGroup(
            name: "Mixed",
            childWorkspaceIds: [pinnedWs.id, unpinnedWs.id]
        )
        #expect(groupId != nil)
        #expect(pinnedWs.groupId == nil)
        #expect(unpinnedWs.groupId == groupId)
    }

    @Test func toggleCollapsedAndPinned() {
        let manager = makeTabManager()
        let groupId = manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [manager.tabs[0].id]
        )!

        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.isCollapsed == true)
        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.isCollapsed == false)

        manager.toggleWorkspaceGroupPinned(groupId: groupId)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.isPinned == true)
    }

    @Test func setAnchorRequiresMember() {
        let manager = makeTabManager()
        let memberId = manager.tabs[0].id
        let outsiderId = manager.tabs[1].id
        let groupId = manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [memberId]
        )!
        let originalAnchor = manager.workspaceGroups.first { $0.id == groupId }!.anchorWorkspaceId

        manager.setWorkspaceGroupAnchor(groupId: groupId, workspaceId: outsiderId)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId == originalAnchor)

        manager.setWorkspaceGroupAnchor(groupId: groupId, workspaceId: memberId)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId == memberId)
    }

    @Test func sessionSnapshotRoundtripPreservesGroups() throws {
        let manager = makeTabManager()
        let child = manager.tabs[0].id
        let groupId = manager.createWorkspaceGroup(name: "Round Trip", childWorkspaceIds: [child])!
        manager.toggleWorkspaceGroupPinned(groupId: groupId)
        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        manager.setWorkspaceGroupColor(groupId: groupId, hex: "#123456")
        manager.setWorkspaceGroupIcon(groupId: groupId, symbol: "leaf.fill")

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let groups = try #require(snapshot.workspaceGroups)
        let g = try #require(groups.first { $0.id == groupId })
        #expect(g.name == "Round Trip")
        #expect(g.isCollapsed == true)
        #expect(g.isPinned == true)
        #expect(g.customColor == "#123456")
        #expect(g.iconSymbol == "leaf.fill")

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)
        let restoredGroup = try #require(restored.workspaceGroups.first { $0.id == groupId })
        #expect(restoredGroup.name == "Round Trip")
        #expect(restoredGroup.isCollapsed == true)
        #expect(restoredGroup.isPinned == true)
        #expect(restoredGroup.customColor == "#123456")
        #expect(restoredGroup.iconSymbol == "leaf.fill")
    }

    @Test func sessionSnapshotRoundtripPreservesNestedGroupParent() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let parentId = try #require(manager.createWorkspaceGroup(name: "Hotels", childWorkspaceIds: [originalIds[0]]))
        let childId = try #require(manager.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [originalIds[1]],
            parentGroupId: parentId
        ))

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let groups = try #require(snapshot.workspaceGroups)
        let childSnapshot = try #require(groups.first { $0.id == childId })
        #expect(childSnapshot.parentGroupId == parentId)
        #expect(childSnapshot.parentGroupIndex == groups.firstIndex { $0.id == parentId })

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)
        #expect(restored.workspaceGroups.first { $0.id == childId }?.parentGroupId == parentId)
    }

    @Test func sessionSnapshotRestoreUsesParentGroupIndexFallback() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let parentId = try #require(manager.createWorkspaceGroup(name: "Hotels", childWorkspaceIds: [originalIds[0]]))
        let childId = try #require(manager.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [originalIds[1]],
            parentGroupId: parentId
        ))
        var snapshot = manager.sessionSnapshot(includeScrollback: false)
        var groups = try #require(snapshot.workspaceGroups)
        let parentIndex = try #require(groups.firstIndex { $0.id == parentId })
        let childIndex = try #require(groups.firstIndex { $0.id == childId })
        groups[childIndex].parentGroupId = nil
        groups[childIndex].parentGroupIndex = parentIndex
        snapshot.workspaceGroups = groups

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        #expect(restored.workspaceGroups.first { $0.id == childId }?.parentGroupId == parentId)
    }

    @Test func sessionSnapshotRestoreRelinksGrandchildToNearestSurvivingAncestor() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let grandparentId = try #require(manager.createWorkspaceGroup(
            name: "Hotels",
            childWorkspaceIds: [originalIds[0]]
        ))
        let parentId = try #require(manager.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [originalIds[1]],
            parentGroupId: grandparentId
        ))
        let childId = try #require(manager.createWorkspaceGroup(
            name: "Downtown",
            childWorkspaceIds: [originalIds[2]],
            parentGroupId: parentId
        ))

        var snapshot = manager.sessionSnapshot(includeScrollback: false)
        // Drop the intermediate folder by removing its only member workspace, so
        // it has nothing to restore. The surviving grandchild must re-attach to
        // the nearest surviving ancestor (the grandparent) rather than flatten to
        // the root.
        snapshot.workspaces.removeAll { $0.groupId == parentId }

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        #expect(restored.workspaceGroups.contains { $0.id == grandparentId })
        #expect(!restored.workspaceGroups.contains { $0.id == parentId })
        #expect(restored.workspaceGroups.first { $0.id == childId }?.parentGroupId == grandparentId)
    }

    @Test func legacyWorkspaceGroupSnapshotDecodesAsTopLevelFolder() throws {
        let groupId = UUID()
        let anchorId = UUID()
        let json = """
        {
          "id": "\(groupId.uuidString)",
          "name": "Legacy",
          "isCollapsed": false,
          "anchorWorkspaceId": "\(anchorId.uuidString)",
          "anchorMemberIndex": 0,
          "isPinned": false,
          "customColor": null,
          "iconSymbol": null
        }
        """

        let decoded = try JSONDecoder().decode(SessionWorkspaceGroupSnapshot.self, from: Data(json.utf8))

        #expect(decoded.id == groupId)
        #expect(decoded.parentGroupId == nil)
        #expect(decoded.parentGroupIndex == nil)
    }

    @Test func workspaceGroupIconSymbolResolutionFallsBackToRenderableIcon() {
        #expect(RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: nil, configured: nil) == "folder.fill")
        #expect(RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: "   ", configured: "leaf.fill") == "leaf.fill")
        #expect(RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: "not.an.sf.symbol", configured: nil) == "folder.fill")
    }

    @Test func setWorkspaceGroupIconDropsInvalidSymbols() {
        let manager = makeTabManager()
        let groupId = manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [manager.tabs[0].id]
        )!

        let invalidStoredIcon = manager.setWorkspaceGroupIcon(groupId: groupId, symbol: "not.an.sf.symbol")
        #expect(invalidStoredIcon == nil)
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.iconSymbol == nil)

        let validStoredIcon = manager.setWorkspaceGroupIcon(groupId: groupId, symbol: "  leaf.fill  ")
        #expect(validStoredIcon == "leaf.fill")
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.iconSymbol == "leaf.fill")
    }

    @Test func surfaceTabIconSymbolResolutionFallsBackForInvalidInput() {
        #expect(RenderableSystemSymbol.resolvedSurfaceTabIcon("doc.text") == "doc.text")
        #expect(RenderableSystemSymbol.resolvedSurfaceTabIcon("   doc.text   ") == "doc.text")
        #expect(RenderableSystemSymbol.resolvedSurfaceTabIcon("not.an.sf.symbol") == "doc.text")
        #expect(RenderableSystemSymbol.resolvedSurfaceTabIcon("   ") == "doc.text")
    }

    // Regression for #5404: renaming a group must update the name shown in
    // window chrome (the custom title bar / NSWindow title / toolbar label),
    // not just the sidebar header. The chrome derives a grouped anchor's
    // displayed name from `resolvedWorkspaceDisplayTitle(for:)`, which must
    // track the group's `name` — the single source of truth — rather than the
    // anchor's own (stale) title that was merely seeded at creation.
    @Test func renamingGroupUpdatesAnchorDisplayTitle() throws {
        let manager = makeTabManager()
        let groupId = try #require(
            manager.createWorkspaceGroup(name: "Group 1", childWorkspaceIds: [manager.tabs[0].id])
        )
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let anchor = try #require(manager.tabs.first { $0.id == group.anchorWorkspaceId })

        // Sanity: the anchor's displayed title starts at the group name.
        #expect(manager.resolvedWorkspaceDisplayTitle(for: anchor) == "Group 1")

        manager.renameWorkspaceGroup(groupId: groupId, name: "AUSTIN GENERAL INTELLIGENCE")

        // The chrome's source of truth must reflect the rename.
        #expect(manager.workspaceGroups.first { $0.id == groupId }?.name == "AUSTIN GENERAL INTELLIGENCE")
        #expect(manager.resolvedWorkspaceDisplayTitle(for: anchor) == "AUSTIN GENERAL INTELLIGENCE")
    }

    // A non-anchor workspace keeps its own title; only the anchor mirrors the
    // group name. Guards against the derivation over-reaching to every member.
    @Test func renamingGroupLeavesNonAnchorMemberTitleAlone() throws {
        let manager = makeTabManager()
        let memberId = manager.tabs[1].id
        let groupId = try #require(
            manager.createWorkspaceGroup(name: "Group 1", childWorkspaceIds: [memberId])
        )
        let member = try #require(manager.tabs.first { $0.id == memberId })
        let memberTitle = member.title

        manager.renameWorkspaceGroup(groupId: groupId, name: "Renamed")

        #expect(manager.resolvedWorkspaceDisplayTitle(for: member) == memberTitle)
    }
}
