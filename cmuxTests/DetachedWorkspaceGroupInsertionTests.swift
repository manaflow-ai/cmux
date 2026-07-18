import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct DetachedWorkspaceGroupInsertionTests {
    @Test
    @MainActor
    func insertionOverrideDoesNotSplitWorkspaceGroup() throws {
        let manager = TabManager()
        let firstChild = manager.tabs[0]
        let secondChild = manager.addWorkspace()
        let groupId = try #require(manager.createWorkspaceGroup(
            name: "Group",
            childWorkspaceIds: [firstChild.id, secondChild.id]
        ))
        let group = try #require(manager.workspaceGroups.first(where: { $0.id == groupId }))
        let source = manager.addWorkspace()
        manager.selectWorkspace(source)

        let groupAnchorIndex = try #require(
            manager.tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId })
        )
        let panelId = try #require(source.focusedPanelId)
        let detached = try #require(source.detachSurface(panelId: panelId))
        let inserted = try #require(manager.addWorkspace(
            fromDetachedSurface: detached,
            insertionIndexOverride: groupAnchorIndex + 1
        ))

        let groupIndexes = manager.tabs.indices.filter { manager.tabs[$0].groupId == groupId }
        let firstGroupIndex = try #require(groupIndexes.first)
        let lastGroupIndex = try #require(groupIndexes.last)
        let insertedIndex = try #require(manager.tabs.firstIndex(where: { $0.id == inserted.id }))
        #expect(groupIndexes == Array(firstGroupIndex...lastGroupIndex))
        #expect(insertedIndex == lastGroupIndex + 1)
    }
}
