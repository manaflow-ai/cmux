import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceGroupTests: XCTestCase {

    private func makeTabManager() -> TabManager {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        return manager
    }

    func testCreateGroupInsertsFreshAnchorAndGroupsChildren() {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let initialCount = manager.tabs.count

        let gid = manager.createWorkspaceGroup(name: "Test Group", childWorkspaceIds: children)
        XCTAssertNotNil(gid)
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "Anchor workspace should be added")
        guard let groupId = gid,
              let group = manager.workspaceGroups.first(where: { $0.id == groupId }) else {
            XCTFail("Group not found")
            return
        }
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertFalse(group.isCollapsed)
        XCTAssertFalse(group.isPinned)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == group.anchorWorkspaceId }))

        let membersIds = manager.tabs.filter { $0.groupId == groupId }.map(\.id)
        XCTAssertEqual(membersIds.count, children.count + 1)
        XCTAssertTrue(membersIds.contains(group.anchorWorkspaceId))
        for childId in children {
            XCTAssertTrue(membersIds.contains(childId), "Child \(childId) should be in the group")
        }
    }

    func testRemoveNonAnchorPreservesGroup() {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        let firstChild = children[0]

        manager.removeWorkspaceFromGroup(workspaceId: firstChild)

        XCTAssertNotNil(manager.workspaceGroups.first(where: { $0.id == groupId }), "Group should still exist when a non-anchor is removed")
        XCTAssertNil(manager.tabs.first(where: { $0.id == firstChild })?.groupId)
    }

    func testRemoveAnchorViaRemoveWorkspaceFromGroupDissolves() {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        guard let group = manager.workspaceGroups.first(where: { $0.id == groupId }) else {
            XCTFail("Group missing")
            return
        }

        manager.removeWorkspaceFromGroup(workspaceId: group.anchorWorkspaceId)

        XCTAssertNil(manager.workspaceGroups.first(where: { $0.id == groupId }), "Group should dissolve when anchor is removed")
        XCTAssertTrue(manager.tabs.allSatisfy { $0.groupId == nil }, "All workspaces should be ungrouped after dissolve")
    }

    func testClosingAnchorWorkspaceDissolvesGroup() {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        // Silence the confirm dialog so closeTab proceeds.
        WorkspaceGroupAnchorCloseSettings.setSuppressed(true)
        defer { WorkspaceGroupAnchorCloseSettings.setSuppressed(false) }
        guard let group = manager.workspaceGroups.first(where: { $0.id == groupId }),
              let anchor = manager.tabs.first(where: { $0.id == group.anchorWorkspaceId }) else {
            XCTFail("Anchor missing")
            return
        }

        manager.closeWorkspace(anchor)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == anchor.id }), "Anchor should be removed")
        XCTAssertNil(manager.workspaceGroups.first(where: { $0.id == groupId }), "Group should dissolve")
        XCTAssertTrue(manager.tabs.allSatisfy { $0.groupId == nil }, "Remaining workspaces should be ungrouped")
    }

    func testUngroupKeepsAllWorkspaces() {
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        let allIdsBefore = Set(manager.tabs.map(\.id))

        manager.ungroupWorkspaceGroup(groupId: groupId)

        XCTAssertNil(manager.workspaceGroups.first(where: { $0.id == groupId }))
        XCTAssertEqual(Set(manager.tabs.map(\.id)), allIdsBefore)
        XCTAssertTrue(manager.tabs.allSatisfy { $0.groupId == nil })
    }

    func testDeleteClosesMembersAndRemovesGroup() {
        let manager = makeTabManager()
        // Add a workspace that is NOT in the group so that closing every
        // member still leaves at least one survivor and the
        // `tabs.count <= 1` guard inside `closeWorkspace` is never hit.
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let groupChildren = Array(manager.tabs.prefix(2)).map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: groupChildren)!
        let memberIdsBefore = Set(manager.tabs.filter { $0.groupId == groupId }.map(\.id))
        XCTAssertFalse(memberIdsBefore.isEmpty)

        let closed = manager.deleteWorkspaceGroup(groupId: groupId)

        XCTAssertEqual(closed, memberIdsBefore.count)
        XCTAssertNil(manager.workspaceGroups.first(where: { $0.id == groupId }))
        XCTAssertTrue(memberIdsBefore.allSatisfy { id in
            !manager.tabs.contains(where: { $0.id == id })
        }, "All former member workspaces should be closed")
    }

    func testDeleteKeepsLastWorkspaceUngrouped() {
        // When the group contains every workspace in the window,
        // `closeWorkspace` refuses to drop the last tab. The lingering tab
        // must be detached from the group so the user isn't left with a
        // stale `groupId` pointing at a removed group.
        let manager = makeTabManager()
        let children = manager.tabs.map(\.id)
        let groupId = manager.createWorkspaceGroup(name: "G", childWorkspaceIds: children)!
        let groupSize = manager.tabs.filter { $0.groupId == groupId }.count

        let closed = manager.deleteWorkspaceGroup(groupId: groupId)

        XCTAssertEqual(manager.tabs.count, 1, "Last workspace must survive the close-all guard")
        XCTAssertEqual(closed, groupSize - 1, "Only the workspaces that actually closed should be counted")
        XCTAssertNil(manager.workspaceGroups.first(where: { $0.id == groupId }))
        XCTAssertTrue(manager.tabs.allSatisfy { $0.groupId == nil })
    }

    func testPinnedWorkspaceCannotJoinGroupViaCreate() {
        let manager = makeTabManager()
        let pinnedWs = manager.tabs[0]
        manager.setPinned(pinnedWs, pinned: true)

        let unpinnedWs = manager.tabs.first(where: { !$0.isPinned })!
        let groupId = manager.createWorkspaceGroup(
            name: "Mixed",
            childWorkspaceIds: [pinnedWs.id, unpinnedWs.id]
        )
        XCTAssertNotNil(groupId)
        XCTAssertNil(pinnedWs.groupId, "Pinned workspace must not gain a group")
        XCTAssertEqual(unpinnedWs.groupId, groupId)
    }

    func testToggleCollapsedAndPinned() {
        let manager = makeTabManager()
        let groupId = manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [manager.tabs[0].id]
        )!

        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        XCTAssertEqual(manager.workspaceGroups.first { $0.id == groupId }?.isCollapsed, true)
        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        XCTAssertEqual(manager.workspaceGroups.first { $0.id == groupId }?.isCollapsed, false)

        manager.toggleWorkspaceGroupPinned(groupId: groupId)
        XCTAssertEqual(manager.workspaceGroups.first { $0.id == groupId }?.isPinned, true)
    }

    func testSetAnchorRequiresMember() {
        let manager = makeTabManager()
        let memberId = manager.tabs[0].id
        let outsiderId = manager.tabs[1].id
        let groupId = manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [memberId]
        )!
        let originalAnchor = manager.workspaceGroups.first { $0.id == groupId }!.anchorWorkspaceId

        // Outsider is not a member, must be rejected.
        manager.setWorkspaceGroupAnchor(groupId: groupId, workspaceId: outsiderId)
        XCTAssertEqual(manager.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId, originalAnchor)

        // The original child member is valid.
        manager.setWorkspaceGroupAnchor(groupId: groupId, workspaceId: memberId)
        XCTAssertEqual(manager.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId, memberId)
    }

    func testSessionSnapshotRoundtripPreservesGroups() {
        let manager = makeTabManager()
        let child = manager.tabs[0].id
        let groupId = manager.createWorkspaceGroup(name: "Round Trip", childWorkspaceIds: [child])!
        manager.toggleWorkspaceGroupPinned(groupId: groupId)
        manager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        manager.setWorkspaceGroupColor(groupId: groupId, hex: "#123456")
        manager.setWorkspaceGroupIcon(groupId: groupId, symbol: "leaf.fill")

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertNotNil(snapshot.workspaceGroups)
        let g = snapshot.workspaceGroups!.first { $0.id == groupId }
        XCTAssertNotNil(g)
        XCTAssertEqual(g?.name, "Round Trip")
        XCTAssertEqual(g?.isCollapsed, true)
        XCTAssertEqual(g?.isPinned, true)
        XCTAssertEqual(g?.customColor, "#123456")
        XCTAssertEqual(g?.iconSymbol, "leaf.fill")

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)
        let restoredGroup = restored.workspaceGroups.first { $0.id == groupId }
        XCTAssertNotNil(restoredGroup)
        XCTAssertEqual(restoredGroup?.name, "Round Trip")
        XCTAssertEqual(restoredGroup?.isCollapsed, true)
        XCTAssertEqual(restoredGroup?.isPinned, true)
        XCTAssertEqual(restoredGroup?.customColor, "#123456")
        XCTAssertEqual(restoredGroup?.iconSymbol, "leaf.fill")
    }
}
