import Foundation
import Testing

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
        let targetIndex = try #require(SidebarDropPlanner.targetIndex(
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

    @Test func collapsedGroupRenderItemCarriesMembersWithoutRenderingChildren() throws {
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

        var groupMemberIds: [UUID] = []
        var visibleWorkspaceIds: [UUID] = []
        for item in items {
            switch item {
            case .groupHeader(let renderedGroup, let memberWorkspaceIds) where renderedGroup.id == groupId:
                groupMemberIds = memberWorkspaceIds
            case .groupHeader:
                break
            case .workspace(let workspace, _):
                visibleWorkspaceIds.append(workspace.id)
            }
        }

        #expect(groupMemberIds == [
            group.anchorWorkspaceId,
            originalIds[1],
            originalIds[2],
        ])
        #expect(!visibleWorkspaceIds.contains(originalIds[1]))
        #expect(!visibleWorkspaceIds.contains(originalIds[2]))
    }

    /// Promote-in-place must keep the anchor's sidebar slot identity: the group
    /// header's render-item `id` has to equal the render-item `id` the same
    /// workspace's row had before it became a group. That stable identity is
    /// what lets SwiftUI animate the morph and stops the LazyVStack from
    /// dropping the row (the bug that previously needed a whole-list
    /// `.id(groupAnchorSignature)` rebuild). Round-trips back to the workspace
    /// id after ungroup.
    @Test func promoteInPlaceKeepsAnchorRenderIdentity() throws {
        let manager = makeTabManager()
        let anchorId = try #require(manager.tabs.first?.id)

        func renderItemId(forWorkspace workspaceId: UUID) -> String? {
            let items = SidebarWorkspaceRenderItem.renderItems(
                tabs: manager.tabs,
                groupsById: Dictionary(
                    uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) }
                )
            )
            for item in items {
                switch item {
                case .groupHeader(let group, _) where group.anchorWorkspaceId == workspaceId:
                    return item.id
                case .workspace(let workspace, _) where workspace.id == workspaceId:
                    return item.id
                default:
                    continue
                }
            }
            return nil
        }

        let workspaceRowId = try #require(renderItemId(forWorkspace: anchorId))

        let groupId = try #require(manager.makeWorkspaceGroupFromWorkspace(anchorWorkspaceId: anchorId))
        let headerRowId = try #require(renderItemId(forWorkspace: anchorId))
        // Same sidebar slot identity before and after promotion.
        #expect(headerRowId == workspaceRowId)

        manager.ungroupWorkspaceGroup(groupId: groupId)
        let restoredRowId = try #require(renderItemId(forWorkspace: anchorId))
        #expect(restoredRowId == workspaceRowId)
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
        ])
        #expect(forcedTopLevelIds == headerTargetIds)
        #expect(!SidebarTabDropIndicatorPredicate.topVisible(
            forTabId: originalIds[3],
            draggedTabId: originalIds[0],
            dropIndicator: indicator,
            tabIds: fullRowIds
        ))
        #expect(SidebarTabDropIndicatorPredicate.topVisible(
            forTabId: originalIds[3],
            draggedTabId: originalIds[0],
            dropIndicator: indicator,
            tabIds: forcedTopLevelIds
        ))
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
        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: draggedUnpinnedId,
            targetTabId: pinnedChild.id,
            tabIds: tabIds,
            pinnedTabIds: pinnedIds,
            legalInsertionRange: legalInsertionRange,
            pointerY: 2,
            targetHeight: 40
        )
        #expect(indicator == nil)
        #expect(SidebarDropPlanner.targetIndex(
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
        WorkspaceGroupAnchorCloseSettings.setSuppressed(true)
        defer { WorkspaceGroupAnchorCloseSettings.setSuppressed(false) }
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

    /// Deleting a group must remove the header row *and* every member row from
    /// the sidebar render items, not just the model arrays. The stable-identity
    /// refactor keys the header on its anchor workspace's id, so this guards
    /// that the header doesn't linger as a phantom row after its anchor (and
    /// members) are closed.
    @Test func deleteRemovesGroupHeaderAndMemberRowsFromRenderItems() throws {
        let manager = makeTabManager()
        // Outsider so closeWorkspace's `tabs.count <= 1` guard never fires and
        // the whole group is genuinely closed.
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let outsiderId = try #require(manager.tabs.last?.id)
        let groupChildren = Array(manager.tabs.prefix(2)).map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(name: "Doomed", childWorkspaceIds: groupChildren))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let anchorId = group.anchorWorkspaceId
        let memberIds = Set(manager.tabs.filter { $0.groupId == groupId }.map(\.id))

        func renderItems() -> [SidebarWorkspaceRenderItem] {
            SidebarWorkspaceRenderItem.renderItems(
                tabs: manager.tabs,
                groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
            )
        }

        // Sanity: before delete the header renders.
        #expect(renderItems().contains { item in
            if case .groupHeader(let g, _) = item, g.id == groupId { return true }
            return false
        })

        manager.deleteWorkspaceGroup(groupId: groupId)

        let items = renderItems()
        // No header for the deleted group.
        #expect(!items.contains { item in
            if case .groupHeader = item { return true }
            return false
        })
        // No row carries the deleted group's identity (header or member).
        let deletedRowIds = memberIds.union([anchorId]).map { "workspace.\($0.uuidString)" }
        #expect(items.allSatisfy { !deletedRowIds.contains($0.id) })
        // The unrelated outsider survives as a plain workspace row.
        #expect(items.contains { item in
            if case .workspace(let ws, _) = item, ws.id == outsiderId { return true }
            return false
        })
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

    // Turning a single workspace into a group promotes that workspace to be
    // the anchor (no fresh anchor is synthesized), keeps it at the same
    // sidebar position, inherits its title as the group name, and ungroup is
    // the exact inverse: the same single workspace at the same spot.
    @Test func makeWorkspaceGroupFromWorkspacePromotesInPlaceAndRoundTrips() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        #expect(originalIds.count == 3)
        let targetId = originalIds[1]
        let target = try #require(manager.tabs.first { $0.id == targetId })
        target.title = "api-server"
        let countBefore = manager.tabs.count

        let groupId = try #require(manager.makeWorkspaceGroupFromWorkspace(anchorWorkspaceId: targetId))

        // No phantom anchor workspace was created.
        #expect(manager.tabs.count == countBefore)
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        // The workspace itself is the anchor and the sole member.
        #expect(group.anchorWorkspaceId == targetId)
        #expect(target.groupId == groupId)
        #expect(manager.tabs.filter { $0.groupId == groupId }.map(\.id) == [targetId])
        // Position is unchanged.
        #expect(manager.tabs.map(\.id) == originalIds)
        // The header inherits the workspace's title rather than "Group N".
        #expect(group.name == "api-server")
        #expect(manager.resolvedWorkspaceDisplayTitle(for: target) == "api-server")

        // Ungroup returns the anchor to a regular ungrouped workspace in place.
        manager.ungroupWorkspaceGroup(groupId: groupId)
        #expect(manager.workspaceGroups.contains { $0.id == groupId } == false)
        #expect(target.groupId == nil)
        #expect(manager.tabs.count == countBefore)
        #expect(manager.tabs.map(\.id) == originalIds)
        #expect(manager.resolvedWorkspaceDisplayTitle(for: target) == "api-server")
    }

    // Promote is for ungrouped workspaces only. A workspace that already
    // belongs to a group must use add/remove, so the call is a no-op.
    @Test func makeWorkspaceGroupFromWorkspaceNoOpsForGroupedWorkspace() throws {
        let manager = makeTabManager()
        let memberId = manager.tabs[1].id
        let groupId = try #require(
            manager.createWorkspaceGroup(name: "Group 1", childWorkspaceIds: [memberId])
        )
        let groupCountBefore = manager.workspaceGroups.count
        let tabCountBefore = manager.tabs.count

        #expect(manager.makeWorkspaceGroupFromWorkspace(anchorWorkspaceId: memberId) == nil)
        #expect(manager.workspaceGroups.count == groupCountBefore)
        #expect(manager.tabs.count == tabCountBefore)
        #expect(manager.tabs.first { $0.id == memberId }?.groupId == groupId)
    }

    // A pinned workspace turned into a group must stay in the pinned sidebar
    // tier (group tier reads `group.isPinned`, not the anchor's own pin), so
    // it does not get demoted below other pinned rows. Guards the
    // `isPinned: anchorTab.isPinned` inheritance.
    @Test func makeWorkspaceGroupFromWorkspaceKeepsPinnedWorkspaceInPinnedTier() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let ids = manager.tabs.map(\.id)
        #expect(ids.count == 4)
        // Pin the first two so they form the pinned tier, in order. Promoting
        // the FIRST pinned workspace without inheriting its pin would demote
        // it below the second pinned workspace (pinned-first reordering).
        manager.tabs[0].isPinned = true
        manager.tabs[1].isPinned = true

        let groupId = try #require(manager.makeWorkspaceGroupFromWorkspace(anchorWorkspaceId: ids[0]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })

        #expect(group.isPinned)
        #expect(manager.tabs.map(\.id) == ids)

        // Ungroup restores the anchor as a still-pinned row in the same spot.
        manager.ungroupWorkspaceGroup(groupId: groupId)
        #expect(manager.tabs.first { $0.id == ids[0] }?.isPinned == true)
        #expect(manager.tabs.map(\.id) == ids)
    }

    // A promoted single-workspace group has its anchor as the only member, so
    // it renders as a header with no child rows. Sanity-check that the anchor
    // is excluded from the rendered workspace rows (it is the header).
    @Test func singleWorkspaceGroupRendersOnlyAsHeader() throws {
        let manager = makeTabManager()
        let targetId = manager.tabs[0].id

        let groupId = try #require(manager.makeWorkspaceGroupFromWorkspace(anchorWorkspaceId: targetId))
        let groupsById = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        let items = SidebarWorkspaceRenderItem.renderItems(tabs: manager.tabs, groupsById: groupsById)

        let headerGroupIds: [UUID] = items.compactMap {
            if case let .groupHeader(group, _) = $0 { return group.id }
            return nil
        }
        let workspaceRowIds: [UUID] = items.compactMap {
            if case let .workspace(workspace, _) = $0 { return workspace.id }
            return nil
        }
        #expect(headerGroupIds.contains(groupId))
        #expect(workspaceRowIds.contains(targetId) == false)
    }

    // MARK: - Grouping keeps sidebar selection on the focused workspace

    @Test func createGroupKeepsSidebarSelectionOnFocusedNonMember() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let focusedTab = try #require(manager.tabs.first { $0.id == originalIds[3] })
        manager.selectTab(focusedTab)
        manager.setSidebarSelectedWorkspaceIds([originalIds[0], originalIds[1]])

        let groupId = manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [originalIds[0], originalIds[1]],
            selectAnchor: false
        )

        #expect(groupId != nil)
        // The active workspace did not change (selectAnchor: false), so the
        // collapsed sidebar selection must keep tracking it instead of
        // jumping to the new empty anchor.
        #expect(manager.selectedTabId == focusedTab.id)
        #expect(manager.sidebarSelectedWorkspaceIds == [focusedTab.id])
    }

    // MARK: - Gesture drag commit (explicit membership)

    @Test func gestureDragJoinsGroupAtInteriorSlot() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [originalIds[0], originalIds[1]]
        ))
        // tabs: [anchor, m0, m1, w2, w3]
        let draggedId = manager.tabs[4].id
        let anchorId = try #require(manager.workspaceGroups.first { $0.id == groupId }).anchorWorkspaceId

        // Join between m0 and m1 (interior slot, index 2 after removal shift).
        let moved = manager.applyGestureDragReorder(tabId: draggedId, toIndex: 2, desiredGroupId: groupId)

        #expect(moved)
        #expect(manager.tabs.first { $0.id == draggedId }?.groupId == groupId)
        let order = manager.tabs.map(\.id)
        #expect(order[0] == anchorId)
        #expect(order[1] == originalIds[0])
        #expect(order[2] == draggedId)
        #expect(order[3] == originalIds[1])
    }

    @Test func gestureDragJoinsEmptyGroupFromBelow() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.makeWorkspaceGroupFromWorkspace(anchorWorkspaceId: originalIds[0]))
        // tabs: [anchor(=w0), w1, w2]
        let draggedId = originalIds[2]

        let moved = manager.applyGestureDragReorder(tabId: draggedId, toIndex: 1, desiredGroupId: groupId)

        #expect(moved)
        #expect(manager.tabs.first { $0.id == draggedId }?.groupId == groupId)
        #expect(manager.tabs.map(\.id)[1] == draggedId)
    }

    @Test func gestureDragMembershipOnlyLeaveAtUnchangedIndex() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [originalIds[0], originalIds[1]]
        ))
        // tabs: [anchor, m0, m1, w2]; pull m1 out in place (last member slot).
        let draggedId = originalIds[1]
        let index = try #require(manager.tabs.firstIndex { $0.id == draggedId })

        let changed = manager.applyGestureDragReorder(tabId: draggedId, toIndex: index, desiredGroupId: nil)

        #expect(changed)
        #expect(manager.tabs.first { $0.id == draggedId }?.groupId == nil)
        // Contiguity holds: the row sits right after the group's run.
        let memberIds = manager.tabs.filter { $0.groupId == groupId }.map(\.id)
        #expect(!memberIds.contains(draggedId))
        let lastMemberIndex = try #require(manager.tabs.lastIndex { $0.groupId == groupId })
        let draggedIndex = try #require(manager.tabs.firstIndex { $0.id == draggedId })
        #expect(draggedIndex > lastMemberIndex)
    }

    @Test func gestureDragMembershipChangeUnpins() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [originalIds[0]]
        ))
        // Pin the member, then drag it out: the pin must not survive and the
        // row must land where aimed instead of teleporting to the pinned tier.
        let memberId = originalIds[0]
        let member = try #require(manager.tabs.first { $0.id == memberId })
        manager.setPinned(member, pinned: true)
        let lastIndex = manager.tabs.count - 1

        let changed = manager.applyGestureDragReorder(tabId: memberId, toIndex: lastIndex, desiredGroupId: nil)

        #expect(changed)
        let moved = try #require(manager.tabs.first { $0.id == memberId })
        #expect(moved.groupId == nil)
        #expect(!moved.isPinned)
        #expect(manager.tabs.firstIndex { $0.id == memberId } == lastIndex)
    }

    @Test func gestureDragJoiningCollapsedGroupExpandsIt() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(name: "C", childWorkspaceIds: [originalIds[0]]))
        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        #expect(try #require(manager.workspaceGroups.first { $0.id == groupId }).isCollapsed)
        let draggedId = originalIds[2]

        _ = manager.applyGestureDragReorder(tabId: draggedId, toIndex: 2, desiredGroupId: groupId)

        #expect(manager.tabs.first { $0.id == draggedId }?.groupId == groupId)
        #expect(try #require(manager.workspaceGroups.first { $0.id == groupId }).isCollapsed == false)
    }

    @Test func gestureDragLeavingPinnedTierUnpins() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let pinnedTab = try #require(manager.tabs.first { $0.id == originalIds[0] })
        manager.setPinned(pinnedTab, pinned: true)
        let lastIndex = manager.tabs.count - 1

        let moved = manager.applyGestureDragReorder(tabId: originalIds[0], toIndex: lastIndex, desiredGroupId: nil)

        #expect(moved)
        let tab = try #require(manager.tabs.first { $0.id == originalIds[0] })
        #expect(!tab.isPinned)
        #expect(manager.tabs.firstIndex { $0.id == originalIds[0] } == lastIndex)
    }

    @Test func boundaryHitboxesResolveLastOfGroupVsFirstAfterGroup() throws {
        // Layout (list space): header H(0..30, group G), member M(30..80, G),
        // ungrouped U(80..130), dragged row D(200..250, ungrouped).
        let drag = SidebarDragState()
        let g = UUID()
        let h = UUID(), m = UUID(), u = UUID(), d = UUID()
        let frames: [UUID: CGRect] = [
            h: CGRect(x: 0, y: 0, width: 200, height: 30),
            m: CGRect(x: 12, y: 30, width: 188, height: 50),
            u: CGRect(x: 0, y: 80, width: 200, height: 50),
            d: CGRect(x: 0, y: 200, width: 200, height: 50),
        ]
        drag.updateRowFrames(frames)
        drag.beginReorder(
            tabId: d,
            usesTopLevelRows: false,
            reorderIds: [h, m, u, d],
            pinnedIds: [],
            scopeBandComposition: [:],
            bandGroupIdById: [h: g, m: g, u: nil, d: nil],
            headerBandIds: [h],
            draggedCommittedGroupId: nil,
            draggedIsAnchor: false,
            draggedRowFrame: frames[d],
            grabOffsetY: 25,
            translationBaseY: 225,
            cursorY: 225
        )

        // Hover the last member's LOWER half: the slot is "after M" and the
        // membership hitbox says INSIDE the group (last member).
        drag.updateReorder(cursorY: 70, translationWidth: 0)
        #expect(drag.dropIndicator != nil)
        #expect(drag.previewMembershipGroupId == g)

        // Slide just past M's bottom edge (over U's top half): SAME insertion
        // position, but the second hitbox — first row AFTER the group.
        drag.updateReorder(cursorY: 95, translationWidth: 0)
        #expect(drag.previewMembershipGroupId == nil)

        // The header's lower half tucks INTO the group as its first slot
        // (clear of the 3pt hysteresis band around the zone edge at y=30).
        drag.updateReorder(cursorY: 26, translationWidth: 0)
        #expect(drag.previewMembershipGroupId == g)

        drag.clearDrag()
        #expect(drag.previewMembershipGroupId == nil)
    }

    @Test func gestureDragRejectsAnchorsAndDeadGroups() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.makeWorkspaceGroupFromWorkspace(anchorWorkspaceId: originalIds[0]))
        let anchorId = try #require(manager.workspaceGroups.first { $0.id == groupId }).anchorWorkspaceId

        #expect(manager.applyGestureDragReorder(tabId: anchorId, toIndex: 2, desiredGroupId: nil) == false)
        // A stale group id resolves to no membership instead of corrupting state.
        let draggedId = originalIds[2]
        _ = manager.applyGestureDragReorder(tabId: draggedId, toIndex: 1, desiredGroupId: UUID())
        #expect(manager.tabs.first { $0.id == draggedId }?.groupId == nil)
    }

    @Test func dragPreviewItemsKeepsInGroupSlotsWhenCollapsedGroupsExist() throws {
        let manager = makeTabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        // One EXPANDED group (m0, m1) and one COLLAPSED group (m2) — the
        // collapsed group's hidden member used to flip the preview into
        // top-level mode and kill the in-group slot preview entirely.
        let expandedGroupId = try #require(manager.createWorkspaceGroup(
            name: "Open",
            childWorkspaceIds: [originalIds[0], originalIds[1]]
        ))
        let collapsedGroupId = try #require(manager.createWorkspaceGroup(
            name: "Closed",
            childWorkspaceIds: [originalIds[2]]
        ))
        manager.toggleWorkspaceGroupCollapsed(groupId: collapsedGroupId)
        _ = expandedGroupId

        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs,
            groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        )
        let draggedId = try #require(manager.tabs.last).id
        let targetMemberId = originalIds[1]
        let reorderIds = manager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: draggedId)

        let preview = SidebarWorkspaceRenderItem.dragPreviewItems(
            items,
            draggedWorkspaceId: draggedId,
            dropIndicator: SidebarDropIndicator(tabId: targetMemberId, edge: .top),
            reorderWorkspaceIds: reorderIds,
            topLevelMode: false,
            draggedMembershipGroupId: expandedGroupId
        )

        let previewIds = preview.map(\.representedWorkspaceId)
        let itemIds = items.map(\.representedWorkspaceId)
        #expect(previewIds != itemIds)
        let draggedIndex = try #require(previewIds.firstIndex(of: draggedId))
        let targetIndex = try #require(previewIds.firstIndex(of: targetMemberId))
        #expect(draggedIndex == targetIndex - 1)
        #expect(preview[draggedIndex].effectiveGroupId == expandedGroupId)
    }
}

