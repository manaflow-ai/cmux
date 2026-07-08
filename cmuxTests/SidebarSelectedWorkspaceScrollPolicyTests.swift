import AppKit
import CmuxSidebar
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarSelectedWorkspaceScrollPolicyTests {
    @Test func skipsScrollWhenSelectedWorkspaceIdIsNil() {
        #expect(!SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: nil as String?,
            oldWorkspaceIds: ["a"],
            newWorkspaceIds: ["a"]
        ))
    }

    @Test func requestsScrollWhenSelectedWorkspaceFirstAppears() {
        #expect(SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "b",
            oldWorkspaceIds: ["a"],
            newWorkspaceIds: ["a", "b"]
        ))
    }

    @Test func requestsScrollWhenSelectedWorkspaceMovesToTop() {
        #expect(SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "c",
            oldWorkspaceIds: ["a", "b", "c"],
            newWorkspaceIds: ["c", "a", "b"]
        ))
    }

    @Test func requestsScrollWhenAnotherReorderShiftsSelectedWorkspaceIndex() {
        #expect(SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "b",
            oldWorkspaceIds: ["a", "b", "c"],
            newWorkspaceIds: ["c", "a", "b"]
        ))
    }

    @Test func skipsScrollWhenReorderLeavesSelectedWorkspaceIndexUnchanged() {
        #expect(!SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "a",
            oldWorkspaceIds: ["a", "b", "c"],
            newWorkspaceIds: ["a", "c", "b"]
        ))
    }

    @Test func skipsScrollWhenSelectedWorkspaceIsMissing() {
        #expect(!SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "b",
            oldWorkspaceIds: ["a", "b"],
            newWorkspaceIds: ["a", "c"]
        ))
    }

    @Test func scrollTargetIsSelfWithoutGroup() {
        let workspaceId = UUID()
        #expect(SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
            selectedWorkspaceId: workspaceId,
            group: nil
        ) == workspaceId)
    }

    @Test func scrollTargetIsSelfInExpandedGroup() {
        let workspaceId = UUID()
        #expect(SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
            selectedWorkspaceId: workspaceId,
            group: makeGroup(isCollapsed: false, anchorWorkspaceId: UUID())
        ) == workspaceId)
    }

    @Test func scrollTargetIsGroupAnchorWhenGroupIsCollapsed() {
        let anchorId = UUID()
        #expect(SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
            selectedWorkspaceId: UUID(),
            group: makeGroup(isCollapsed: true, anchorWorkspaceId: anchorId)
        ) == anchorId)
    }

    private func makeGroup(isCollapsed: Bool, anchorWorkspaceId: UUID) -> WorkspaceGroup {
        WorkspaceGroup(
            id: UUID(),
            name: "group",
            isCollapsed: isCollapsed,
            isPinned: false,
            anchorWorkspaceId: anchorWorkspaceId,
            customColor: nil,
            iconSymbol: nil
        )
    }
}
