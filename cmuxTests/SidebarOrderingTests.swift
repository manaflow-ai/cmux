import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
            homeDirectoryForTildeExpansion: nil,
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
            homeDirectoryForTildeExpansion: nil,
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
            homeDirectoryForTildeExpansion: nil,
            fallbackBranch: SidebarGitBranchState(branch: "main", isDirty: false)
        )

        XCTAssertEqual(
            rows,
            [SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: false, directory: "/repo/default")]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesKeepsAbsoluteDirectoryWhenLaterEntryUsesTildeAlias() {
        let first = UUID()
        let second = UUID()

        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [first, second],
            panelBranches: [
                first: SidebarGitBranchState(branch: "main", isDirty: false),
                second: SidebarGitBranchState(branch: "feature", isDirty: true)
            ],
            panelDirectories: [
                first: "/home/remoteuser/project",
                second: "~/project"
            ],
            defaultDirectory: nil,
            homeDirectoryForTildeExpansion: "/home/remoteuser",
            fallbackBranch: nil
        )

        XCTAssertEqual(
            rows,
            [
                SidebarBranchOrdering.BranchDirectoryEntry(
                    branch: "feature",
                    isDirty: true,
                    directory: "/home/remoteuser/project"
                )
            ]
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
                    status: .open,
                    isStale: true
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
                    status: .open,
                    isStale: true
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

    func testOrderedUniquePullRequestsPrefersFreshEntryWhenStatusesMatch() {
        let first = UUID()
        let second = UUID()

        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [first, second],
            panelPullRequests: [
                first: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/42",
                    status: .open,
                    isStale: true
                ),
                second: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/42",
                    status: .open,
                    isStale: false
                )
            ],
            fallbackPullRequest: nil
        )

        XCTAssertEqual(pullRequests.count, 1)
        XCTAssertEqual(pullRequests.first?.isStale, false)
    }

    @MainActor
    func testUpdatePanelPullRequestClearsStaleFlagOnFreshUpdate() {
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
            isStale: true
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 42,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/42")!,
            status: .open
        )

        XCTAssertEqual(workspace.panelPullRequests[panelId]?.isStale, false)
        XCTAssertEqual(workspace.pullRequest?.isStale, false)
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
        isStale: Bool = false
    ) -> SidebarPullRequestState {
        SidebarPullRequestState(
            number: number,
            label: label,
            url: URL(string: url)!,
            status: status,
            branch: branch,
            isStale: isStale
        )
    }
}


