import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarWorkspaceGroupHeaderDropZoneTests {
    @Test func identifiesBottomEdgeAtDefaultHeight() {
        #expect(!SidebarWorkspaceGroupHeaderDropZone.isBottomEdgeDrop(locationY: 2, rowHeight: 24))
        #expect(!SidebarWorkspaceGroupHeaderDropZone.isBottomEdgeDrop(locationY: 12, rowHeight: 24))
        #expect(SidebarWorkspaceGroupHeaderDropZone.isBottomEdgeDrop(locationY: 22, rowHeight: 24))
    }

    @Test func identifiesBottomEdgeAtCompactHeight() {
        #expect(!SidebarWorkspaceGroupHeaderDropZone.isBottomEdgeDrop(locationY: 2, rowHeight: 20))
        #expect(!SidebarWorkspaceGroupHeaderDropZone.isBottomEdgeDrop(locationY: 10, rowHeight: 20))
        #expect(SidebarWorkspaceGroupHeaderDropZone.isBottomEdgeDrop(locationY: 18, rowHeight: 20))
    }
}
