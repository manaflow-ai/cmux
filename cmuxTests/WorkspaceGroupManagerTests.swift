import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceGroupManagerTests: XCTestCase {
    var tabManager: TabManager!
    var manager: WorkspaceGroupManager!

    override func setUp() {
        super.setUp()
        tabManager = TabManager()
        manager = WorkspaceGroupManager(tabManager: tabManager)
    }

    // MARK: - Standalone Registration

    func testRegisterWorkspaceAppearsInItems() {
        let wsId = tabManager.tabs[0].id
        manager.registerWorkspaceAsStandalone(wsId)
        XCTAssertTrue(manager.items.contains(wsId))
    }

    func testDuplicateRegistrationIgnored() {
        let wsId = tabManager.tabs[0].id
        manager.registerWorkspaceAsStandalone(wsId)
        manager.registerWorkspaceAsStandalone(wsId)
        XCTAssertEqual(manager.items.filter { $0 == wsId }.count, 1)
    }

    // MARK: - Child Management

    func testAddChildIdAppendsToParent() {
        let parent = tabManager.tabs[0]
        let child = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(parent.id)
        manager.addChildId(child.id, to: parent.id)
        XCTAssertTrue(parent.childWorkspaceIds.contains(child.id))
    }

    func testRemoveChildIdFromParent() {
        let parent = tabManager.tabs[0]
        let child = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(parent.id)
        parent.childWorkspaceIds.append(child.id)
        manager.removeChildId(child.id, from: parent.id)
        XCTAssertFalse(parent.childWorkspaceIds.contains(child.id))
    }

    // MARK: - Remove Workspace

    func testRemoveWorkspaceClearsFromItems() {
        let wsId = tabManager.tabs[0].id
        manager.registerWorkspaceAsStandalone(wsId)
        manager.removeWorkspace(wsId)
        XCTAssertFalse(manager.items.contains(wsId))
    }

    func testRemoveWorkspaceClearsFromParentChildren() {
        let parent = tabManager.tabs[0]
        let child = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(parent.id)
        parent.childWorkspaceIds.append(child.id)
        manager.removeWorkspace(child.id)
        XCTAssertFalse(parent.childWorkspaceIds.contains(child.id))
    }

    // MARK: - Depth Queries

    func testDepthOfTopLevelIs1() {
        let wsId = tabManager.tabs[0].id
        manager.registerWorkspaceAsStandalone(wsId)
        XCTAssertEqual(manager.depthOf(workspaceId: wsId), 1)
    }

    func testDepthOfChildIs2() {
        let parent = tabManager.tabs[0]
        let child = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(parent.id)
        parent.childWorkspaceIds.append(child.id)
        XCTAssertEqual(manager.depthOf(workspaceId: child.id), 2)
    }

    func testDepthOfGrandchildIs3() {
        let grandparent = tabManager.tabs[0]
        let parent = tabManager.addWorkspace()
        let child = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(grandparent.id)
        grandparent.childWorkspaceIds.append(parent.id)
        parent.childWorkspaceIds.append(child.id)
        XCTAssertEqual(manager.depthOf(workspaceId: child.id), 3)
    }

    func testDepthOfUnknownIs0() {
        XCTAssertEqual(manager.depthOf(workspaceId: UUID()), 0)
    }

    // MARK: - Parent Workspace

    func testParentWorkspaceFindsCorrectParent() {
        let parent = tabManager.tabs[0]
        let child = tabManager.addWorkspace()
        parent.childWorkspaceIds.append(child.id)
        let found = manager.parentWorkspace(of: child.id)
        XCTAssertEqual(found?.id, parent.id)
    }

    func testParentWorkspaceReturnsNilForTopLevel() {
        let wsId = tabManager.tabs[0].id
        manager.registerWorkspaceAsStandalone(wsId)
        XCTAssertNil(manager.parentWorkspace(of: wsId))
    }

    // MARK: - Visible Workspaces

    func testVisibleWorkspacesIncludesExpandedChildren() {
        let parent = tabManager.tabs[0]
        let child = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(parent.id)
        parent.childWorkspaceIds.append(child.id)
        parent.isCollapsed = false

        let visible = manager.visibleWorkspaces()
        XCTAssertTrue(visible.contains(where: { $0.id == parent.id }))
        XCTAssertTrue(visible.contains(where: { $0.id == child.id }))
    }

    func testVisibleWorkspacesSkipsCollapsedChildren() {
        let parent = tabManager.tabs[0]
        let child = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(parent.id)
        parent.childWorkspaceIds.append(child.id)
        parent.isCollapsed = true

        let visible = manager.visibleWorkspaces()
        XCTAssertTrue(visible.contains(where: { $0.id == parent.id }))
        XCTAssertFalse(visible.contains(where: { $0.id == child.id }))
    }

    // MARK: - Toggle Collapsed

    func testToggleCollapsedFlipsState() {
        let ws = tabManager.tabs[0]
        ws.childWorkspaceIds = [UUID()]
        manager.registerWorkspaceAsStandalone(ws.id)
        XCTAssertFalse(ws.isCollapsed)
        manager.toggleCollapsed(ws.id)
        XCTAssertTrue(ws.isCollapsed)
        manager.toggleCollapsed(ws.id)
        XCTAssertFalse(ws.isCollapsed)
    }

    func testToggleCollapsedIgnoresWorkspaceWithoutChildren() {
        let ws = tabManager.tabs[0]
        manager.registerWorkspaceAsStandalone(ws.id)
        manager.toggleCollapsed(ws.id)
        XCTAssertFalse(ws.isCollapsed)
    }

    // MARK: - Descendant IDs

    func testAllDescendantIdsCollectsDeep() {
        let grandparent = tabManager.tabs[0]
        let parent = tabManager.addWorkspace()
        let child = tabManager.addWorkspace()
        grandparent.childWorkspaceIds = [parent.id]
        parent.childWorkspaceIds = [child.id]

        let descendants = manager.allDescendantIds(of: grandparent.id)
        XCTAssertEqual(Set(descendants), [parent.id, child.id])
    }

    // MARK: - Indent (Tab)

    func testIndentTopLevelBecomesSiblingChild() {
        let ws1 = tabManager.tabs[0]
        let ws2 = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(ws1.id)
        manager.registerWorkspaceAsStandalone(ws2.id)

        let result = manager.indentWorkspace(ws2.id)
        XCTAssertTrue(result)
        XCTAssertFalse(manager.items.contains(ws2.id))
        XCTAssertTrue(ws1.childWorkspaceIds.contains(ws2.id))
    }

    func testIndentFirstTopLevelDoesNothing() {
        let ws1 = tabManager.tabs[0]
        manager.registerWorkspaceAsStandalone(ws1.id)

        let result = manager.indentWorkspace(ws1.id)
        XCTAssertFalse(result)
        XCTAssertTrue(manager.items.contains(ws1.id))
    }

    func testIndentChildBecomesSiblingChild() {
        let parent = tabManager.tabs[0]
        let child1 = tabManager.addWorkspace()
        let child2 = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(parent.id)
        parent.childWorkspaceIds = [child1.id, child2.id]

        let result = manager.indentWorkspace(child2.id)
        XCTAssertTrue(result)
        XCTAssertTrue(child1.childWorkspaceIds.contains(child2.id))
        XCTAssertFalse(parent.childWorkspaceIds.contains(child2.id))
    }

    func testIndentBlockedByDepthConstraint() {
        // ws1 -> ws2 -> ws3 (depth 3), try to indent ws2 under ws1 again would exceed
        let ws1 = tabManager.tabs[0]
        let ws2 = tabManager.addWorkspace()
        let ws3 = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(ws1.id)
        manager.registerWorkspaceAsStandalone(ws2.id)
        ws2.childWorkspaceIds = [ws3.id]

        // ws2 is at depth 1, ws3 at depth 2 in ws2's subtree
        // Indenting ws2 under ws1: ws2 becomes depth 2, ws3 becomes depth 3 — allowed
        let result = manager.indentWorkspace(ws2.id)
        XCTAssertTrue(result)

        // Now ws1 -> ws2 -> ws3 (ws3 is at depth 3)
        // Create ws4 and try to indent under ws3 — would exceed depth 3
        let ws4 = tabManager.addWorkspace()
        ws3.childWorkspaceIds = [ws4.id]
        // ws4 is now at depth 4 which is the state but indenting ws3 further isn't possible
        // since ws3 is a child of ws2 which is a child of ws1
    }

    func testIndentPreservesChildren() {
        let ws1 = tabManager.tabs[0]
        let ws2 = tabManager.addWorkspace()
        let ws3 = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(ws1.id)
        manager.registerWorkspaceAsStandalone(ws2.id)
        ws2.childWorkspaceIds = [ws3.id]

        let result = manager.indentWorkspace(ws2.id)
        XCTAssertTrue(result)
        // ws2's children should remain
        XCTAssertTrue(ws2.childWorkspaceIds.contains(ws3.id))
        // ws2 is now child of ws1
        XCTAssertTrue(ws1.childWorkspaceIds.contains(ws2.id))
    }

    // MARK: - Outdent (Shift-Tab)

    func testOutdentChildBecomesTopLevel() {
        let parent = tabManager.tabs[0]
        let child = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(parent.id)
        parent.childWorkspaceIds = [child.id]

        let result = manager.outdentWorkspace(child.id)
        XCTAssertTrue(result)
        XCTAssertFalse(parent.childWorkspaceIds.contains(child.id))
        // child should be in items right after parent
        guard let parentIdx = manager.items.firstIndex(of: parent.id),
              let childIdx = manager.items.firstIndex(of: child.id) else {
            XCTFail("Expected both in items")
            return
        }
        XCTAssertEqual(childIdx, parentIdx + 1)
    }

    func testOutdentTopLevelDoesNothing() {
        let ws = tabManager.tabs[0]
        manager.registerWorkspaceAsStandalone(ws.id)

        let result = manager.outdentWorkspace(ws.id)
        XCTAssertFalse(result)
    }

    func testOutdentGrandchildBecomesChild() {
        let gp = tabManager.tabs[0]
        let parent = tabManager.addWorkspace()
        let child = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(gp.id)
        gp.childWorkspaceIds = [parent.id]
        parent.childWorkspaceIds = [child.id]

        let result = manager.outdentWorkspace(child.id)
        XCTAssertTrue(result)
        XCTAssertFalse(parent.childWorkspaceIds.contains(child.id))
        // child should be in grandparent's children right after parent
        guard let parentIdx = gp.childWorkspaceIds.firstIndex(of: parent.id),
              let childIdx = gp.childWorkspaceIds.firstIndex(of: child.id) else {
            XCTFail("Expected both in grandparent's children")
            return
        }
        XCTAssertEqual(childIdx, parentIdx + 1)
    }

    func testOutdentPreservesChildren() {
        let parent = tabManager.tabs[0]
        let child = tabManager.addWorkspace()
        let grandchild = tabManager.addWorkspace()
        manager.registerWorkspaceAsStandalone(parent.id)
        parent.childWorkspaceIds = [child.id]
        child.childWorkspaceIds = [grandchild.id]

        let result = manager.outdentWorkspace(child.id)
        XCTAssertTrue(result)
        // child keeps its children
        XCTAssertTrue(child.childWorkspaceIds.contains(grandchild.id))
    }
}
