import Foundation
import Testing
import SwiftUI

import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar workspace render-item group facts")
struct SidebarWorkspaceRenderItemGroupFactsTests {

    private func makeGroup(id: UUID, customColor: String? = nil) -> WorkspaceGroup {
        WorkspaceGroup(
            id: id,
            name: "Group",
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: UUID(),
            customColor: customColor,
            iconSymbol: nil
        )
    }

    // MARK: First rendered row

    @Test func firstRenderedRowReturnsLeadingHeader() {
        let groupId = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: groupId, anchorWorkspaceId: UUID()),
            .workspace(workspaceId: UUID()),
        ]

        #expect(SidebarWorkspaceRenderItem.firstRenderedRowId(
            items: items,
            isRendered: { _ in true }
        ) == .group(groupId))
    }

    @Test func firstRenderedRowReturnsLeadingRenderedWorkspace() {
        let leading = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .workspace(workspaceId: leading),
            .workspace(workspaceId: UUID()),
        ]

        #expect(SidebarWorkspaceRenderItem.firstRenderedRowId(
            items: items,
            isRendered: { _ in true }
        ) == .workspace(leading))
    }

    @Test func firstRenderedRowSkipsLeadingCacheMissingWorkspace() {
        let missing = UUID()
        let groupId = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .workspace(workspaceId: missing),
            .groupHeader(groupId: groupId, anchorWorkspaceId: UUID()),
            .workspace(workspaceId: UUID()),
        ]
        let rendered: Set<UUID> = []

        // The leading render item is dropped on a snapshot-cache miss, so the
        // header that becomes visually first is the first rendered row. The
        // fact takes no drag input, so it is identical whether sidebarReorderIds
        // is empty (at rest) or populated (mid-drag).
        #expect(SidebarWorkspaceRenderItem.firstRenderedRowId(
            items: items,
            isRendered: { rendered.contains($0) }
        ) == .group(groupId))
    }

    @Test func firstRenderedRowReturnsFirstRenderedWorkspaceAfterMisses() {
        let missing = UUID()
        let visible = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .workspace(workspaceId: missing),
            .workspace(workspaceId: visible),
        ]
        let rendered: Set<UUID> = [visible]

        #expect(SidebarWorkspaceRenderItem.firstRenderedRowId(
            items: items,
            isRendered: { rendered.contains($0) }
        ) == .workspace(visible))
    }

    @Test func firstRenderedRowIsNilWhenNothingRenders() {
        #expect(SidebarWorkspaceRenderItem.firstRenderedRowId(
            items: [],
            isRendered: { _ in true }
        ) == nil)

        let items: [SidebarWorkspaceRenderItem] = [
            .workspace(workspaceId: UUID()),
            .workspace(workspaceId: UUID()),
        ]
        #expect(SidebarWorkspaceRenderItem.firstRenderedRowId(
            items: items,
            isRendered: { _ in false }
        ) == nil)
    }

    // MARK: Guide run boundaries

    @Test func twoGroupsBackToBackEndEachRun() {
        let g1 = UUID(), g2 = UUID()
        let m1 = UUID(), m2 = UUID(), m3 = UUID(), m4 = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: g1, anchorWorkspaceId: UUID()),
            .workspace(workspaceId: m1),
            .workspace(workspaceId: m2),
            .groupHeader(groupId: g2, anchorWorkspaceId: UUID()),
            .workspace(workspaceId: m3),
            .workspace(workspaceId: m4),
        ]
        let membership: [UUID: UUID?] = [m1: g1, m2: g1, m3: g2, m4: g2]

        #expect(SidebarWorkspaceRenderItem.guideRunEndWorkspaceIds(
            items: items,
            groupIdByWorkspaceId: membership,
            isRendered: { _ in true }
        ) == [m2, m4])
    }

    @Test func collapsedGroupHasNoRunEnds() {
        let g1 = UUID()
        // A collapsed group's members are absent from the projection, so only
        // its header remains; nothing ends a run.
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: g1, anchorWorkspaceId: UUID()),
        ]

        #expect(SidebarWorkspaceRenderItem.guideRunEndWorkspaceIds(
            items: items,
            groupIdByWorkspaceId: [:],
            isRendered: { _ in true }
        ).isEmpty)
    }

    @Test func emptyGroupHasNoRunEnds() {
        let g1 = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: g1, anchorWorkspaceId: UUID()),
            .groupHeader(groupId: UUID(), anchorWorkspaceId: UUID()),
        ]

        #expect(SidebarWorkspaceRenderItem.guideRunEndWorkspaceIds(
            items: items,
            groupIdByWorkspaceId: [:],
            isRendered: { _ in true }
        ).isEmpty)
    }

    @Test func ungroupedRowAfterLastMemberEndsRun() {
        let g1 = UUID()
        let m1 = UUID(), root = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: g1, anchorWorkspaceId: UUID()),
            .workspace(workspaceId: m1),
            .workspace(workspaceId: root),
        ]
        let membership: [UUID: UUID?] = [m1: g1, root: nil]

        let ends = SidebarWorkspaceRenderItem.guideRunEndWorkspaceIds(
            items: items,
            groupIdByWorkspaceId: membership,
            isRendered: { _ in true }
        )
        #expect(ends == [m1])
        #expect(!ends.contains(root))
    }

    @Test func staleGroupRowAfterLastMemberEndsRun() {
        let g1 = UUID()
        let m1 = UUID(), stale = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: g1, anchorWorkspaceId: UUID()),
            .workspace(workspaceId: m1),
            .workspace(workspaceId: stale),
        ]
        // A stale group reference resolves to no effective group, so the stale
        // row is a root row: the real member ends its run and the stale row is
        // never counted as a member.
        let membership: [UUID: UUID?] = [m1: g1, stale: nil]

        let ends = SidebarWorkspaceRenderItem.guideRunEndWorkspaceIds(
            items: items,
            groupIdByWorkspaceId: membership,
            isRendered: { _ in true }
        )
        #expect(ends == [m1])
        #expect(!ends.contains(stale))
    }

    @Test func splitRunsEachEndAndRootRowIsNotMarked() {
        let g1 = UUID()
        let m1 = UUID(), root = UUID(), m2 = UUID()
        // The render item list emits the header once and tolerates a group
        // split into two runs by a root row; each run ends its own segment.
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: g1, anchorWorkspaceId: UUID()),
            .workspace(workspaceId: m1),
            .workspace(workspaceId: root),
            .workspace(workspaceId: m2),
        ]
        let membership: [UUID: UUID?] = [m1: g1, root: nil, m2: g1]

        let ends = SidebarWorkspaceRenderItem.guideRunEndWorkspaceIds(
            items: items,
            groupIdByWorkspaceId: membership,
            isRendered: { _ in true }
        )
        #expect(ends == [m1, m2])
        #expect(!ends.contains(root))
    }

    @Test func cacheMissingMemberBeforeRootRowEndsRunAtVisibleMember() {
        let g1 = UUID()
        let m1 = UUID(), missingMember = UUID(), root = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: g1, anchorWorkspaceId: UUID()),
            .workspace(workspaceId: m1),
            .workspace(workspaceId: missingMember),
            .workspace(workspaceId: root),
        ]
        let membership: [UUID: UUID?] = [m1: g1, missingMember: g1, root: nil]
        let rendered: Set<UUID> = [m1, root]

        // The cache-missing member is dropped from the projection, so the
        // guide must not cross the gap it leaves: the visible member ends its
        // run against the following root row.
        let ends = SidebarWorkspaceRenderItem.guideRunEndWorkspaceIds(
            items: items,
            groupIdByWorkspaceId: membership,
            isRendered: { rendered.contains($0) }
        )
        #expect(ends == [m1])
        #expect(!ends.contains(missingMember))
    }

    @Test func singleMemberGroupEndsItsRun() {
        let g1 = UUID()
        let m1 = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: g1, anchorWorkspaceId: UUID()),
            .workspace(workspaceId: m1),
        ]
        let membership: [UUID: UUID?] = [m1: g1]

        #expect(SidebarWorkspaceRenderItem.guideRunEndWorkspaceIds(
            items: items,
            groupIdByWorkspaceId: membership,
            isRendered: { _ in true }
        ) == [m1])
    }

    // MARK: Group color map

    @Test func groupColorMapPrefersCustomColorThenConfigThenNone() {
        let customId = UUID()
        let configId = UUID()
        let noneId = UUID()
        let groups = [
            makeGroup(id: customId, customColor: "#AABBCC"),
            makeGroup(id: configId, customColor: nil),
            makeGroup(id: noneId, customColor: nil),
        ]
        let configColors: [UUID: String] = [configId: "#112233"]

        let map = VerticalTabsSidebar.groupColorHexByGroupId(
            groups: groups,
            configColor: { configColors[$0.id] }
        )

        // Custom color wins over the directory config color.
        #expect(map[customId] == "#AABBCC")
        // No custom color falls back to the directory config color.
        #expect(map[configId] == "#112233")
        // No color at all leaves the group out of the map.
        #expect(map[noneId] == nil)
    }
}
