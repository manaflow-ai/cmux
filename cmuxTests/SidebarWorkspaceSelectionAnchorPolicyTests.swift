import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Sidebar workspace selection anchor policy")
struct SidebarWorkspaceSelectionAnchorPolicyTests {
    @MainActor
    @Test
    func anchorWorkspaceIdReadsTheExistingAnchorIdentity() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        #expect(
            SidebarWorkspaceSelectionSyncPolicy().anchorWorkspaceId(
                existingAnchorIndex: 1,
                liveWorkspaceIds: [first, second, third]
            ) == second
        )
        #expect(
            SidebarWorkspaceSelectionSyncPolicy().anchorWorkspaceId(
                existingAnchorIndex: 3,
                liveWorkspaceIds: [first, second, third]
            ) == nil
        )
    }

    @MainActor
    @Test
    func reorderKeepsRangeAnchorByWorkspaceIdentityInsteadOfFocus() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()

        let anchorIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceReorder(
            preferredAnchorWorkspaceId: first,
            selectedWorkspaceIds: [first, second, third],
            focusedWorkspaceId: third,
            liveWorkspaceIds: [second, third, first, fourth]
        )

        #expect(anchorIndex == 2)
    }

    @MainActor
    @Test
    func reorderFallsBackToFocusedWorkspaceWhenRangeAnchorIsNoLongerSelected() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let anchorIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceReorder(
            preferredAnchorWorkspaceId: first,
            selectedWorkspaceIds: [second, third],
            focusedWorkspaceId: third,
            liveWorkspaceIds: [second, third, first]
        )

        #expect(anchorIndex == 1)
    }

    @MainActor
    @Test
    func shiftClickAnchorFallsBackToSingleSidebarSelection() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let anchorIndex = SidebarWorkspaceSelectionSyncPolicy().shiftClickAnchorIndex(
            existingAnchorIndex: nil,
            selectedWorkspaceIds: [first],
            focusedWorkspaceId: second,
            liveWorkspaceIds: [first, second, third]
        )

        #expect(anchorIndex == 0)
    }

    @MainActor
    @Test
    func shiftClickKeepsExistingAnchorWhileFocusMoves() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let anchorIndex = SidebarWorkspaceSelectionSyncPolicy().shiftClickAnchorIndex(
            existingAnchorIndex: 0,
            selectedWorkspaceIds: [first, second],
            focusedWorkspaceId: second,
            liveWorkspaceIds: [first, second, third]
        )
        let nextAnchorIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceClick(
            isShiftClick: true,
            resolvedShiftAnchorIndex: anchorIndex,
            clickedIndex: 2
        )

        #expect(anchorIndex == 0)
        #expect(nextAnchorIndex == 0)
    }

    @MainActor
    @Test
    func nonShiftClickMovesSidebarSelectionAnchor() {
        let nextAnchorIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceClick(
            isShiftClick: false,
            resolvedShiftAnchorIndex: 0,
            clickedIndex: 2
        )

        #expect(nextAnchorIndex == 2)
    }
}
