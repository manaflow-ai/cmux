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
}
