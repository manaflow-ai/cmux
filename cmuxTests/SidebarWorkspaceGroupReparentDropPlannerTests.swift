import CoreGraphics
import Foundation
import Testing

import CmuxFoundation

private func require<T>(_ value: T?, _ message: String? = nil) throws -> T {
    _ = message
    return try #require(value)
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String? = nil) {
    _ = message
    #expect(lhs == rhs)
}

@Suite struct SidebarWorkspaceGroupReparentDropPlannerTests {
    @Test func groupHeaderCenterDropReparentsDraggedFolder() throws {
        let fixture = GroupReparentFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 12, y: 56), draggedWorkspaceId: fixture.childAnchor)
        ))

        #expect(plan.indicator == nil)
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.parentGroupId))
        guard case .reparentGroup(let groupId, let parentGroupId) = plan.action else {
            Issue.record("Expected group reparent plan")
            return
        }
        expectEqual(groupId, fixture.childGroupId)
        expectEqual(parentGroupId, fixture.parentGroupId)
    }

    @Test func groupHeaderCenterDropRejectsFolderReparentCycle() {
        let fixture = GroupReparentFixture(childIsNestedUnderParent: true)

        let plan = SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(
                point: CGPoint(x: 12, y: 96),
                draggedWorkspaceId: fixture.parentAnchor
            )
        )

        if case .reparentGroup = plan?.action {
            Issue.record("Cycle candidate should not produce a group reparent plan")
        }
    }
}

private struct GroupReparentFixture {
    let parentAnchor = UUID()
    let childAnchor = UUID()
    let parentGroupId = UUID()
    let childGroupId = UUID()
    let childIsNestedUnderParent: Bool

    init(childIsNestedUnderParent: Bool = false) {
        self.childIsNestedUnderParent = childIsNestedUnderParent
    }

    func request(point: CGPoint, draggedWorkspaceId: UUID) -> SidebarWorkspaceReorderDropRequest {
        SidebarWorkspaceReorderDropRequest(
            point: point,
            draggedWorkspaceId: draggedWorkspaceId,
            workspaces: [
                SidebarWorkspaceReorderWorkspaceSnapshot(id: parentAnchor, isPinned: false, groupId: parentGroupId),
                SidebarWorkspaceReorderWorkspaceSnapshot(id: childAnchor, isPinned: false, groupId: childGroupId)
            ],
            groups: [
                SidebarWorkspaceReorderGroupSnapshot(id: parentGroupId, anchorWorkspaceId: parentAnchor, isPinned: false),
                SidebarWorkspaceReorderGroupSnapshot(
                    id: childGroupId,
                    anchorWorkspaceId: childAnchor,
                    isPinned: false,
                    parentGroupId: childIsNestedUnderParent ? parentGroupId : nil
                )
            ],
            targets: [
                SidebarWorkspaceReorderDropTarget(
                    workspaceId: parentAnchor,
                    groupId: parentGroupId,
                    isGroupHeader: true,
                    frame: CGRect(x: 0, y: 40, width: 180, height: 32)
                ),
                SidebarWorkspaceReorderDropTarget(
                    workspaceId: childAnchor,
                    groupId: childGroupId,
                    isGroupHeader: true,
                    frame: CGRect(x: 12, y: 80, width: 168, height: 32)
                )
            ]
        )
    }
}
