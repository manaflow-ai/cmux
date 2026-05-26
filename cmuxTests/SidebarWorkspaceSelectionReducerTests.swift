import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWorkspaceSelectionReducerTests: XCTestCase {
    func testShiftClickKeepsOriginalAnchorAcrossRepeatedRanges() {
        let workspaceIds = ["0", "1", "2", "3", "4", "5"]
        let firstRange = SidebarWorkspaceSelectionReducer.select(
            workspaceId: "1",
            index: 1,
            workspaceIds: workspaceIds,
            selectedIds: ["4"],
            anchorIndex: 4,
            isCommand: false,
            isShift: true
        )
        XCTAssertEqual(firstRange.selectedIds, ["1", "2", "3", "4"])
        XCTAssertEqual(firstRange.anchorIndex, 4)

        let secondRange = SidebarWorkspaceSelectionReducer.select(
            workspaceId: "2",
            index: 2,
            workspaceIds: workspaceIds,
            selectedIds: firstRange.selectedIds,
            anchorIndex: firstRange.anchorIndex,
            isCommand: false,
            isShift: true
        )
        XCTAssertEqual(secondRange.selectedIds, ["2", "3", "4"])
        XCTAssertEqual(secondRange.anchorIndex, 4)
    }

    func testPlainClickMovesAnchorToClickedWorkspace() {
        let result = SidebarWorkspaceSelectionReducer.select(
            workspaceId: "2",
            index: 2,
            workspaceIds: ["0", "1", "2"],
            selectedIds: ["0", "1"],
            anchorIndex: 0,
            isCommand: false,
            isShift: false
        )

        XCTAssertEqual(result.selectedIds, ["2"])
        XCTAssertEqual(result.anchorIndex, 2)
    }

    func testCommandShiftAddsRangeWithoutMovingAnchor() {
        let result = SidebarWorkspaceSelectionReducer.select(
            workspaceId: "3",
            index: 3,
            workspaceIds: ["0", "1", "2", "3"],
            selectedIds: ["0"],
            anchorIndex: 1,
            isCommand: true,
            isShift: true
        )

        XCTAssertEqual(result.selectedIds, ["0", "1", "2", "3"])
        XCTAssertEqual(result.anchorIndex, 1)
    }
}
