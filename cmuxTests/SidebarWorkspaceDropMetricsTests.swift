import CoreGraphics
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarWorkspaceDropMetricsTests {
    @Test func workspaceGroupHeaderDropTargetHeightScalesWithoutLayoutMeasurement() {
        #expect(SidebarWorkspaceGroupHeaderMetrics(fontScale: 1).dropTargetHeight == 26)
        #expect(SidebarWorkspaceGroupHeaderMetrics(fontScale: 2).dropTargetHeight == 48)
    }

    @Test func workspaceRowDropTargetHeightScalesWithContentWithoutLayoutMeasurement() {
        let base = workspaceRowHeight()
        let rich = workspaceRowHeight(
            titleLineCount: 2,
            descriptionLineCount: 2,
            hasSubtitle: true,
            hasRemoteStatus: true,
            metadataEntryCount: 4,
            metadataEntryIsExpanded: true,
            metadataBlockLineCounts: [2, 3],
            hasMetadataBlockToggle: true,
            hasLog: true,
            hasProgress: true,
            branchDirectoryRowCount: 2,
            pullRequestRowCount: 2,
            hasPorts: true
        )
        let scaled = workspaceRowHeight(fontScale: 1.5)

        #expect(base == 34)
        #expect(rich > base)
        #expect(scaled > base)
    }

    @Test func workspaceRowDropTargetHeightTracksExpandedMetadataRows() {
        let collapsed = workspaceRowHeight(metadataEntryCount: 6, metadataEntryIsExpanded: false)
        let expanded = workspaceRowHeight(metadataEntryCount: 6, metadataEntryIsExpanded: true)

        #expect(expanded > collapsed)
    }

    @Test func workspaceRowDropTargetHeightTracksExpandedMetadataBlocks() {
        let collapsed = workspaceRowHeight(
            metadataBlockLineCounts: [1],
            hasMetadataBlockToggle: true
        )
        let expanded = workspaceRowHeight(
            metadataBlockLineCounts: [1, 4, 2],
            hasMetadataBlockToggle: true
        )

        #expect(expanded > collapsed)
    }

    @Test func metadataBlockLineEstimationOnlyScansVisibleCollapsedBlock() {
        let blocks = [
            SidebarMetadataBlock(key: "visible", markdown: "one", priority: 0, timestamp: Date()),
            SidebarMetadataBlock(
                key: "hidden",
                markdown: String(repeating: "hidden\n", count: 100),
                priority: 0,
                timestamp: Date()
            ),
        ]

        #expect(SidebarWorkspaceRowDropMetrics.estimatedMetadataBlockLineCounts(blocks, isExpanded: false) == [1])
        #expect(SidebarWorkspaceRowDropMetrics.estimatedMetadataBlockLineCounts(blocks, isExpanded: true) == [1, 12])
    }

    @Test func workspaceRowDropTargetHeightUsesLineAwareTitleAndDescriptionEstimates() {
        let short = workspaceRowHeight(titleLineCount: 1, descriptionLineCount: 1)
        let tall = workspaceRowHeight(titleLineCount: 4, descriptionLineCount: 5)

        #expect(tall > short)
    }

    @Test func pointerEdgeHeightIsOnlyUsedForWidthIndependentRows() {
        #expect(SidebarWorkspaceRowDropMetrics.shouldUsePointerEdgeHeight(
            wrapsWorkspaceTitles: false,
            hasDescription: false,
            hasMetadataBlocks: false
        ))
        #expect(!SidebarWorkspaceRowDropMetrics.shouldUsePointerEdgeHeight(
            wrapsWorkspaceTitles: true,
            hasDescription: false,
            hasMetadataBlocks: false
        ))
        #expect(!SidebarWorkspaceRowDropMetrics.shouldUsePointerEdgeHeight(
            wrapsWorkspaceTitles: false,
            hasDescription: true,
            hasMetadataBlocks: false
        ))
        #expect(!SidebarWorkspaceRowDropMetrics.shouldUsePointerEdgeHeight(
            wrapsWorkspaceTitles: false,
            hasDescription: false,
            hasMetadataBlocks: true
        ))
    }

    private func workspaceRowHeight(
        fontScale: CGFloat = 1,
        titleLineCount: Int = 1,
        descriptionLineCount: Int = 0,
        hasSubtitle: Bool = false,
        hasRemoteStatus: Bool = false,
        metadataEntryCount: Int = 0,
        metadataEntryIsExpanded: Bool = false,
        metadataBlockLineCounts: [Int] = [],
        hasMetadataBlockToggle: Bool = false,
        hasLog: Bool = false,
        hasProgress: Bool = false,
        branchDirectoryRowCount: Int = 0,
        pullRequestRowCount: Int = 0,
        hasPorts: Bool = false
    ) -> CGFloat {
        SidebarWorkspaceRowDropMetrics.targetHeight(
            fontScale: fontScale,
            titleLineCount: titleLineCount,
            descriptionLineCount: descriptionLineCount,
            hasSubtitle: hasSubtitle,
            hasRemoteStatus: hasRemoteStatus,
            metadataEntryCount: metadataEntryCount,
            metadataEntryIsExpanded: metadataEntryIsExpanded,
            metadataBlockLineCounts: metadataBlockLineCounts,
            hasMetadataBlockToggle: hasMetadataBlockToggle,
            hasLog: hasLog,
            hasProgress: hasProgress,
            branchDirectoryRowCount: branchDirectoryRowCount,
            pullRequestRowCount: pullRequestRowCount,
            hasPorts: hasPorts
        )
    }
}
