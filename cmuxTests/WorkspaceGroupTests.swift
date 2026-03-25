import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceGroupTests: XCTestCase {

    // MARK: - Workspace Child Properties

    func testWorkspaceDefaultsToNoChildren() {
        let ws = Workspace(title: "Test")
        XCTAssertTrue(ws.childWorkspaceIds.isEmpty)
        XCTAssertFalse(ws.hasChildren)
        XCTAssertFalse(ws.isCollapsed)
    }

    func testWorkspaceHasChildrenWhenChildIdsNonEmpty() {
        let ws = Workspace(title: "Parent")
        ws.childWorkspaceIds = [UUID()]
        XCTAssertTrue(ws.hasChildren)
    }

    func testWorkspaceIsCollapsedToggles() {
        let ws = Workspace(title: "Parent")
        ws.childWorkspaceIds = [UUID()]
        XCTAssertFalse(ws.isCollapsed)
        ws.isCollapsed = true
        XCTAssertTrue(ws.isCollapsed)
    }

    // MARK: - SidebarItem (typealias for UUID)

    func testSidebarItemIsUUID() {
        let id = UUID()
        let item: SidebarItem = id
        XCTAssertEqual(item, id)
    }
}
