import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarActiveForegroundColorTests: XCTestCase {
    func testLightAppearanceUsesBlackWithRequestedOpacity() {
        guard let lightAppearance = NSAppearance(named: .aqua),
              let color = sidebarActiveForegroundNSColor(
                  opacity: 0.8,
                  appAppearance: lightAppearance
              ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.8, accuracy: 0.001)
    }

    func testDarkAppearanceUsesWhiteWithRequestedOpacity() {
        guard let darkAppearance = NSAppearance(named: .darkAqua),
              let color = sidebarActiveForegroundNSColor(
                  opacity: 0.65,
                  appAppearance: darkAppearance
              ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }
}


final class SidebarBranchLayoutSettingsTests: XCTestCase {
    func testDefaultUsesVerticalLayout() {
        let suiteName = "SidebarBranchLayoutSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))
    }

    func testStoredPreferenceOverridesDefault() {
        let suiteName = "SidebarBranchLayoutSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: SidebarBranchLayoutSettings.key)
        XCTAssertFalse(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))

        defaults.set(true, forKey: SidebarBranchLayoutSettings.key)
        XCTAssertTrue(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))
    }
}


final class SidebarActiveTabIndicatorSettingsTests: XCTestCase {
    func testDefaultStyleWhenUnset() {
        let suiteName = "SidebarActiveTabIndicatorSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(
            SidebarActiveTabIndicatorSettings.current(defaults: defaults),
            SidebarActiveTabIndicatorSettings.defaultStyle
        )
    }

    func testStoredStyleParsesAndInvalidFallsBack() {
        let suiteName = "SidebarActiveTabIndicatorSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(SidebarActiveTabIndicatorStyle.leftRail.rawValue, forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(SidebarActiveTabIndicatorSettings.current(defaults: defaults), .leftRail)

        defaults.set("rail", forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(SidebarActiveTabIndicatorSettings.current(defaults: defaults), .leftRail)

        defaults.set("not-a-style", forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(
            SidebarActiveTabIndicatorSettings.current(defaults: defaults),
            SidebarActiveTabIndicatorSettings.defaultStyle
        )
    }
}


final class SidebarRemoteErrorCopySupportTests: XCTestCase {
    func testMenuLabelIsNilWhenThereAreNoErrors() {
        XCTAssertNil(SidebarRemoteErrorCopySupport.menuLabel(for: []))
        XCTAssertNil(SidebarRemoteErrorCopySupport.clipboardText(for: []))
    }

    func testSingleErrorUsesCopyErrorLabelAndSingleLinePayload() {
        let entries = [
            SidebarRemoteErrorCopyEntry(
                workspaceTitle: "alpha",
                target: "devbox:22",
                detail: "failed to start reverse relay"
            )
        ]

        XCTAssertEqual(SidebarRemoteErrorCopySupport.menuLabel(for: entries), "Copy Error")
        XCTAssertEqual(
            SidebarRemoteErrorCopySupport.clipboardText(for: entries),
            "SSH error (devbox:22): failed to start reverse relay"
        )
    }

    func testMultipleErrorsUseCopyErrorsLabelAndEnumeratedPayload() {
        let entries = [
            SidebarRemoteErrorCopyEntry(
                workspaceTitle: "alpha",
                target: "devbox-a:22",
                detail: "connection timed out"
            ),
            SidebarRemoteErrorCopyEntry(
                workspaceTitle: "beta",
                target: "devbox-b:22",
                detail: "permission denied"
            ),
        ]

        XCTAssertEqual(SidebarRemoteErrorCopySupport.menuLabel(for: entries), "Copy Errors")
        XCTAssertEqual(
            SidebarRemoteErrorCopySupport.clipboardText(for: entries),
            """
            1. alpha (devbox-a:22): connection timed out
            2. beta (devbox-b:22): permission denied
            """
        )
    }

    func testClipboardTextSingleEntryUsesStructuredEntryFields() {
        let entry = SidebarRemoteErrorCopyEntry(
            workspaceTitle: "alpha",
            target: "devbox:22",
            detail: "failed to bootstrap daemon"
        )
        XCTAssertEqual(
            SidebarRemoteErrorCopySupport.clipboardText(for: [entry]),
            "SSH error (devbox:22): failed to bootstrap daemon"
        )
    }
}


final class SidebarBranchOrderingTests: XCTestCase {

    func testOrderedUniqueBranchesDedupesByNameAndMergesDirtyState() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let branches = SidebarBranchOrdering.orderedUniqueBranches(
            orderedPanelIds: [first, second, third],
            panelBranches: [
                first: SidebarGitBranchState(branch: "main", isDirty: false),
                second: SidebarGitBranchState(branch: "feature", isDirty: false),
                third: SidebarGitBranchState(branch: "main", isDirty: true)
            ],
            fallbackBranch: SidebarGitBranchState(branch: "fallback", isDirty: false)
        )

        XCTAssertEqual(
            branches,
            [
                SidebarBranchOrdering.BranchEntry(name: "main", isDirty: true),
                SidebarBranchOrdering.BranchEntry(name: "feature", isDirty: false)
            ]
        )
    }

    func testOrderedUniqueBranchesUsesFallbackWhenNoPanelBranchesExist() {
        let branches = SidebarBranchOrdering.orderedUniqueBranches(
            orderedPanelIds: [],
            panelBranches: [:],
            fallbackBranch: SidebarGitBranchState(branch: "fallback", isDirty: true)
        )

        XCTAssertEqual(
            branches,
            [SidebarBranchOrdering.BranchEntry(name: "fallback", isDirty: true)]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesDedupesPairsAndMergesDirtyState() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let fifth = UUID()

        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [first, second, third, fourth, fifth],
            panelBranches: [
                first: SidebarGitBranchState(branch: "main", isDirty: false),
                second: SidebarGitBranchState(branch: "feature", isDirty: false),
                third: SidebarGitBranchState(branch: "main", isDirty: true),
                fourth: SidebarGitBranchState(branch: "main", isDirty: false)
            ],
            panelDirectories: [
                first: "/repo/a",
                second: "/repo/b",
                third: "/repo/a",
                fourth: "/repo/d",
                fifth: "/repo/e"
            ],
            defaultDirectory: "/repo/default",
            fallbackBranch: SidebarGitBranchState(branch: "fallback", isDirty: false)
        )

        XCTAssertEqual(
            rows,
            [
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: true, directory: "/repo/a"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "feature", isDirty: false, directory: "/repo/b"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: false, directory: "/repo/d"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: nil, isDirty: false, directory: "/repo/e")
            ]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesUsesFallbackBranchWhenPanelBranchesMissing() {
        let first = UUID()
        let second = UUID()

        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [first, second],
            panelBranches: [:],
            panelDirectories: [
                first: "/repo/one",
                second: "/repo/two"
            ],
            defaultDirectory: "/repo/default",
            fallbackBranch: SidebarGitBranchState(branch: "main", isDirty: true)
        )

        XCTAssertEqual(
            rows,
            [
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: true, directory: "/repo/one"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: true, directory: "/repo/two")
            ]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesFallsBackWhenNoPanelsExist() {
        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [],
            panelBranches: [:],
            panelDirectories: [:],
            defaultDirectory: "/repo/default",
            fallbackBranch: SidebarGitBranchState(branch: "main", isDirty: false)
        )

        XCTAssertEqual(
            rows,
            [SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: false, directory: "/repo/default")]
        )
    }

    func testOrderedUniquePullRequestsFollowsPanelOrderAcrossSplitsAndTabs() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()

        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [first, second, third, fourth],
            panelPullRequests: [
                first: pullRequestState(
                    number: 337,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/337",
                    status: .open
                ),
                second: pullRequestState(
                    number: 18,
                    label: "MR",
                    url: "https://gitlab.com/manaflow/cmux/-/merge_requests/18",
                    status: .open
                ),
                third: pullRequestState(
                    number: 337,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/337",
                    status: .merged
                ),
                fourth: pullRequestState(
                    number: 92,
                    label: "PR",
                    url: "https://bitbucket.org/manaflow/cmux/pull-requests/92",
                    status: .closed
                )
            ],
            fallbackPullRequest: pullRequestState(
                number: 1,
                label: "PR",
                url: "https://example.invalid/fallback/1",
                status: .open
            )
        )

        XCTAssertEqual(
            pullRequests.map { "\($0.label)#\($0.number)" },
            ["PR#337", "MR#18", "PR#92"]
        )
        XCTAssertEqual(
            pullRequests.map(\.status),
            [.merged, .open, .closed]
        )
    }

    func testOrderedUniquePullRequestsTreatsSameNumberDifferentLabelsAsDistinct() {
        let first = UUID()
        let second = UUID()

        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [first, second],
            panelPullRequests: [
                first: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/42",
                    status: .open
                ),
                second: pullRequestState(
                    number: 42,
                    label: "MR",
                    url: "https://gitlab.com/manaflow/cmux/-/merge_requests/42",
                    status: .open
                )
            ],
            fallbackPullRequest: nil
        )

        XCTAssertEqual(
            pullRequests.map { "\($0.label)#\($0.number)" },
            ["PR#42", "MR#42"]
        )
    }

    func testOrderedUniquePullRequestsTreatsSameNumberAndLabelDifferentUrlsAsDistinct() {
        let first = UUID()
        let second = UUID()

        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [first, second],
            panelPullRequests: [
                first: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/42",
                    status: .open
                ),
                second: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/other-repo/pull/42",
                    status: .open
                )
            ],
            fallbackPullRequest: nil
        )

        XCTAssertEqual(
            pullRequests.map(\.url.absoluteString),
            [
                "https://github.com/manaflow-ai/cmux/pull/42",
                "https://github.com/manaflow-ai/other-repo/pull/42"
            ]
        )
    }

    func testOrderedUniquePullRequestsPrefersEntryWithChecksWhenStatusesMatch() {
        let first = UUID()
        let second = UUID()

        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [first, second],
            panelPullRequests: [
                first: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/42",
                    status: .open
                ),
                second: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/42",
                    status: .open,
                    checks: .pass
                )
            ],
            fallbackPullRequest: nil
        )

        XCTAssertEqual(pullRequests.count, 1)
        XCTAssertEqual(pullRequests.first?.checks, .pass)
    }

    @MainActor
    func testUpdatePanelPullRequestPreservesExistingChecksWhenUpdateOmitsThem() {
        let workspace = Workspace(title: "Tests", workingDirectory: FileManager.default.currentDirectoryPath, portOrdinal: 0)
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel for new workspace")
            return
        }

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 42,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/42")!,
            status: .open,
            checks: .pass
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 42,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/42")!,
            status: .open
        )

        XCTAssertEqual(workspace.panelPullRequests[panelId]?.checks, .pass)
        XCTAssertEqual(workspace.pullRequest?.checks, .pass)
    }

    func testOrderedUniquePullRequestsUsesFallbackWhenNoPanelPullRequestsExist() {
        let fallback = pullRequestState(
            number: 11,
            label: "PR",
            url: "https://github.com/manaflow-ai/cmux/pull/11",
            status: .open
        )
        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [],
            panelPullRequests: [:],
            fallbackPullRequest: fallback
        )

        XCTAssertEqual(pullRequests, [fallback])
    }

    @MainActor
    func testUpdatePanelGitBranchClearsFocusedPullRequestWhenBranchChanges() {
        let workspace = Workspace(title: "Tests", workingDirectory: FileManager.default.currentDirectoryPath, portOrdinal: 0)
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel for new workspace")
            return
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/sidebar-pr", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 1629,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/1629")!,
            status: .open
        )

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)

        XCTAssertNil(workspace.pullRequest)
        XCTAssertNil(workspace.panelPullRequests[panelId])
        XCTAssertTrue(workspace.sidebarPullRequestsInDisplayOrder().isEmpty)
    }

    @MainActor
    func testSidebarPullRequestsHideBranchMismatches() {
        let workspace = Workspace(title: "Tests", workingDirectory: FileManager.default.currentDirectoryPath, portOrdinal: 0)
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel for new workspace")
            return
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 1629,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/1629")!,
            status: .open,
            branch: "feature/sidebar-pr"
        )

        XCTAssertTrue(workspace.sidebarPullRequestsInDisplayOrder().isEmpty)
    }

    private func pullRequestState(
        number: Int,
        label: String,
        url: String,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        checks: SidebarPullRequestChecksStatus? = nil
    ) -> SidebarPullRequestState {
        SidebarPullRequestState(
            number: number,
            label: label,
            url: URL(string: url)!,
            status: status,
            branch: branch,
            checks: checks
        )
    }
}


