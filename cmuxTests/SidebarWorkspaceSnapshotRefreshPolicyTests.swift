import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWorkspaceSnapshotRefreshPolicyTests: XCTestCase {
    func testContextMenuPinChangeUpdatesDisplayedFieldsAndDefersNoisyFields() {
        let current = Self.snapshot(
            title: "lmao",
            isPinned: false,
            customColorHex: nil,
            remoteConnectionStatusText: "Connected",
            latestSubmittedMessage: "old message",
            listeningPorts: [3000]
        )
        let next = Self.snapshot(
            title: "lmao",
            isPinned: true,
            customColorHex: nil,
            remoteConnectionStatusText: "Disconnected",
            latestSubmittedMessage: "new message",
            listeningPorts: [3000, 4000]
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        var expectedDisplayed = current
        expectedDisplayed = expectedDisplayed.applyingContextMenuImmediateFields(from: next)
        XCTAssertEqual(decision.workspaceSnapshotStorage, expectedDisplayed)
        XCTAssertTrue(decision.workspaceSnapshotStorage?.isPinned == true)
        XCTAssertEqual(decision.workspaceSnapshotStorage?.remoteConnectionStatusText, "Connected")
        XCTAssertEqual(decision.workspaceSnapshotStorage?.latestSubmittedMessage, "old message")
        XCTAssertEqual(decision.workspaceSnapshotStorage?.listeningPorts, [3000])
        XCTAssertEqual(decision.pendingWorkspaceSnapshot, next)
        XCTAssertTrue(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    func testContextMenuImmediateOnlyChangeDoesNotCreateDeferredFlush() {
        let current = Self.snapshot(
            title: "old",
            customDescription: nil,
            isPinned: false,
            customColorHex: nil
        )
        let next = Self.snapshot(
            title: "new",
            customDescription: "description",
            isPinned: true,
            customColorHex: "#C0392B"
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        XCTAssertEqual(decision.workspaceSnapshotStorage, next)
        XCTAssertNil(decision.pendingWorkspaceSnapshot)
        XCTAssertFalse(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    func testClosedContextMenuStoresNextAndClearsPending() {
        let current = Self.snapshot(title: "old", isPinned: false)
        let next = Self.snapshot(title: "new", isPinned: true)

        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: false
        )

        XCTAssertEqual(decision.workspaceSnapshotStorage, next)
        XCTAssertNil(decision.pendingWorkspaceSnapshot)
        XCTAssertFalse(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    private static func snapshot(
        title: String = "workspace",
        customDescription: String? = nil,
        isPinned: Bool = false,
        customColorHex: String? = nil,
        remoteConnectionStatusText: String = "Disconnected",
        latestSubmittedMessage: String? = nil,
        listeningPorts: [Int] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            customColorHex: customColorHex,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: "",
            copyableSidebarSSHError: nil,
            latestSubmittedMessage: latestSubmittedMessage,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            compactGitBranchSummaryText: nil,
            compactBranchDirectoryRow: nil,
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: listeningPorts
        )
    }
}
