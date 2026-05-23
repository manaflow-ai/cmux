import CoreGraphics
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWorkspaceDropPlannerTests: XCTestCase {
    func testWorkspaceDropCenterTargetsExistingWorkspace() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 56),
            targets: targets
        )

        XCTAssertEqual(action, .existingWorkspace(second))
    }

    func testWorkspaceDropTopEdgeCreatesWorkspaceBeforeTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 42),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 1,
                indicator: SidebarDropIndicator(tabId: second, edge: .top)
            )
        )
    }

    func testWorkspaceDropBottomEdgeCreatesWorkspaceAfterTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 65),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 2,
                indicator: SidebarDropIndicator(tabId: nil, edge: .bottom)
            )
        )
    }

    func testWorkspaceDropGapCreatesWorkspaceBeforeNextTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 36),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 1,
                indicator: SidebarDropIndicator(tabId: second, edge: .top)
            )
        )
    }

    func testWorkspaceDropAfterLastRowCreatesWorkspaceAtEnd() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 92),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 2,
                indicator: SidebarDropIndicator(tabId: nil, edge: .bottom)
            )
        )
    }

    func testWorkspaceDropKeepsNewWorkspaceAfterPinnedRows() {
        let pinnedA = UUID()
        let pinnedB = UUID()
        let unpinned = UUID()
        let targets = workspaceDropTargets([pinnedA, pinnedB, unpinned], pinnedIds: [pinnedA, pinnedB])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 2),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 2,
                indicator: SidebarDropIndicator(tabId: unpinned, edge: .top)
            )
        )
    }

    func testBrowserStackDropCanInsertAtStartOfNextSection() throws {
        let openA = UUID()
        let openB = UUID()
        let readingA = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: openB, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading")
        ]

        let move = try XCTUnwrap(ExtensionSidebarBrowserStackDropPlanner.move(
            draggedWorkspaceId: openB,
            insertionPosition: 2,
            orderedRows: rows,
            preferredTargetSectionId: "reading"
        ))

        XCTAssertEqual(move.workspaceId, openB)
        XCTAssertEqual(move.sourceSectionId, "open")
        XCTAssertEqual(move.targetSectionId, "reading")
        XCTAssertEqual(move.targetIndex, 0)
    }

    func testBrowserStackAdjacentTopDropPreservesNextSectionBoundary() throws {
        let openA = UUID()
        let openB = UUID()
        let readingA = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: openB, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading")
        ]

        let indicator = ExtensionSidebarBrowserStackDropPlanner.sectionBoundaryIndicator(
            draggedWorkspaceId: openB,
            targetWorkspaceId: readingA,
            pointerY: 2,
            targetHeight: 34,
            orderedRows: rows
        )

        XCTAssertEqual(indicator, SidebarDropIndicator(tabId: readingA, edge: .top))
    }

    func testBrowserStackAdjacentBottomDropPreservesPreviousSectionBoundary() throws {
        let openA = UUID()
        let readingA = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading")
        ]

        let indicator = ExtensionSidebarBrowserStackDropPlanner.sectionBoundaryIndicator(
            draggedWorkspaceId: readingA,
            targetWorkspaceId: openA,
            pointerY: 32,
            targetHeight: 34,
            orderedRows: rows
        )

        XCTAssertEqual(indicator, SidebarDropIndicator(tabId: openA, edge: .bottom))
    }

    func testBrowserStackDropBoundaryBottomStaysInPreviousSection() throws {
        let openA = UUID()
        let readingA = UUID()
        let readingB = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingB, sectionId: "reading")
        ]

        let move = try XCTUnwrap(ExtensionSidebarBrowserStackDropPlanner.move(
            draggedWorkspaceId: readingB,
            insertionPosition: 1,
            orderedRows: rows,
            preferredTargetSectionId: "open"
        ))

        XCTAssertEqual(move.workspaceId, readingB)
        XCTAssertEqual(move.sourceSectionId, "reading")
        XCTAssertEqual(move.targetSectionId, "open")
        XCTAssertEqual(move.targetIndex, 1)
    }

    func testBrowserStackDropBoundaryBottomPrefersTargetRowSection() throws {
        let openA = UUID()
        let openB = UUID()
        let readingA = UUID()
        let readingB = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: openB, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingB, sectionId: "reading")
        ]

        let preferredSectionId = ExtensionSidebarBrowserStackDropPlanner.preferredSectionId(
            targetWorkspaceId: openB,
            indicator: SidebarDropIndicator(tabId: readingA, edge: .top),
            orderedRows: rows
        )

        XCTAssertEqual(preferredSectionId, "open")

        let move = try XCTUnwrap(ExtensionSidebarBrowserStackDropPlanner.move(
            draggedWorkspaceId: readingB,
            insertionPosition: 2,
            orderedRows: rows,
            preferredTargetSectionId: preferredSectionId
        ))
        XCTAssertEqual(move.workspaceId, readingB)
        XCTAssertEqual(move.sourceSectionId, "reading")
        XCTAssertEqual(move.targetSectionId, "open")
        XCTAssertEqual(move.targetIndex, 2)
    }

    private func workspaceDropTargets(
        _ ids: [UUID],
        pinnedIds: Set<UUID> = []
    ) -> [SidebarDropPlanner.WorkspaceDropTarget] {
        ids.enumerated().map { index, id in
            SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: id,
                isPinned: pinnedIds.contains(id),
                frame: CGRect(x: 0, y: CGFloat(index * 40), width: 180, height: 32)
            )
        }
    }
}
