import XCTest
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class ProjectGroupTests: XCTestCase {

    // MARK: - ProjectGroup Initialization

    func testProjectGroupDefaultInit() {
        let group = ProjectGroup(name: "Backend")
        XCTAssertFalse(group.id.uuidString.isEmpty)
        XCTAssertEqual(group.name, "Backend")
        XCTAssertNil(group.color)
        XCTAssertFalse(group.isCollapsed)
        XCTAssertTrue(group.workspaceIds.isEmpty)
    }

    func testProjectGroupCustomInit() {
        let fixedId = UUID()
        let wsIds = [UUID(), UUID()]
        let group = ProjectGroup(id: fixedId, name: "Frontend", color: "blue", isCollapsed: true, workspaceIds: wsIds)
        XCTAssertEqual(group.id, fixedId)
        XCTAssertEqual(group.name, "Frontend")
        XCTAssertEqual(group.color, "blue")
        XCTAssertTrue(group.isCollapsed)
        XCTAssertEqual(group.workspaceIds, wsIds)
    }

    func testProjectGroupPublishedNameChange() {
        let group = ProjectGroup(name: "Old")
        let expectation = expectation(description: "name publisher fires")
        var cancellable: AnyCancellable?
        cancellable = group.$name
            .dropFirst()
            .sink { newName in
                XCTAssertEqual(newName, "New")
                expectation.fulfill()
                cancellable?.cancel()
            }
        group.name = "New"
        waitForExpectations(timeout: 1)
    }

    // MARK: - SidebarOrderItem Equality

    func testSidebarOrderItemEquality() {
        let id1 = UUID()
        let id2 = UUID()
        XCTAssertEqual(SidebarOrderItem.group(id1), SidebarOrderItem.group(id1))
        XCTAssertNotEqual(SidebarOrderItem.group(id1), SidebarOrderItem.group(id2))
        XCTAssertEqual(SidebarOrderItem.workspace(id1), SidebarOrderItem.workspace(id1))
        XCTAssertNotEqual(SidebarOrderItem.workspace(id1), SidebarOrderItem.group(id1))
    }

    // MARK: - SidebarOrderItem Codable Round-trip

    func testSidebarOrderItemGroupCodableRoundTrip() throws {
        let id = UUID()
        let original = SidebarOrderItem.group(id)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SidebarOrderItem.self, from: data)
        XCTAssertEqual(decoded, original)

        // Verify the type discriminator key is present in the JSON
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "group")
        XCTAssertEqual((json?["id"] as? String)?.lowercased(), id.uuidString.lowercased())
    }

    func testSidebarOrderItemWorkspaceCodableRoundTrip() throws {
        let id = UUID()
        let original = SidebarOrderItem.workspace(id)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SidebarOrderItem.self, from: data)
        XCTAssertEqual(decoded, original)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "workspace")
    }

    func testSidebarOrderItemDecodingInvalidTypeThrows() {
        let json = #"{"type":"unknown","id":"00000000-0000-0000-0000-000000000000"}"#
        let data = Data(json.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SidebarOrderItem.self, from: data))
    }

    // MARK: - GroupRowModel Equality

    func testGroupRowModelEquality() {
        let id = UUID()
        let a = GroupRowModel(id: id, name: "G", color: "red", isCollapsed: false, workspaceCount: 3)
        let b = GroupRowModel(id: id, name: "G", color: "red", isCollapsed: false, workspaceCount: 3)
        let c = GroupRowModel(id: id, name: "G", color: "blue", isCollapsed: false, workspaceCount: 3)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - WorkspaceRowModel Equality

    func testWorkspaceRowModelEquality() {
        let id = UUID()
        let parentId = UUID()
        let a = WorkspaceRowModel(id: id, parentGroupId: parentId, title: "ws1", customColor: nil, isPinned: false)
        let b = WorkspaceRowModel(id: id, parentGroupId: parentId, title: "ws1", customColor: nil, isPinned: false)
        let c = WorkspaceRowModel(id: id, parentGroupId: nil, title: "ws1", customColor: nil, isPinned: false)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.isIndented)
        XCTAssertFalse(c.isIndented)
    }

    // MARK: - SidebarDisplayItem Identity

    func testSidebarDisplayItemIdentity() {
        let groupId = UUID()
        let wsId = UUID()
        let groupModel = GroupRowModel(id: groupId, name: "G", color: nil, isCollapsed: false, workspaceCount: 1)
        let wsModel = WorkspaceRowModel(id: wsId, parentGroupId: groupId, title: "ws", customColor: nil, isPinned: false)

        let groupItem = SidebarDisplayItem.groupHeader(groupModel)
        let wsItem = SidebarDisplayItem.workspace(wsModel)

        XCTAssertEqual(groupItem.id, groupId)
        XCTAssertEqual(wsItem.id, wsId)
        XCTAssertNotEqual(groupItem.id, wsItem.id)
    }

    func testProjectGroupPublishesChangesForAllProperties() {
        let group = ProjectGroup(name: "Test")
        var changeCount = 0
        let cancellable = group.objectWillChange.sink { _ in changeCount += 1 }

        group.name = "Renamed"
        group.color = "#FF0000"
        group.isCollapsed = true
        group.workspaceIds = [UUID()]

        XCTAssertEqual(changeCount, 4)
        _ = cancellable
    }

    func testSidebarDisplayItemEquality() {
        let id = UUID()
        let model1 = GroupRowModel(id: id, name: "G", color: nil, isCollapsed: false, workspaceCount: 1)
        let model2 = GroupRowModel(id: id, name: "G", color: nil, isCollapsed: false, workspaceCount: 1)
        XCTAssertEqual(SidebarDisplayItem.groupHeader(model1), SidebarDisplayItem.groupHeader(model2))
    }
}