final class SidebarDropPlannerTests: XCTestCase {
    func testNoIndicatorForNoOpEdges() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: first,
                tabIds: tabIds,
                pinnedTabIds: []
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: nil,
                tabIds: tabIds,
                pinnedTabIds: []
            )
        )
    }

    func testNoIndicatorWhenOnlyOneTabExists() {
        let only = UUID()
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: nil,
                tabIds: [only],
                pinnedTabIds: []
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: only,
                tabIds: [only],
                pinnedTabIds: []
            )
        )
    }

    func testIndicatorAppearsForRealMoveToEnd() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: second,
            targetTabId: nil,
            tabIds: tabIds,
            pinnedTabIds: []
        )
        XCTAssertEqual(indicator?.tabId, nil)
        XCTAssertEqual(indicator?.edge, .bottom)
    }

    func testTargetIndexForMoveToEndFromMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let index = SidebarDropPlanner.targetIndex(
            draggedTabId: second,
            targetTabId: nil,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
            tabIds: tabIds,
            pinnedTabIds: []
        )
        XCTAssertEqual(index, 2)
    }

    func testNoIndicatorForSelfDropInMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: second,
                targetTabId: second,
                tabIds: tabIds,
                pinnedTabIds: []
            )
        )
    }

    func testPointerEdgeTopCanSuppressNoOpWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: second,
                tabIds: tabIds,
                pinnedTabIds: [],
                pointerY: 2,
                targetHeight: 40
            )
        )
    }

    func testPointerEdgeBottomAllowsMoveWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: first,
            targetTabId: second,
            tabIds: tabIds,
            pinnedTabIds: [],
            pointerY: 38,
            targetHeight: 40
        )
        XCTAssertEqual(indicator?.tabId, third)
        XCTAssertEqual(indicator?.edge, .top)
        XCTAssertEqual(
            SidebarDropPlanner.targetIndex(
                draggedTabId: first,
                targetTabId: second,
                indicator: indicator,
                tabIds: tabIds,
                pinnedTabIds: []
            ),
            1
        )
    }

    func testEquivalentBoundaryInputsResolveToSingleCanonicalIndicator() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let fromBottomOfFirst = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: first,
            tabIds: tabIds,
            pinnedTabIds: [],
            pointerY: 38,
            targetHeight: 40
        )
        let fromTopOfSecond = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: second,
            tabIds: tabIds,
            pinnedTabIds: [],
            pointerY: 2,
            targetHeight: 40
        )

        XCTAssertEqual(fromBottomOfFirst?.tabId, second)
        XCTAssertEqual(fromBottomOfFirst?.edge, .top)
        XCTAssertEqual(fromTopOfSecond?.tabId, second)
        XCTAssertEqual(fromTopOfSecond?.edge, .top)
    }

    func testPointerEdgeBottomSuppressesNoOpWhenDraggingLastOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: second,
                tabIds: tabIds,
                pinnedTabIds: [],
                pointerY: 38,
                targetHeight: 40
            )
        )
    }

    func testIndicatorSnapsUnpinnedDropToFirstUnpinnedBoundaryWhenHoveringPinnedWorkspace() {
        let pinnedA = UUID()
        let pinnedB = UUID()
        let unpinnedA = UUID()
        let unpinnedB = UUID()
        let tabIds = [pinnedA, pinnedB, unpinnedA, unpinnedB]
        let pinnedIds: Set<UUID> = [pinnedA, pinnedB]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: unpinnedB,
            targetTabId: pinnedA,
            tabIds: tabIds,
            pinnedTabIds: pinnedIds,
            pointerY: 2,
            targetHeight: 40
        )

        XCTAssertEqual(indicator?.tabId, unpinnedA)
        XCTAssertEqual(indicator?.edge, .top)
    }

    func testTargetIndexSnapsUnpinnedDropToFirstUnpinnedBoundaryWhenHoveringPinnedWorkspace() {
        let pinnedA = UUID()
        let pinnedB = UUID()
        let unpinnedA = UUID()
        let unpinnedB = UUID()
        let tabIds = [pinnedA, pinnedB, unpinnedA, unpinnedB]
        let pinnedIds: Set<UUID> = [pinnedA, pinnedB]

        let targetIndex = SidebarDropPlanner.targetIndex(
            draggedTabId: unpinnedB,
            targetTabId: pinnedA,
            indicator: SidebarDropIndicator(tabId: pinnedA, edge: .top),
            tabIds: tabIds,
            pinnedTabIds: pinnedIds
        )

        XCTAssertEqual(targetIndex, 2)
    }

}


