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

    @Test func workspaceRowDropTargetHeightIncludesTopLevelSectionSpacing() {
        let withDescription = workspaceRowHeight(descriptionLineCount: 1)
        let withDescriptionAndSubtitle = workspaceRowHeight(
            descriptionLineCount: 1,
            hasSubtitle: true
        )

        #expect(workspaceRowHeight() == 34)
        #expect(withDescription == 51)
        #expect(withDescriptionAndSubtitle == 79)
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

    @Test func metadataBlockLineEstimationUsesRenderedMarkdownText() {
        let longURL = "https://example.com/" + String(repeating: "hidden-url-segment/", count: 24)
        let block = SidebarMetadataBlock(
            key: "link",
            markdown: "[short](\(longURL))",
            priority: 0,
            timestamp: Date()
        )

        let lineCounts = SidebarWorkspaceRowDropMetrics.estimatedMetadataBlockLineCounts(
            [block],
            isExpanded: false,
            textWidth: 48
        )

        #expect(lineCounts == [1])
    }

    @Test func workspaceRowDropTargetHeightUsesLineAwareTitleAndDescriptionEstimates() {
        let short = workspaceRowHeight(titleLineCount: 1, descriptionLineCount: 1)
        let tall = workspaceRowHeight(titleLineCount: 4, descriptionLineCount: 5)

        #expect(tall > short)
    }

    @Test func workspaceRowDropTargetHeightKeepsPointerEdgeMetricsForWrappedAndRichRows() {
        let snapshot = workspaceSnapshot(
            title: String(repeating: "Long workspace title ", count: 12),
            customDescription: "First description line\nSecond description line",
            metadataEntries: [
                SidebarStatusEntry(key: "state", value: "running"),
                SidebarStatusEntry(key: "phase", value: "building"),
                SidebarStatusEntry(key: "owner", value: "agent")
            ],
            metadataBlocks: [
                SidebarMetadataBlock(
                    key: "notes",
                    markdown: "Line one\nLine two\nLine three",
                    priority: 0,
                    timestamp: Date()
                )
            ]
        )

        let wideHeight = SidebarWorkspaceRowDropMetrics.dropTargetHeight(
            snapshot: snapshot,
            settings: settings(wrapsWorkspaceTitles: true),
            effectiveSubtitle: "Recent update",
            metadataEntryIsExpanded: false,
            metadataBlocksAreExpanded: false,
            sidebarWidth: 600,
            unreadCount: 0,
            hasMemoryWarning: false,
            canCloseWorkspace: true
        )
        let narrowHeight = SidebarWorkspaceRowDropMetrics.dropTargetHeight(
            snapshot: snapshot,
            settings: settings(wrapsWorkspaceTitles: true),
            effectiveSubtitle: "Recent update",
            metadataEntryIsExpanded: false,
            metadataBlocksAreExpanded: false,
            sidebarWidth: 216,
            unreadCount: 12,
            hasMemoryWarning: true,
            canCloseWorkspace: true
        )
        let groupedNarrowHeight = SidebarWorkspaceRowDropMetrics.dropTargetHeight(
            snapshot: snapshot,
            settings: settings(wrapsWorkspaceTitles: true),
            effectiveSubtitle: "Recent update",
            metadataEntryIsExpanded: false,
            metadataBlocksAreExpanded: false,
            sidebarWidth: 216 - SidebarWorkspaceGroupingMetrics.memberIndent,
            unreadCount: 12,
            hasMemoryWarning: true,
            canCloseWorkspace: true
        )

        #expect(wideHeight > workspaceRowHeight())
        #expect(narrowHeight > wideHeight)
        #expect(groupedNarrowHeight >= narrowHeight)
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

    private func settings(wrapsWorkspaceTitles: Bool = false) -> SidebarTabItemSettingsSnapshot {
        let suiteName = "SidebarWorkspaceDropMetricsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create test UserDefaults suite")
        }
        defaults.set(wrapsWorkspaceTitles, forKey: SidebarWorkspaceTitleWrapSettings.key)
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        defaults.removePersistentDomain(forName: suiteName)
        return settings
    }

    private func workspaceSnapshot(
        title: String = "workspace",
        customDescription: String? = nil,
        metadataEntries: [SidebarStatusEntry] = [],
        metadataBlocks: [SidebarMetadataBlock] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let visibleAuxiliaryDetails = SidebarWorkspaceAuxiliaryDetailVisibility(
            showsMetadata: true,
            showsLog: true,
            showsProgress: true,
            showsBranchDirectory: true,
            showsPullRequests: true,
            showsPorts: true
        )
        return SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey(
                showsWorkspaceDescription: true,
                usesVerticalBranchLayout: true,
                showsGitBranch: true,
                usesViewportAwarePath: false,
                visibleAuxiliaryDetails: visibleAuxiliaryDetails
            ),
            title: title,
            customDescription: customDescription,
            isPinned: false,
            customColorHex: nil,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: "",
            remoteStateHelpText: "",
            showsRemoteReconnectAffordance: false,
            copyableSidebarSSHError: nil,
            latestConversationMessage: nil,
            metadataEntries: metadataEntries,
            metadataBlocks: metadataBlocks,
            latestLog: nil,
            progress: nil,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: [],
            finderDirectoryPath: nil
        )
    }
}