final class SessionGroupSnapshotTests: XCTestCase {
    func testSessionGroupSnapshotRoundTrip() throws {
        let wsIds = [UUID(), UUID()]
        let snapshot = SessionGroupSnapshot(
            id: UUID(),
            name: "Backend",
            color: "#1565C0",
            isCollapsed: true,
            workspaceIds: wsIds
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionGroupSnapshot.self, from: data)
        XCTAssertEqual(decoded.id, snapshot.id)
        XCTAssertEqual(decoded.name, "Backend")
        XCTAssertEqual(decoded.color, "#1565C0")
        XCTAssertTrue(decoded.isCollapsed)
        XCTAssertEqual(decoded.workspaceIds, wsIds)
    }

    func testSessionGroupSnapshotNilColor() throws {
        let snapshot = SessionGroupSnapshot(
            id: UUID(),
            name: "Frontend",
            color: nil,
            isCollapsed: false,
            workspaceIds: []
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionGroupSnapshot.self, from: data)
        XCTAssertNil(decoded.color)
        XCTAssertFalse(decoded.isCollapsed)
    }
}

final class SessionMigrationTests: XCTestCase {
    func testV1SnapshotDecodesWithEmptyGroupsAndSidebarOrder() throws {
        let v1Json = """
        {
            "selectedWorkspaceIndex": 0,
            "workspaces": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: v1Json)
        XCTAssertEqual(decoded.selectedWorkspaceIndex, 0)
        XCTAssertTrue(decoded.workspaces.isEmpty)
        XCTAssertTrue(decoded.groups.isEmpty)
        XCTAssertTrue(decoded.sidebarOrder.isEmpty)
    }
}

// MARK: - TabManager Group CRUD Tests

@MainActor
final class TabManagerGroupTests: XCTestCase {

    func testCreateGroupAddsToGroupsAndSidebarOrder() {
        let manager = TabManager()
        // TabManager creates one default workspace on init
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.sidebarOrder.count, 1)

        let group = manager.createGroup(name: "Backend")
        XCTAssertEqual(manager.groups.count, 1)
        XCTAssertEqual(manager.groups.first?.name, "Backend")
        XCTAssertTrue(manager.sidebarOrder.contains(.group(group.id)))
        XCTAssertEqual(manager.sidebarOrder.count, 2) // 1 workspace + 1 group
    }

    func testOrderedSidebarWorkspaceIdsFlattensGroupsInSidebarOrder() {
        let manager = TabManager()
        let topLevelWorkspace = manager.tabs[0]
        let groupedWorkspaceA = manager.addWorkspace()
        let groupedWorkspaceB = manager.addWorkspace()
        let trailingWorkspace = manager.addWorkspace()
        let group = manager.createGroup(name: "Backend")

        manager.addWorkspaceToGroup(groupedWorkspaceA.id, to: group.id)
        manager.addWorkspaceToGroup(groupedWorkspaceB.id, to: group.id)
        XCTAssertTrue(manager.reorderTopLevelItem(.workspace(trailingWorkspace.id), toIndex: 1))
        group.isCollapsed = true

        XCTAssertEqual(
            manager.orderedSidebarWorkspaceIds(),
            [topLevelWorkspace.id, trailingWorkspace.id, groupedWorkspaceA.id, groupedWorkspaceB.id]
        )
    }

    func testSetGroupNameTrimsWhitespaceAndRejectsEmptyValues() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Backend")

        manager.setGroupName(groupId: group.id, name: "  Platform  ")
        XCTAssertEqual(group.name, "Platform")

        manager.setGroupName(groupId: group.id, name: "   \n  ")
        XCTAssertEqual(group.name, "Platform")
    }

    func testDeleteGroupWithKeepWorkspacesMovesToTopLevel() {
        let manager = TabManager()
        let initialWs = manager.tabs[0]
        let ws2 = manager.addWorkspace(select: false)

        let group = manager.createGroup(name: "Frontend")
        manager.addWorkspaceToGroup(initialWs.id, to: group.id)
        manager.addWorkspaceToGroup(ws2.id, to: group.id)
        XCTAssertEqual(group.workspaceIds.count, 2)

        // Delete group but keep workspaces
        manager.deleteGroup(id: group.id, closeWorkspaces: false)
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertFalse(manager.sidebarOrder.contains(.group(group.id)))
        // The workspaces should now be top-level entries in sidebarOrder
        XCTAssertTrue(manager.sidebarOrder.contains(.workspace(initialWs.id)))
        XCTAssertTrue(manager.sidebarOrder.contains(.workspace(ws2.id)))
    }

    func testDeleteGroupWithCloseWorkspacesClosesGroupedTabs() {
        let manager = TabManager()
        let group = manager.createGroup(name: "ToDelete")
        let ws1 = manager.tabs[0]  // default workspace
        let ws2 = manager.addWorkspace(select: false)
        manager.addWorkspaceToGroup(ws1.id, to: group.id)
        manager.addWorkspaceToGroup(ws2.id, to: group.id)

        // Need at least one ungrouped tab so closeWorkspace doesn't refuse
        let ws3 = manager.addWorkspace(select: false)

        manager.deleteGroup(id: group.id, closeWorkspaces: true)

        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == ws1.id }))
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == ws2.id }))
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == ws3.id }))
        XCTAssertFalse(manager.sidebarOrder.contains(.group(group.id)))
    }

    func testAddWorkspaceToGroup() {
        let manager = TabManager()
        let ws = manager.tabs[0]
        let group = manager.createGroup(name: "Group1")

        manager.addWorkspaceToGroup(ws.id, to: group.id)
        XCTAssertEqual(group.workspaceIds, [ws.id])
        // Workspace should be removed from top-level sidebarOrder
        XCTAssertFalse(manager.sidebarOrder.contains(.workspace(ws.id)))
    }

    func testRemoveWorkspaceFromGroup() {
        let manager = TabManager()
        let ws = manager.tabs[0]
        let group = manager.createGroup(name: "Group1")
        manager.addWorkspaceToGroup(ws.id, to: group.id)
        XCTAssertTrue(group.workspaceIds.contains(ws.id))

        manager.removeWorkspaceFromGroup(ws.id, from: group.id)
        XCTAssertFalse(group.workspaceIds.contains(ws.id))
        // Workspace should be back in top-level sidebarOrder
        XCTAssertTrue(manager.sidebarOrder.contains(.workspace(ws.id)))
    }

    func testGroupForWorkspace() {
        let manager = TabManager()
        let ws = manager.tabs[0]
        let group = manager.createGroup(name: "Group1")
        manager.addWorkspaceToGroup(ws.id, to: group.id)

        let found = manager.groupForWorkspace(ws.id)
        XCTAssertEqual(found?.id, group.id)
    }

    func testGroupForUngroupedWorkspaceReturnsNil() {
        let manager = TabManager()
        let ws = manager.tabs[0]
        XCTAssertNil(manager.groupForWorkspace(ws.id))
    }

    func testUngroupAllMovesWorkspacesAndRemovesGroup() {
        let manager = TabManager()
        let ws1 = manager.tabs[0]
        let ws2 = manager.addWorkspace(select: false)

        let group = manager.createGroup(name: "Group1")
        manager.addWorkspaceToGroup(ws1.id, to: group.id)
        manager.addWorkspaceToGroup(ws2.id, to: group.id)
        XCTAssertEqual(manager.groups.count, 1)

        manager.ungroupAll(groupId: group.id)
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertTrue(manager.sidebarOrder.contains(.workspace(ws1.id)))
        XCTAssertTrue(manager.sidebarOrder.contains(.workspace(ws2.id)))
    }

    func testWorkspaceCanBelongToOnlyOneGroup() {
        let manager = TabManager()
        let ws = manager.tabs[0]
        let group1 = manager.createGroup(name: "Group1")
        let group2 = manager.createGroup(name: "Group2")

        manager.addWorkspaceToGroup(ws.id, to: group1.id)
        XCTAssertEqual(group1.workspaceIds, [ws.id])

        // Moving to group2 should remove from group1
        manager.addWorkspaceToGroup(ws.id, to: group2.id)
        XCTAssertFalse(group1.workspaceIds.contains(ws.id))
        XCTAssertEqual(group2.workspaceIds, [ws.id])
    }

    func testAddUngroupedWorkspaceRespectsPlacementInSidebarOrder() {
        let manager = TabManager()
        let ws1 = manager.tabs[0]
        let ws2 = manager.addWorkspace(select: false, placementOverride: .end)
        let group = manager.createGroup(name: "Group1")
        manager.addWorkspaceToGroup(ws1.id, to: group.id)

        XCTAssertEqual(manager.sidebarOrder, [.workspace(ws2.id), .group(group.id)])

        let ws3 = manager.addWorkspace(select: false, placementOverride: .top)
        XCTAssertEqual(manager.sidebarOrder, [.workspace(ws3.id), .workspace(ws2.id), .group(group.id)])
    }

    func testReorderTopLevelItemMovesGroupBeforeWorkspace() {
        let manager = TabManager()
        let ws1 = manager.tabs[0]
        let ws2 = manager.addWorkspace(select: false, placementOverride: .end)
        let group = manager.createGroup(name: "Group1")

        XCTAssertEqual(manager.sidebarOrder, [.workspace(ws1.id), .workspace(ws2.id), .group(group.id)])
        XCTAssertTrue(manager.reorderTopLevelItem(.group(group.id), toIndex: 1))
        XCTAssertEqual(manager.sidebarOrder, [.workspace(ws1.id), .group(group.id), .workspace(ws2.id)])
    }

    func testReorderWorkspaceInGroupMovesWorkspaceWithinGroup() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Group1")
        let ws1 = manager.tabs[0]
        let ws2 = manager.addWorkspace(select: false, placementOverride: .end)
        let ws3 = manager.addWorkspace(select: false, placementOverride: .end)

        manager.addWorkspaceToGroup(ws1.id, to: group.id)
        manager.addWorkspaceToGroup(ws2.id, to: group.id)
        manager.addWorkspaceToGroup(ws3.id, to: group.id)

        XCTAssertTrue(manager.reorderWorkspaceInGroup(ws3.id, groupId: group.id, toIndex: 1))
        XCTAssertEqual(group.workspaceIds, [ws1.id, ws3.id, ws2.id])
    }

    func testMoveWorkspaceToGroupAtSpecificIndex() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Group1")
        let ws1 = manager.tabs[0]
        let ws2 = manager.addWorkspace(select: false, placementOverride: .end)
        let ws3 = manager.addWorkspace(select: false, placementOverride: .end)

        manager.addWorkspaceToGroup(ws1.id, to: group.id)
        manager.addWorkspaceToGroup(ws2.id, to: group.id)

        XCTAssertTrue(manager.moveWorkspaceToGroup(ws3.id, groupId: group.id, at: 1))
        XCTAssertEqual(group.workspaceIds, [ws1.id, ws3.id, ws2.id])
        XCTAssertFalse(manager.sidebarOrder.contains(.workspace(ws3.id)))
    }

    func testMoveWorkspaceOutOfGroupInsertsAtRequestedSidebarIndex() {
        let manager = TabManager()
        let ws1 = manager.tabs[0]
        let ws2 = manager.addWorkspace(select: false, placementOverride: .end)
        let ws3 = manager.addWorkspace(select: false, placementOverride: .end)
        let group = manager.createGroup(name: "Group1")

        manager.addWorkspaceToGroup(ws2.id, to: group.id)
        XCTAssertEqual(manager.sidebarOrder, [.workspace(ws1.id), .workspace(ws3.id), .group(group.id)])

        XCTAssertTrue(manager.moveWorkspaceOutOfGroup(ws2.id, toSidebarIndex: 1))
        XCTAssertEqual(manager.sidebarOrder, [.workspace(ws1.id), .workspace(ws2.id), .workspace(ws3.id), .group(group.id)])
        XCTAssertFalse(group.workspaceIds.contains(ws2.id))
    }
}

// MARK: - Display Items Rebuild Tests

@MainActor
final class DisplayItemsRebuildTests: XCTestCase {

    func testRebuildDisplayItemsWithUngroupedOnly() {
        let manager = TabManager()
        // TabManager creates one workspace on init
        let ws = manager.tabs[0]

        let items = manager.rebuildDisplayItems()
        XCTAssertEqual(items.count, 1)
        if case .workspace(let model) = items.first {
            XCTAssertEqual(model.id, ws.id)
            XCTAssertNil(model.parentGroupId)
            XCTAssertFalse(model.isIndented)
        } else {
            XCTFail("Expected workspace display item")
        }
    }

    func testRebuildDisplayItemsWithGroupAndChildren() {
        let manager = TabManager()
        let ws = manager.tabs[0]

        let group = manager.createGroup(name: "Backend")
        manager.addWorkspaceToGroup(ws.id, to: group.id)

        let items = manager.rebuildDisplayItems()
        // Should have: 1 group header + 1 workspace child
        XCTAssertEqual(items.count, 2)

        if case .groupHeader(let model) = items[0] {
            XCTAssertEqual(model.id, group.id)
            XCTAssertEqual(model.name, "Backend")
            XCTAssertEqual(model.workspaceCount, 1)
        } else {
            XCTFail("Expected group header display item")
        }

        if case .workspace(let model) = items[1] {
            XCTAssertEqual(model.id, ws.id)
            XCTAssertEqual(model.parentGroupId, group.id)
            XCTAssertTrue(model.isIndented)
        } else {
            XCTFail("Expected workspace display item")
        }
    }

    func testCollapsedGroupHidesChildren() {
        let manager = TabManager()
        let ws = manager.tabs[0]

        let group = manager.createGroup(name: "Backend")
        manager.addWorkspaceToGroup(ws.id, to: group.id)
        group.isCollapsed = true

        let items = manager.rebuildDisplayItems()
        // Should only have the group header, no workspace children
        XCTAssertEqual(items.count, 1)
        if case .groupHeader(let model) = items[0] {
            XCTAssertEqual(model.id, group.id)
            XCTAssertTrue(model.isCollapsed)
        } else {
            XCTFail("Expected group header display item")
        }
    }
}

// MARK: - Group-Aware Lifecycle Tests

@MainActor
final class GroupAwareLifecycleTests: XCTestCase {

    func testCloseWorkspaceRemovesFromGroup() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Test")
        let ws = manager.addWorkspace()
        manager.addWorkspaceToGroup(ws.id, to: group.id)
        let _ = manager.addWorkspace() // need 2+ tabs to close
        manager.closeWorkspace(ws)
        XCTAssertFalse(group.workspaceIds.contains(ws.id))
        XCTAssertFalse(manager.sidebarOrder.contains(.workspace(ws.id)))
    }

    func testDetachWorkspaceRemovesFromGroup() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Test")
        let ws = manager.addWorkspace()
        manager.addWorkspaceToGroup(ws.id, to: group.id)
        let detached = manager.detachWorkspace(tabId: ws.id)
        XCTAssertNotNil(detached)
        XCTAssertFalse(group.workspaceIds.contains(ws.id))
        XCTAssertFalse(manager.sidebarOrder.contains(.workspace(ws.id)))
    }

    func testAttachWorkspaceAddsToSidebarOrderUngrouped() {
        let manager = TabManager()
        let ws = manager.addWorkspace()
        guard let detached = manager.detachWorkspace(tabId: ws.id) else {
            XCTFail("Expected detached workspace")
            return
        }
        manager.attachWorkspace(detached)
        XCTAssertTrue(manager.sidebarOrder.contains(.workspace(ws.id)))
        XCTAssertNil(manager.groupForWorkspace(ws.id))
    }

    func testAddWorkspaceWithTargetGroupId() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Test")
        let ws = manager.addWorkspace(targetGroupId: group.id)
        XCTAssertTrue(group.workspaceIds.contains(ws.id))
        XCTAssertFalse(manager.sidebarOrder.contains(.workspace(ws.id)))
    }

    func testMoveTabToTopForNotificationReordersWithinGroup() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Test")
        let ws1 = manager.addWorkspace()
        let ws2 = manager.addWorkspace()
        manager.addWorkspaceToGroup(ws1.id, to: group.id)
        manager.addWorkspaceToGroup(ws2.id, to: group.id)
        manager.moveTabToTopForNotification(ws2.id)
        XCTAssertEqual(group.workspaceIds.first, ws2.id)
    }

    func testMoveTabsToTopWithinGroupPreservesRelativeOrder() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Test")
        let ws1 = manager.tabs[0]
        let ws2 = manager.addWorkspace(select: false)
        let ws3 = manager.addWorkspace(select: false)
        manager.addWorkspaceToGroup(ws1.id, to: group.id)
        manager.addWorkspaceToGroup(ws2.id, to: group.id)
        manager.addWorkspaceToGroup(ws3.id, to: group.id)

        XCTAssertEqual(group.workspaceIds, [ws1.id, ws2.id, ws3.id])

        manager.moveTabsToTop([ws2.id, ws3.id])

        XCTAssertEqual(group.workspaceIds, [ws2.id, ws3.id, ws1.id])
    }

    func testReorderWorkspaceRejectsGroupedWorkspace() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Test")
        let groupedWorkspace = manager.tabs[0]
        let trailingWorkspace = manager.addWorkspace(select: false)
        manager.addWorkspaceToGroup(groupedWorkspace.id, to: group.id)

        let originalTabs = manager.tabs.map(\.id)

        XCTAssertFalse(manager.reorderWorkspace(tabId: groupedWorkspace.id, toIndex: 1))
        XCTAssertEqual(manager.tabs.map(\.id), originalTabs)
        XCTAssertEqual(group.workspaceIds, [groupedWorkspace.id])
        XCTAssertEqual(trailingWorkspace.id, manager.tabs.last?.id)
    }
}

// MARK: - Group Session Snapshot Tests

@MainActor
final class GroupSessionSnapshotTests: XCTestCase {

    func testSessionSnapshotIncludesGroups() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Backend")
        let ws = manager.addWorkspace()
        manager.addWorkspaceToGroup(ws.id, to: group.id)
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.groups.count, 1)
        XCTAssertEqual(snapshot.groups.first?.name, "Backend")
        XCTAssertEqual(snapshot.groups.first?.workspaceIds.count, 1)
    }

    func testSessionSnapshotIncludesSidebarOrder() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Test")
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertFalse(snapshot.sidebarOrder.isEmpty)
        XCTAssertTrue(snapshot.sidebarOrder.contains(.group(group.id)))
    }

    func testRestoreSessionSnapshotWithGroups() {
        let manager = TabManager()
        let group = manager.createGroup(name: "Backend")
        group.color = "#FF0000"
        group.isCollapsed = true
        let ws = manager.addWorkspace()
        ws.setCustomTitle("Worker")
        manager.addWorkspaceToGroup(ws.id, to: group.id)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.groups.count, 1)
        XCTAssertEqual(restored.groups.first?.name, "Backend")
        XCTAssertEqual(restored.groups.first?.color, "#FF0000")
        XCTAssertTrue(restored.groups.first?.isCollapsed ?? false)
        XCTAssertEqual(restored.groups.first?.workspaceIds.count, 1)
    }

    func testRestoreV1SnapshotCreatesEmptyGroupsAndPopulatesSidebarOrder() {
        let manager = TabManager()
        let v1Snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: []
        )
        manager.restoreSessionSnapshot(v1Snapshot)
        XCTAssertTrue(manager.groups.isEmpty)
        // v1 migration should populate sidebarOrder from tabs
        XCTAssertFalse(manager.sidebarOrder.isEmpty)
        XCTAssertEqual(manager.sidebarOrder.count, manager.tabs.count)
    }

    func testRestorePrunesStaleWorkspaceIdsFromGroups() {
        let manager = TabManager()
        let staleId = UUID()
        let groupSnapshot = SessionGroupSnapshot(
            id: UUID(),
            name: "Stale",
            color: nil,
            isCollapsed: false,
            workspaceIds: [staleId]
        )
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: [],
            groups: [groupSnapshot],
            sidebarOrder: [.group(groupSnapshot.id)]
        )
        manager.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(manager.groups.count, 1, "Group should be restored even with stale workspace IDs")
        XCTAssertTrue(manager.groups[0].workspaceIds.isEmpty, "Stale workspace ID should be pruned")
    }

    func testDecodeGroupedSnapshotWithoutSidebarOrderPreservesInterleaving() throws {
        let leadingWorkspace = SessionWorkspaceSnapshot(
            id: UUID(),
            processTitle: "Leading",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let groupedWorkspaceA = SessionWorkspaceSnapshot(
            id: UUID(),
            processTitle: "Grouped A",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let trailingWorkspace = SessionWorkspaceSnapshot(
            id: UUID(),
            processTitle: "Trailing",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let groupedWorkspaceB = SessionWorkspaceSnapshot(
            id: UUID(),
            processTitle: "Grouped B",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let groupSnapshot = SessionGroupSnapshot(
            id: UUID(),
            name: "Backend",
            color: nil,
            isCollapsed: false,
            workspaceIds: [groupedWorkspaceA.id, groupedWorkspaceB.id]
        )
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [leadingWorkspace, groupedWorkspaceA, trailingWorkspace, groupedWorkspaceB],
            groups: [groupSnapshot],
            sidebarOrder: [.workspace(leadingWorkspace.id), .group(groupSnapshot.id), .workspace(trailingWorkspace.id)]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        jsonObject.removeValue(forKey: "sidebarOrder")
        let missingSidebarOrderData = try JSONSerialization.data(withJSONObject: jsonObject)

        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: missingSidebarOrderData)
        XCTAssertEqual(decoded.sidebarOrder, [.workspace(leadingWorkspace.id), .group(groupSnapshot.id), .workspace(trailingWorkspace.id)])

        let restored = TabManager()
        restored.restoreSessionSnapshot(decoded)
        XCTAssertEqual(restored.sidebarOrder, [.workspace(leadingWorkspace.id), .group(groupSnapshot.id), .workspace(trailingWorkspace.id)])
        XCTAssertEqual(
            restored.orderedSidebarWorkspaceIds(),
            [leadingWorkspace.id, groupedWorkspaceA.id, groupedWorkspaceB.id, trailingWorkspace.id]
        )
    }
}