final class SidebarDragAutoScrollPlannerTests: XCTestCase {
    func testAutoScrollPlanTriggersNearTopAndBottomOnly() {
        let topPlan = SidebarDragAutoScrollPlanner.plan(distanceToTop: 4, distanceToBottom: 96, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(topPlan?.direction, .up)
        XCTAssertNotNil(topPlan)

        let bottomPlan = SidebarDragAutoScrollPlanner.plan(distanceToTop: 96, distanceToBottom: 4, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(bottomPlan?.direction, .down)
        XCTAssertNotNil(bottomPlan)

        XCTAssertNil(
            SidebarDragAutoScrollPlanner.plan(distanceToTop: 60, distanceToBottom: 60, edgeInset: 44, minStep: 2, maxStep: 12)
        )
    }

    func testAutoScrollPlanSpeedsUpCloserToEdge() {
        let nearTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: 1, distanceToBottom: 99, edgeInset: 44, minStep: 2, maxStep: 12)
        let midTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: 22, distanceToBottom: 78, edgeInset: 44, minStep: 2, maxStep: 12)

        XCTAssertNotNil(nearTop)
        XCTAssertNotNil(midTop)
        XCTAssertGreaterThan(nearTop?.pointsPerTick ?? 0, midTop?.pointsPerTick ?? 0)
    }