/// Covers the gesture-driven reorder hit-testing + hysteresis that
/// `SidebarReorderIndicatorResolver` adds on top of `SidebarDropPlanner`.
@Suite("Sidebar reorder indicator resolver")
struct SidebarReorderIndicatorResolverTests {
    private func band(_ id: UUID, _ minY: CGFloat, _ maxY: CGFloat) -> SidebarReorderIndicatorResolver.Band {
        .init(id: id, minY: minY, maxY: maxY)
    }

    @Test func cursorBelowAllRowsAppendsToEnd() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let bands = [band(a, 0, 20), band(b, 22, 42), band(c, 44, 64)]
        let indicator = SidebarReorderIndicatorResolver.resolve(
            cursorY: 200, bands: bands, draggedId: a, pinnedIds: [], current: nil, hysteresisMargin: 6
        )
        #expect(indicator?.tabId == nil)
        #expect(indicator?.edge == .bottom)
    }

    @Test func cursorInTopHalfOfFirstRowTargetsItsTop() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let bands = [band(a, 0, 20), band(b, 22, 42), band(c, 44, 64)]
        // Dragging C; hovering the top half of A should land it before A.
        let indicator = SidebarReorderIndicatorResolver.resolve(
            cursorY: 3, bands: bands, draggedId: c, pinnedIds: [], current: nil, hysteresisMargin: 6
        )
        #expect(indicator?.tabId == a)
        #expect(indicator?.edge == .top)
    }

    @Test func hysteresisHoldsCurrentEdgeNearMidpoint() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let bands = [band(a, 0, 20), band(b, 20, 40), band(c, 40, 60)]
        // Dragging A. Current landing slot is "after B" (canonicalized to top of C).
        let current = SidebarDropIndicator(tabId: c, edge: .top)
        // Cursor just above B's midpoint (30) and within the 6pt dead-zone: the
        // raw decision flips to "before B", but stickiness keeps the current slot.
        let held = SidebarReorderIndicatorResolver.resolve(
            cursorY: 29, bands: bands, draggedId: a, pinnedIds: [], current: current, hysteresisMargin: 6
        )
        #expect(held == current)
        // With no hysteresis the same cursor flips the slot.
        let flipped = SidebarReorderIndicatorResolver.resolve(
            cursorY: 29, bands: bands, draggedId: a, pinnedIds: [], current: current, hysteresisMargin: 0
        )
        #expect(flipped != current)
    }

    @Test func clearMidpointCrossingFlipsEdge() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let bands = [band(a, 0, 20), band(b, 20, 40), band(c, 40, 60)]
        let current = SidebarDropIndicator(tabId: c, edge: .top) // after B
        // Dragging C; cursor well into the top of B (far outside the dead-zone)
        // lands before B.
        let indicator = SidebarReorderIndicatorResolver.resolve(
            cursorY: 22, bands: bands, draggedId: c, pinnedIds: [], current: current, hysteresisMargin: 6
        )
        #expect(indicator?.tabId == b)
        #expect(indicator?.edge == .top)
    }

    @Test func emptyBandsResolveToNil() {
        let indicator = SidebarReorderIndicatorResolver.resolve(
            cursorY: 10, bands: [], draggedId: UUID(), pinnedIds: [], current: nil, hysteresisMargin: 6
        )
        #expect(indicator == nil)
    }
}