    func testAutoScrollPlanStillTriggersWhenPointerIsPastEdge() {
        let aboveTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: -500, distanceToBottom: 600, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(aboveTop?.direction, .up)
        XCTAssertEqual(aboveTop?.pointsPerTick, 12)

        let belowBottom = SidebarDragAutoScrollPlanner.plan(distanceToTop: 600, distanceToBottom: -500, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(belowBottom?.direction, .down)
        XCTAssertEqual(belowBottom?.pointsPerTick, 12)
    }
}


final class TerminalControllerSidebarDedupeTests: XCTestCase {
    func testShouldReplaceStatusEntryReturnsFalseForUnchangedPayload() {
        let current = SidebarStatusEntry(
            key: "agent",
            value: "idle",
            icon: "bolt",
            color: "#ffffff",
            timestamp: Date(timeIntervalSince1970: 123)
        )
        XCTAssertFalse(
            TerminalController.shouldReplaceStatusEntry(
                current: current,
                key: "agent",
                value: "idle",
                icon: "bolt",
                color: "#ffffff",
                url: nil,
                priority: 0,
                format: .plain
            )
        )
    }

    func testShouldReplaceStatusEntryReturnsTrueWhenValueChanges() {
        let current = SidebarStatusEntry(
            key: "agent",
            value: "idle",
            icon: "bolt",
            color: "#ffffff",
            timestamp: Date(timeIntervalSince1970: 123)
        )
        XCTAssertTrue(
            TerminalController.shouldReplaceStatusEntry(
                current: current,
                key: "agent",
                value: "running",
                icon: "bolt",
                color: "#ffffff",
                url: nil,
                priority: 0,
                format: .plain
            )
        )
    }

    func testShouldReplaceProgressReturnsFalseForUnchangedPayload() {
        XCTAssertFalse(
            TerminalController.shouldReplaceProgress(
                current: SidebarProgressState(value: 0.42, label: "indexing"),
                value: 0.42,
                label: "indexing"
            )
        )
    }

    func testShouldReplaceGitBranchReturnsFalseForUnchangedPayload() {
        XCTAssertFalse(
            TerminalController.shouldReplaceGitBranch(
                current: SidebarGitBranchState(branch: "main", isDirty: true),
                branch: "main",
                isDirty: true
            )
        )
    }

    func testShouldReplacePortsIgnoresOrderAndDuplicates() {
        XCTAssertFalse(
            TerminalController.shouldReplacePorts(
                current: [9229, 3000],
                next: [3000, 9229, 3000]
            )
        )
        XCTAssertTrue(
            TerminalController.shouldReplacePorts(
                current: [9229, 3000],
                next: [3000]
            )
        )
    }

    func testExplicitSocketScopeParsesValidUUIDTabAndPanel() {
        let workspaceId = UUID()
        let panelId = UUID()
        let scope = TerminalController.explicitSocketScope(
            options: [
                "tab": workspaceId.uuidString,
                "panel": panelId.uuidString
            ]
        )
        XCTAssertEqual(scope?.workspaceId, workspaceId)
        XCTAssertEqual(scope?.panelId, panelId)
    }

    func testExplicitSocketScopeAcceptsSurfaceAlias() {
        let workspaceId = UUID()
        let panelId = UUID()
        let scope = TerminalController.explicitSocketScope(
            options: [
                "tab": workspaceId.uuidString,
                "surface": panelId.uuidString
            ]
        )
        XCTAssertEqual(scope?.workspaceId, workspaceId)
        XCTAssertEqual(scope?.panelId, panelId)
    }

    func testExplicitSocketScopeRejectsMissingOrInvalidValues() {
        XCTAssertNil(TerminalController.explicitSocketScope(options: [:]))
        XCTAssertNil(TerminalController.explicitSocketScope(options: ["tab": "workspace:1", "panel": UUID().uuidString]))
        XCTAssertNil(TerminalController.explicitSocketScope(options: ["tab": UUID().uuidString, "panel": "surface:1"]))
    }

    func testNormalizeReportedDirectoryTrimsWhitespace() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("   /Users/cmux/project   "),
            "/Users/cmux/project"
        )
    }

    func testNormalizeReportedDirectoryResolvesFileURL() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("file:///Users/cmux/project"),
            "/Users/cmux/project"
        )
    }

    func testNormalizeReportedDirectoryLeavesInvalidURLTrimmed() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("  file://bad host  "),
            "file://bad host"
        )
    }
}
