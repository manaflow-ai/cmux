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

let lastSurfaceCloseShortcutDefaultsKey = "closeWorkspaceOnLastSurfaceShortcut"

func drainMainQueue() {
    let expectation = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1.0)
}

@discardableResult
private func waitForCondition(
    timeout: TimeInterval = 3.0,
    pollInterval: TimeInterval = 0.05,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
) -> Bool {
    if condition() {
        return true
    }

    let expectation = XCTestExpectation(description: "wait for condition")
    let deadline = Date().addingTimeInterval(timeout)

    func poll() {
        if condition() {
            expectation.fulfill()
            return
        }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            poll()
        }
    }

    DispatchQueue.main.async {
        poll()
    }

    let result = XCTWaiter().wait(for: [expectation], timeout: timeout + pollInterval + 0.1)
    if result != .completed {
        XCTFail("Timed out waiting for condition", file: file, line: line)
        return false
    }
    return true
}

private struct ProcessRunResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func splitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
    switch node {
    case .pane:
        return []
    case .split(let split):
        return [split] + splitNodes(in: split.first) + splitNodes(in: split.second)
    }
}

private func runProcess(
    executablePath: String,
    arguments: [String],
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil
) throws -> ProcessRunResult {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = currentDirectoryURL
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    return ProcessRunResult(
        status: process.terminationStatus,
        stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func runGit(
    _ arguments: [String],
    in directoryURL: URL,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String {
    let result = try runProcess(
        executablePath: "/usr/bin/env",
        arguments: ["git"] + arguments,
        currentDirectoryURL: directoryURL
    )
    XCTAssertEqual(
        result.status,
        0,
        "git \(arguments.joined(separator: " ")) failed: \(result.stderr)",
        file: file,
        line: line
    )
    return result.stdout
}

@MainActor
final class TabManagerChildExitCloseTests: XCTestCase {
    func testChildExitOnLastPanelClosesSelectedWorkspaceAndKeepsIndexStable() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(tabId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id])
        XCTAssertEqual(
            manager.selectedTabId,
            third.id,
            "Expected selection to stay at the same index after deleting the selected workspace"
        )
    }

    func testChildExitOnLastPanelInLastWorkspaceSelectsPreviousWorkspace() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(tabId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id])
        XCTAssertEqual(
            manager.selectedTabId,
            first.id,
            "Expected previous workspace to be selected after closing the last-index workspace"
        )
    }

    func testChildExitOnLastRemotePanelKeepsWorkspaceAndDemotesToLocal() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let remotePanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64015,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(remotePanelId))

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: remotePanelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(manager.tabs.first?.id, workspace.id)
        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertNil(workspace.panels[remotePanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, remotePanelId)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    func testChildExitAfterRemoteSessionEndKeepsWorkspaceAndDemotesToLocal() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let remotePanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64016,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )

        workspace.markRemoteTerminalSessionEnded(surfaceId: remotePanelId, relayPort: 64016)

        XCTAssertFalse(workspace.isRemoteWorkspace)

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: remotePanelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(manager.tabs.first?.id, workspace.id)
        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertNil(workspace.panels[remotePanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, remotePanelId)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    func testChildExitOnNonLastPanelClosesOnlyPanel() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        guard let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        let panelCountBefore = workspace.panels.count
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: splitPanel.id)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs.first?.id, workspace.id)
        XCTAssertEqual(workspace.panels.count, panelCountBefore - 1)
        XCTAssertNotNil(workspace.panels[initialPanelId], "Expected sibling panel to remain")
    }
}


@MainActor
final class TabManagerWorkspaceOwnershipTests: XCTestCase {
    func testCloseWorkspaceIgnoresWorkspaceNotOwnedByManager() {
        let manager = TabManager()
        _ = manager.addWorkspace()
        let initialTabIds = manager.tabs.map(\.id)
        let initialSelectedTabId = manager.selectedTabId

        let externalWorkspace = Workspace(title: "External workspace")
        let externalPanelCountBefore = externalWorkspace.panels.count
        let externalPanelTitlesBefore = externalWorkspace.panelTitles

        manager.closeWorkspace(externalWorkspace)

        XCTAssertEqual(manager.tabs.map(\.id), initialTabIds)
        XCTAssertEqual(manager.selectedTabId, initialSelectedTabId)
        XCTAssertEqual(externalWorkspace.panels.count, externalPanelCountBefore)
        XCTAssertEqual(externalWorkspace.panelTitles, externalPanelTitlesBefore)
    }
}

@MainActor
final class TabManagerPullRequestProbeTests: XCTestCase {
    func testGitHubRepositorySlugsPrioritizeUpstreamThenOriginAndDeduplicate() {
        let output = """
        origin https://github.com/austinwang/cmux.git (fetch)
        origin https://github.com/austinwang/cmux.git (push)
        upstream git@github.com:manaflow-ai/cmux.git (fetch)
        upstream git@github.com:manaflow-ai/cmux.git (push)
        backup ssh://git@github.com/manaflow-ai/cmux.git (fetch)
        mirror https://gitlab.com/manaflow-ai/cmux.git (fetch)
        """

        XCTAssertEqual(
            TabManager.githubRepositorySlugs(fromGitRemoteVOutput: output),
            ["manaflow-ai/cmux", "austinwang/cmux"]
        )
    }

    func testPreferredPullRequestPrefersOpenOverMergedAndClosed() {
        let candidates = [
            TabManager.GitHubPullRequestProbeItem(
                number: 1889,
                state: "MERGED",
                url: "https://github.com/manaflow-ai/cmux/pull/1889",
                updatedAt: "2026-03-20T18:00:00Z"
            ),
            TabManager.GitHubPullRequestProbeItem(
                number: 1891,
                state: "OPEN",
                url: "https://github.com/manaflow-ai/cmux/pull/1891",
                updatedAt: "2026-03-19T18:00:00Z"
            ),
            TabManager.GitHubPullRequestProbeItem(
                number: 1800,
                state: "CLOSED",
                url: "https://github.com/manaflow-ai/cmux/pull/1800",
                updatedAt: "2026-03-21T18:00:00Z"
            ),
        ]

        XCTAssertEqual(
            TabManager.preferredPullRequest(from: candidates),
            candidates[1]
        )
    }

    func testPreferredPullRequestPrefersMostRecentlyUpdatedWithinSameStatus() {
        let olderOpen = TabManager.GitHubPullRequestProbeItem(
            number: 1880,
            state: "OPEN",
            url: "https://github.com/manaflow-ai/cmux/pull/1880",
            updatedAt: "2026-03-18T18:00:00Z"
        )
        let newerOpen = TabManager.GitHubPullRequestProbeItem(
            number: 1890,
            state: "OPEN",
            url: "https://github.com/manaflow-ai/cmux/pull/1890",
            updatedAt: "2026-03-20T18:00:00Z"
        )

        XCTAssertEqual(
            TabManager.preferredPullRequest(from: [olderOpen, newerOpen]),
            newerOpen
        )
    }

    func testPreferredPullRequestIgnoresMalformedCandidates() {
        let valid = TabManager.GitHubPullRequestProbeItem(
            number: 1888,
            state: "OPEN",
            url: "https://github.com/manaflow-ai/cmux/pull/1888",
            updatedAt: "2026-03-20T18:00:00Z"
        )

        XCTAssertEqual(
            TabManager.preferredPullRequest(from: [
                TabManager.GitHubPullRequestProbeItem(
                    number: 9999,
                    state: "WHATEVER",
                    url: "https://github.com/manaflow-ai/cmux/pull/9999",
                    updatedAt: "2026-03-21T18:00:00Z"
                ),
                TabManager.GitHubPullRequestProbeItem(
                    number: 10000,
                    state: "OPEN",
                    url: "not a url",
                    updatedAt: "2026-03-21T18:00:00Z"
                ),
                valid,
            ]),
            valid
        )
    }

    func testPullRequestMapDropsStaleMergedHeadPullRequestForLongLivedBaseBranch() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-20T12:00:00Z"))
        let pullRequests = [
            TabManager.GitHubPullRequestProbeItem(
                number: 2400,
                state: "MERGED",
                url: "https://github.com/manaflow-ai/cmux/pull/2400",
                updatedAt: "2026-03-06T12:00:00Z",
                mergedAt: "2026-03-06T12:00:00Z",
                headRefName: "develop",
                baseRefName: "main"
            ),
            TabManager.GitHubPullRequestProbeItem(
                number: 2501,
                state: "MERGED",
                url: "https://github.com/manaflow-ai/cmux/pull/2501",
                updatedAt: "2026-04-19T12:00:00Z",
                mergedAt: "2026-04-19T12:00:00Z",
                headRefName: "feature/recent-one",
                baseRefName: "develop"
            ),
            TabManager.GitHubPullRequestProbeItem(
                number: 2502,
                state: "OPEN",
                url: "https://github.com/manaflow-ai/cmux/pull/2502",
                updatedAt: "2026-04-20T12:00:00Z",
                headRefName: "feature/recent-two",
                baseRefName: "develop"
            ),
        ]

        let pullRequestsByBranch = TabManager.pullRequestMapByNormalizedBranchForTesting(
            from: pullRequests,
            now: now
        )

        XCTAssertNil(pullRequestsByBranch["develop"])
        XCTAssertEqual(pullRequestsByBranch["feature/recent-one"]?.number, 2501)
        XCTAssertEqual(pullRequestsByBranch["feature/recent-two"]?.number, 2502)
    }

    func testShouldSkipWorkspacePullRequestLookupOnlyForExactMainAndMaster() {
        XCTAssertTrue(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "main"))
        XCTAssertTrue(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "master"))
        XCTAssertTrue(TabManager.shouldSkipWorkspacePullRequestLookup(branch: " master \n"))

        XCTAssertFalse(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "Main"))
        XCTAssertFalse(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "mainline"))
        XCTAssertFalse(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "feature/main"))
        XCTAssertFalse(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "release/master-fix"))
    }

    func testWorkspacePullRequestRefreshAllowsRepoCacheForTimerAndPeriodicReasons() {
        XCTAssertTrue(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "periodicPoll"))
        XCTAssertTrue(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "periodicPoll.followUp"))
        XCTAssertTrue(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "selectedPeriodicPoll"))
        XCTAssertTrue(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "selectedPeriodicPoll.followUp"))
        XCTAssertTrue(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "timer"))
        XCTAssertTrue(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "timer.followUp"))

        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "branchChange"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "branchChange.followUp"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "shellPrompt"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "commandHint:merge"))
    }

    func testWorkspacePullRequestShouldRefreshHonorsForcedRefreshForTerminalStates() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recentTerminalRefresh = now.addingTimeInterval(-60)

        XCTAssertTrue(
            TabManager.shouldRefreshWorkspacePullRequest(
                now: now,
                nextPollAt: .distantPast,
                lastTerminalStateRefreshAt: recentTerminalRefresh,
                currentPullRequestStatus: .merged
            )
        )
        XCTAssertFalse(
            TabManager.shouldRefreshWorkspacePullRequest(
                now: now,
                nextPollAt: now.addingTimeInterval(60),
                lastTerminalStateRefreshAt: recentTerminalRefresh,
                currentPullRequestStatus: .closed
            )
        )
    }

    func testTrackedWorkspaceGitMetadataPollCandidatesIncludeMainAndMasterPanels() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let mainPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        guard let masterPanel = workspace.newTerminalSplit(from: mainPanelId, orientation: .horizontal),
              let featurePanel = workspace.newTerminalSplit(from: mainPanelId, orientation: .vertical),
              let mainlinePanel = workspace.newTerminalSplit(from: mainPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panels to be created")
            return
        }

        let staleURL = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/371"))
        workspace.updatePanelGitBranch(panelId: mainPanelId, branch: "main", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: mainPanelId,
            number: 371,
            label: "PR",
            url: staleURL,
            status: .open,
            branch: "main"
        )
        workspace.updatePanelGitBranch(panelId: masterPanel.id, branch: "master", isDirty: false)
        workspace.updatePanelGitBranch(panelId: featurePanel.id, branch: "feature/sidebar-pr", isDirty: false)
        workspace.updatePanelGitBranch(panelId: mainlinePanel.id, branch: "mainline", isDirty: false)

        XCTAssertEqual(
            manager.trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: workspace.id),
            Set([mainPanelId, masterPanel.id, featurePanel.id, mainlinePanel.id])
        )
    }

    func testTrackedWorkspaceGitMetadataPollCandidatesIncludeFocusedFallbackOnMain() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.gitBranch = SidebarGitBranchState(branch: "main", isDirty: false)
        XCTAssertEqual(
            manager.trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: workspace.id),
            Set([panelId])
        )

        workspace.gitBranch = SidebarGitBranchState(branch: "feature/sidebar-pr", isDirty: false)
        XCTAssertEqual(
            manager.trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: workspace.id),
            Set([panelId])
        )
    }

    func testTrackedWorkspaceGitMetadataPollCandidatesExcludeDirectoriesWithoutResolvedGitMetadata() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-git-nonrepo-candidate-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: directoryURL.path)

        XCTAssertTrue(
            waitForCondition {
                manager.activeWorkspaceGitProbePanelIdsForTesting(workspaceId: workspace.id).isEmpty &&
                    manager.trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: workspace.id)
                    .isEmpty &&
                    workspace.panelGitBranches[panelId] == nil
            }
        )
    }

    func testInheritedBackgroundWorkspaceFetchesGitBranchWithoutSelection() throws {
        let fileManager = FileManager.default
        let repoURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-git-inherited-background-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repoURL) }

        try runGit(["init", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "seed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repoURL)
        try runGit(["commit", "-m", "Initial commit"], in: repoURL)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }
        workspace.currentDirectory = repoURL.path

        let backgroundWorkspace = manager.addWorkspace(select: false)
        guard let backgroundPanelId = backgroundWorkspace.focusedPanelId else {
            XCTFail("Expected background workspace with focused panel")
            return
        }

        XCTAssertNotEqual(manager.selectedTabId, backgroundWorkspace.id)
        XCTAssertTrue(
            waitForCondition {
                backgroundWorkspace.panelGitBranches[backgroundPanelId]?.branch == "main"
            }
        )
        XCTAssertEqual(backgroundWorkspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["main"])
    }

    func testPeriodicWorkspaceGitMetadataRefreshUpdatesMainWorkspaceAfterCheckoutToFeatureBranch() throws {
        let fileManager = FileManager.default
        let repoURL = fileManager.temporaryDirectory.appendingPathComponent("cmux-git-main-refresh-\(UUID().uuidString)")
        try fileManager.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repoURL) }

        try runGit(["init", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "seed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repoURL)
        try runGit(["commit", "-m", "Initial commit"], in: repoURL)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)
        manager.updateSurfaceGitBranch(tabId: workspace.id, surfaceId: panelId, branch: "main", isDirty: false)

        XCTAssertEqual(
            manager.trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: workspace.id),
            Set([panelId])
        )

        try runGit(["checkout", "-b", "feature/sidebar-live-refresh"], in: repoURL)

        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "feature/sidebar-live-refresh"
            }
        )
        XCTAssertEqual(workspace.gitBranch?.branch, "feature/sidebar-live-refresh")
    }

    func testPeriodicWorkspaceGitMetadataRefreshRestoresClearedBranchForStaleTerminal() throws {
        let fileManager = FileManager.default
        let repoURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-git-stale-branch-refresh-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repoURL) }

        try runGit(["init", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "seed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repoURL)
        try runGit(["commit", "-m", "Initial commit"], in: repoURL)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)
        manager.updateSurfaceGitBranch(tabId: workspace.id, surfaceId: panelId, branch: "main", isDirty: false)
        manager.clearSurfaceGitBranch(tabId: workspace.id, surfaceId: panelId)

        XCTAssertNil(workspace.panelGitBranches[panelId])

        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
            }
        )
        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["main"])
    }

    func testRemoteSplitSkipsInitialGitMetadataProbe() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                manager.activeWorkspaceGitProbePanelIdsForTesting(workspaceId: workspace.id).isEmpty
            }
        )

        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64017,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )

        guard let splitPanel = workspace.newTerminalSplit(from: panelId, orientation: .horizontal, focus: false) else {
            XCTFail("Expected remote split terminal panel to be created")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(splitPanel.id))
        XCTAssertEqual(manager.activeWorkspaceGitProbePanelIdsForTesting(workspaceId: workspace.id), Set<UUID>())
    }

    func testResolvedCommandPathFallsBackOutsideAppPATH() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-command-path-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let executableName = "cmux-gh-test-\(UUID().uuidString)"
        let executableURL = tempDir.appendingPathComponent(executableName)
        try """
        #!/bin/sh
        exit 0
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        XCTAssertEqual(
            TabManager.resolvedCommandPathForTesting(
                executable: executableName,
                environment: ["PATH": "/usr/bin:/bin"],
                fallbackDirectories: [tempDir.path]
            ),
            executableURL.path
        )
    }

    func testPeriodicWorkspaceGitMetadataRefreshClearsStalePullRequestAfterBranchReset() throws {
        let fileManager = FileManager.default
        let repoURL = fileManager.temporaryDirectory.appendingPathComponent("cmux-git-refresh-\(UUID().uuidString)")
        try fileManager.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repoURL) }

        try runGit(["init", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "seed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repoURL)
        try runGit(["commit", "-m", "Initial commit"], in: repoURL)
        try runGit(["checkout", "-b", "feature/sidebar-pr"], in: repoURL)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)
        manager.updateSurfaceGitBranch(tabId: workspace.id, surfaceId: panelId, branch: "feature/sidebar-pr", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 1052,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/1052")),
            status: .open,
            branch: "feature/sidebar-pr"
        )

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "feature/sidebar-pr")
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.number, 1052)
        XCTAssertEqual(workspace.sidebarPullRequestsInDisplayOrder().map(\.number), [1052])

        try runGit(["checkout", "main"], in: repoURL)

        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelPullRequests[panelId] == nil
            }
        )
        XCTAssertEqual(workspace.gitBranch?.branch, "main")
        XCTAssertNil(workspace.pullRequest)
        XCTAssertTrue(workspace.sidebarPullRequestsInDisplayOrder().isEmpty)
    }
}


@MainActor
final class TabManagerCloseWorkspacesWithConfirmationTests: XCTestCase {
    func testCloseWorkspacesWithConfirmationPromptsOnceAndClosesAcceptedWorkspaces() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")
        manager.setCustomTitle(tabId: third.id, title: "Gamma")

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return true
        }

        manager.closeWorkspacesWithConfirmation([manager.tabs[0].id, second.id], allowPinned: true)

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1, "Expected a single confirmation prompt for multi-close")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.map(\.title), ["Gamma"])
    }

    func testCloseWorkspacesWithConfirmationKeepsWorkspacesWhenCancelled() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return false
        }

        manager.closeWorkspacesWithConfirmation([manager.tabs[0].id, second.id], allowPinned: true)

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(prompts.first?.acceptCmdD, true)
        XCTAssertEqual(manager.tabs.map(\.title), ["Alpha", "Beta"])
    }

    func testCloseCurrentWorkspaceWithConfirmationUsesSidebarMultiSelection() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")
        manager.setCustomTitle(tabId: third.id, title: "Gamma")
        manager.selectWorkspace(second)
        manager.setSidebarSelectedWorkspaceIds([manager.tabs[0].id, second.id])

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return false
        }

        manager.closeCurrentWorkspaceWithConfirmation()

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1, "Expected Cmd+Shift+W path to reuse the multi-close summary dialog")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.map(\.title), ["Alpha", "Beta", "Gamma"])
    }
}

@MainActor
final class TabManagerCloseCurrentTabSpamTests: XCTestCase {
    func testCloseCurrentTabSpamWithConfirmationEnabledPromptsOnceAndClosesOneWorkspace() {
        let manager = TabManager()
        while manager.tabs.count < 6 {
            _ = manager.addWorkspace()
        }

        for workspace in manager.tabs {
            guard let panelId = workspace.focusedPanelId,
                  let terminalPanel = workspace.terminalPanel(for: panelId) else {
                XCTFail("Expected each workspace to have a focused terminal panel")
                return
            }
            terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        }

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return true
        }

        for _ in 0..<5 {
            manager.closeCurrentTabWithConfirmation()
        }

        XCTAssertEqual(prompts.count, 1, "Expected close-tab spam to surface only one confirmation prompt")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?")
        )
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.count, 5, "Expected only one workspace to close after the first accepted confirmation")
    }

    func testCloseCurrentTabSpamWithConfirmationDisabledClosesEveryRequestedWorkspace() {
        let manager = TabManager()
        while manager.tabs.count < 6 {
            _ = manager.addWorkspace()
        }

        for workspace in manager.tabs {
            guard let panelId = workspace.focusedPanelId,
                  let terminalPanel = workspace.terminalPanel(for: panelId) else {
                XCTFail("Expected each workspace to have a focused terminal panel")
                return
            }
            terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(false)
        }

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return true
        }

        for _ in 0..<5 {
            manager.closeCurrentTabWithConfirmation()
        }

        XCTAssertEqual(promptCount, 0, "Expected warning-disabled close-tab spam to bypass confirmation entirely")
        XCTAssertEqual(manager.tabs.count, 1, "Expected warning-disabled close-tab spam to close all requested workspaces")
    }
}


@MainActor
final class TabManagerCloseCurrentPanelTests: XCTestCase {
    func testRuntimeCloseSkipsConfirmationWhenShellReportsPromptIdle() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected selected workspace and focused terminal panel")
            return
        }

        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeRuntimeSurfaceWithConfirmation(tabId: workspace.id, surfaceId: panelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(promptCount, 0, "Runtime closes should honor prompt-idle shell state")
        XCTAssertNil(workspace.panels[panelId], "Expected the original panel to close")
        XCTAssertEqual(workspace.panels.count, 1, "Expected a replacement surface after closing the last panel")
    }

    func testRuntimeClosePromptsWhenShellReportsRunningCommand() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected selected workspace and focused terminal panel")
            return
        }

        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(false)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeRuntimeSurfaceWithConfirmation(tabId: workspace.id, surfaceId: panelId)

        XCTAssertEqual(promptCount, 1, "Running commands should still require confirmation")
        XCTAssertNotNil(workspace.panels[panelId], "Prompt rejection should keep the original panel open")
    }

    func testCloseCurrentPanelClosesWorkspaceWhenItOwnsTheLastSurface() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertEqual(secondWorkspace.panels.count, 1)

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testCloseCurrentPanelPromptsBeforeClosingPinnedWorkspaceLastSurface() {
        let manager = TabManager()
        _ = manager.tabs[0]
        let pinnedWorkspace = manager.addWorkspace()
        manager.setPinned(pinnedWorkspace, pinned: true)
        manager.selectWorkspace(pinnedWorkspace)

        guard let pinnedPanelId = pinnedWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in pinned workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, pinnedWorkspace.id)
        XCTAssertEqual(pinnedWorkspace.panels.count, 1)

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return false
        }

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closePinnedWorkspace.title", defaultValue: "Close pinned workspace?")
        )
        XCTAssertEqual(
            prompts.first?.message,
            String(
                localized: "dialog.closePinnedWorkspace.message",
                defaultValue: "This workspace is pinned. Closing it will close the workspace and all of its panels."
            )
        )
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }))
        XCTAssertEqual(manager.selectedTabId, pinnedWorkspace.id)
        XCTAssertNotNil(pinnedWorkspace.panels[pinnedPanelId])
        XCTAssertEqual(pinnedWorkspace.panels.count, 1)
    }

    func testCloseCurrentPanelClosesPinnedWorkspaceAfterConfirmation() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let pinnedWorkspace = manager.addWorkspace()
        manager.setPinned(pinnedWorkspace, pinned: true)
        manager.selectWorkspace(pinnedWorkspace)

        guard let pinnedPanelId = pinnedWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in pinned workspace")
            return
        }

        manager.confirmCloseHandler = { _, _, _ in true }

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(pinnedWorkspace.panels[pinnedPanelId])
        XCTAssertTrue(pinnedWorkspace.panels.isEmpty)
    }

    func testCloseCurrentPanelKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: lastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: lastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: lastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: lastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        let initialWorkspaceId = workspace.id

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, initialWorkspaceId)
        XCTAssertEqual(manager.tabs.first?.id, initialWorkspaceId)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testClosePanelButtonClosesWorkspaceWhenItOwnsTheLastSurface() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertEqual(secondWorkspace.panels.count, 1)

        guard let secondSurfaceId = secondWorkspace.surfaceIdFromPanelId(secondPanelId) else {
            XCTFail("Expected bonsplit surface ID for focused panel")
            return
        }

        secondWorkspace.markExplicitClose(surfaceId: secondSurfaceId)
        XCTAssertFalse(secondWorkspace.closePanel(secondPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testClosePanelButtonStillClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsEnabled() {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: lastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: lastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: lastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: lastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        guard let secondSurfaceId = secondWorkspace.surfaceIdFromPanelId(secondPanelId) else {
            XCTFail("Expected bonsplit surface ID for focused panel")
            return
        }

        secondWorkspace.markExplicitClose(surfaceId: secondSurfaceId)
        XCTAssertFalse(secondWorkspace.closePanel(secondPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testGenericClosePanelKeepsWorkspaceOpenWithoutExplicitCloseMarker() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        let initialWorkspaceId = workspace.id
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(workspace.panels.count, 1)

        XCTAssertTrue(workspace.closePanel(initialPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, initialWorkspaceId)
        XCTAssertEqual(manager.tabs.first?.id, initialWorkspaceId)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testCloseCurrentPanelIgnoresStaleSurfaceId() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()

        manager.closePanelWithConfirmation(tabId: secondWorkspace.id, surfaceId: UUID())

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id, secondWorkspace.id])
    }

    func testCloseCurrentPanelClearsNotificationsForClosedSurface() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: initialPanelId,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: initialPanelId))

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: initialPanelId))
    }
}


@MainActor
final class TabManagerNotificationFocusTests: XCTestCase {
    func testFocusTabFromNotificationClearsSplitZoomBeforeFocusingTargetPanel() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftPanelId)
        XCTAssertTrue(workspace.toggleSplitZoom(panelId: leftPanelId), "Expected split zoom to enable")
        XCTAssertTrue(workspace.bonsplitController.isSplitZoomed, "Expected workspace to start zoomed")

        XCTAssertTrue(manager.focusTabFromNotification(workspace.id, surfaceId: rightPanel.id))
        drainMainQueue()
        drainMainQueue()

        XCTAssertFalse(
            workspace.bonsplitController.isSplitZoomed,
            "Expected notification focus to exit split zoom so the target pane becomes visible"
        )
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id, "Expected notification target panel to be focused")
    }

    func testFocusTabFromNotificationReturnsFalseForMissingPanel() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        XCTAssertFalse(manager.focusTabFromNotification(workspace.id, surfaceId: UUID()))
    }

    func testFocusTabFromNotificationDismissesUnreadWithDismissFlash() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        workspace.focusPanel(leftPanelId)
        store.addNotification(
            tabId: workspace.id,
            surfaceId: rightPanel.id,
            title: "Unread",
            subtitle: "",
            body: "Right pane should dismiss attention when focused from a notification"
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: rightPanel.id))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: rightPanel.id))
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)

        XCTAssertTrue(manager.focusTabFromNotification(workspace.id, surfaceId: rightPanel.id))

        let expectation = XCTestExpectation(description: "notification focus flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: rightPanel.id))
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: rightPanel.id))
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 1)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashPanelId, rightPanel.id)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashReason, .notificationDismiss)
    }
}


@MainActor
final class TabManagerPendingUnfocusPolicyTests: XCTestCase {
    func testDoesNotUnfocusWhenPendingTabIsCurrentlySelected() {
        let tabId = UUID()

        XCTAssertFalse(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: tabId,
                selectedTabId: tabId
            )
        )
    }

    func testUnfocusesWhenPendingTabIsNotSelected() {
        XCTAssertTrue(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: UUID(),
                selectedTabId: UUID()
            )
        )
        XCTAssertTrue(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: UUID(),
                selectedTabId: nil
            )
        )
    }
}


@MainActor
final class TabManagerSurfaceCreationTests: XCTestCase {
    func testNewSurfaceFocusesCreatedSurface() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected a selected workspace")
            return
        }

        let beforePanels = Set(workspace.panels.keys)
        manager.newSurface()
        let afterPanels = Set(workspace.panels.keys)

        let createdPanels = afterPanels.subtracting(beforePanels)
        XCTAssertEqual(createdPanels.count, 1, "Expected one new surface for Cmd+T path")
        guard let createdPanelId = createdPanels.first else { return }

        XCTAssertEqual(
            workspace.focusedPanelId,
            createdPanelId,
            "Expected newly created surface to be focused"
        )
    }

    func testOpenBrowserInsertAtEndPlacesNewBrowserAtPaneEnd() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused workspace and pane")
            return
        }

        // Add one extra surface so we verify append-to-end rather than first insert behavior.
        _ = workspace.newTerminalSurface(inPane: paneId, focus: false)

        guard let browserPanelId = manager.openBrowser(insertAtEnd: true) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        let tabs = workspace.bonsplitController.tabs(inPane: paneId)
        guard let lastSurfaceId = tabs.last?.id else {
            XCTFail("Expected at least one surface in pane")
            return
        }

        XCTAssertEqual(
            workspace.panelIdFromSurfaceId(lastSurfaceId),
            browserPanelId,
            "Expected Cmd+Shift+B/Cmd+L open path to append browser surface at end"
        )
        XCTAssertEqual(workspace.focusedPanelId, browserPanelId, "Expected opened browser surface to be focused")
    }

    func testOpenBrowserInWorkspaceSplitRightSelectsTargetWorkspaceAndCreatesSplit() {
        let manager = TabManager()
        guard let initialWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial selected workspace")
            return
        }
        guard let url = URL(string: "https://example.com/pull/123") else {
            XCTFail("Expected test URL to be valid")
            return
        }

        let targetWorkspace = manager.addWorkspace(select: false)
        manager.selectWorkspace(initialWorkspace)
        let initialPaneCount = targetWorkspace.bonsplitController.allPaneIds.count
        let initialPanelCount = targetWorkspace.panels.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: targetWorkspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created in target workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, targetWorkspace.id, "Expected target workspace to become selected")
        XCTAssertEqual(
            targetWorkspace.bonsplitController.allPaneIds.count,
            initialPaneCount + 1,
            "Expected split-right browser open to create a new pane"
        )
        XCTAssertEqual(
            targetWorkspace.panels.count,
            initialPanelCount + 1,
            "Expected browser panel count to increase by one"
        )
        XCTAssertEqual(
            targetWorkspace.focusedPanelId,
            browserPanelId,
            "Expected created browser panel to be focused in target workspace"
        )
        XCTAssertTrue(
            targetWorkspace.panels[browserPanelId] is BrowserPanel,
            "Expected created panel to be a browser panel"
        )
    }

    func testOpenBrowserInWorkspaceSplitRightReusesTopRightPaneWhenAlreadySplit() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let topRightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              workspace.newTerminalSplit(from: topRightPanel.id, orientation: .vertical) != nil,
              let topRightPaneId = workspace.paneId(forPanelId: topRightPanel.id),
              let url = URL(string: "https://example.com/pull/456") else {
            XCTFail("Expected split setup to succeed")
            return
        }

        let initialPaneCount = workspace.bonsplitController.allPaneIds.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: workspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            initialPaneCount,
            "Expected split-right browser open to reuse existing panes"
        )
        XCTAssertEqual(
            workspace.paneId(forPanelId: browserPanelId),
            topRightPaneId,
            "Expected browser to open in the top-right pane when multiple splits already exist"
        )

        let targetPaneTabs = workspace.bonsplitController.tabs(inPane: topRightPaneId)
        guard let lastSurfaceId = targetPaneTabs.last?.id else {
            XCTFail("Expected top-right pane to contain tabs")
            return
        }
        XCTAssertEqual(
            workspace.panelIdFromSurfaceId(lastSurfaceId),
            browserPanelId,
            "Expected browser surface to be appended at end in the reused top-right pane"
        )
    }
}


@MainActor
final class TabManagerEqualizeSplitsTests: XCTestCase {
    func testEqualizeSplitsSetsEverySplitDividerToHalf() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              workspace.newTerminalSplit(from: rightPanel.id, orientation: .vertical) != nil else {
            XCTFail("Expected nested split setup to succeed")
            return
        }

        let initialSplits = splitNodes(in: workspace.bonsplitController.treeSnapshot())
        XCTAssertGreaterThanOrEqual(initialSplits.count, 2, "Expected at least two split nodes in nested layout")

        for (index, split) in initialSplits.enumerated() {
            guard let splitId = UUID(uuidString: split.id) else {
                XCTFail("Expected split ID to be a UUID")
                return
            }
            let targetPosition: CGFloat = index.isMultiple(of: 2) ? 0.2 : 0.8
            XCTAssertTrue(
                workspace.bonsplitController.setDividerPosition(targetPosition, forSplit: splitId),
                "Expected to seed divider position for split \(splitId)"
            )
        }

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        let equalizedSplits = splitNodes(in: workspace.bonsplitController.treeSnapshot())
        XCTAssertEqual(equalizedSplits.count, initialSplits.count)
        for split in equalizedSplits {
            XCTAssertEqual(split.dividerPosition, 0.5, accuracy: 0.000_1)
        }
    }
}

@MainActor
final class TabManagerResizeSplitsTests: XCTestCase {
    func testResizeSplitMovesHorizontalDividerRightForFirstChildPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) != nil else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.5, forSplit: splitId),
            "Expected to seed divider position"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: leftPanelId, direction: .right, amount: 120),
            "Expected resizeSplit to succeed for the right edge of the left pane"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertGreaterThan(
            updatedSplit.dividerPosition,
            0.5,
            "Expected resizing the left pane to the right to move the divider toward the second child"
        )
    }

    func testResizeSplitMovesHorizontalDividerLeftForSecondChildPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.5, forSplit: splitId),
            "Expected to seed divider position"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: rightPanel.id, direction: .left, amount: 120),
            "Expected resizeSplit to succeed for the left edge of the right pane"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertLessThan(
            updatedSplit.dividerPosition,
            0.5,
            "Expected resizing the right pane to the left to move the divider toward the first child"
        )
    }

    func testResizeSplitMovesVerticalDividerDownForFirstChildPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let topPanelId = workspace.focusedPanelId,
              workspace.newTerminalSplit(from: topPanelId, orientation: .vertical) != nil else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.5, forSplit: splitId),
            "Expected to seed divider position"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: topPanelId, direction: .down, amount: 120),
            "Expected resizeSplit to succeed for the bottom edge of the top pane"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertGreaterThan(
            updatedSplit.dividerPosition,
            0.5,
            "Expected resizing the top pane downward to move the divider toward the second child"
        )
    }

    func testResizeSplitMovesVerticalDividerUpForSecondChildPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let topPanelId = workspace.focusedPanelId,
              let bottomPanel = workspace.newTerminalSplit(from: topPanelId, orientation: .vertical) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.5, forSplit: splitId),
            "Expected to seed divider position"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: bottomPanel.id, direction: .up, amount: 120),
            "Expected resizeSplit to succeed for the top edge of the bottom pane"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertLessThan(
            updatedSplit.dividerPosition,
            0.5,
            "Expected resizing the bottom pane upward to move the divider toward the first child"
        )
    }

    func testResizeSplitReturnsFalseWhenPaneHasNoBorderInDirection() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) != nil else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertFalse(
            manager.resizeSplit(tabId: workspace.id, surfaceId: leftPanelId, direction: .left, amount: 120),
            "Expected resizeSplit to fail when the pane has no adjacent border in that direction"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }
        XCTAssertEqual(updatedSplit.dividerPosition, split.dividerPosition, accuracy: 0.000_1)
    }

    func testResizeSplitClampsDividerPositionAtUpperBound() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) != nil else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.89, forSplit: splitId),
            "Expected to seed divider position near upper bound"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: leftPanelId, direction: .right, amount: 10_000),
            "Expected resizeSplit to clamp instead of failing"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertEqual(updatedSplit.dividerPosition, 0.9, accuracy: 0.000_1)
    }

    func testResizeSplitClampsDividerPositionAtLowerBound() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let topPanelId = workspace.focusedPanelId,
              let bottomPanel = workspace.newTerminalSplit(from: topPanelId, orientation: .vertical) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.11, forSplit: splitId),
            "Expected to seed divider position near lower bound"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: bottomPanel.id, direction: .up, amount: 10_000),
            "Expected resizeSplit to clamp instead of failing"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertEqual(updatedSplit.dividerPosition, 0.1, accuracy: 0.000_1)
    }
}


@MainActor
final class TabManagerWorkspaceConfigInheritanceSourceTests: XCTestCase {
    func testUsesFocusedTerminalWhenTerminalIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused terminal")
            return
        }

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(sourcePanel?.id, terminalPanelId)
    }

    func testFallsBackToTerminalWhenBrowserIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected selected workspace setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourcePanel?.id,
            terminalPanelId,
            "Expected new workspace inheritance source to resolve to the pane terminal when browser is focused"
        )
    }

    func testPrefersLastFocusedTerminalAcrossPanesWhenBrowserIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.newTerminalSplit(from: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.newBrowserSurface(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourcePanel?.id,
            leftTerminalPanelId,
            "Expected workspace inheritance source to use last focused terminal across panes"
        )
    }
}


@MainActor
final class TabManagerFocusedNotificationIndicatorTests: XCTestCase {
    func testFocusPanelDismissesUnreadNotificationWithDismissFlash() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: leftPanelId,
            title: "Unread",
            subtitle: "",
            body: "Left pane should dismiss attention when focused"
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: leftPanelId))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: leftPanelId))
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)

        workspace.focusPanel(leftPanelId)

        XCTAssertEqual(workspace.focusedPanelId, leftPanelId)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: leftPanelId))
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: leftPanelId))
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 1)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashPanelId, leftPanelId)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashReason, .notificationDismiss)
    }

    func testDismissNotificationOnDirectInteractionClearsFocusedNotificationIndicator() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        XCTAssertTrue(
            manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: panelId)
        )
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
    }

    func testDismissNotificationOnDirectInteractionTriggersDismissFlashForFocusedIndicatorOnly() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)

        XCTAssertTrue(
            manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: panelId)
        )

        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            1,
            "Expected dismissing a focused-read indicator to emit a dismiss flash even when unread is already cleared"
        )
        XCTAssertEqual(workspace.tmuxWorkspaceFlashPanelId, panelId)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashReason, .notificationDismiss)
    }
}

@MainActor
final class TabManagerReopenClosedBrowserFocusTests: XCTestCase {
    func testStandardBrowserTabCloseStagesRestoreSnapshot() {
        let workspace = Workspace()
        let expectedURL = URL(string: "https://example.com/standard-close")
        guard let paneId = workspace.bonsplitController.focusedPaneId,
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, url: expectedURL, focus: false),
              let tabId = workspace.surfaceIdFromPanelId(browserPanel.id),
              let tab = workspace.bonsplitController.tab(tabId) else {
            XCTFail("Expected browser panel setup")
            return
        }

        var closedSnapshot: ClosedBrowserPanelRestoreSnapshot?
        workspace.onClosedBrowserPanel = { snapshot in
            closedSnapshot = snapshot
        }

        XCTAssertTrue(workspace.splitTabBar(workspace.bonsplitController, shouldCloseTab: tab, inPane: paneId))
        workspace.splitTabBar(workspace.bonsplitController, didCloseTab: tabId, fromPane: paneId)

        XCTAssertEqual(closedSnapshot?.workspaceId, workspace.id)
        XCTAssertEqual(closedSnapshot?.url, expectedURL)
        XCTAssertEqual(closedSnapshot?.originalPaneId, paneId.id)
    }

    func testReopenFromDifferentWorkspaceFocusesReopenedBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/ws-switch")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFallsBackToCurrentWorkspaceAndFocusesBrowserWhenOriginalWorkspaceDeleted() {
        let manager = TabManager()
        guard let originalWorkspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/deleted-ws")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(originalWorkspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let currentWorkspace = manager.addWorkspace()
        manager.closeWorkspace(originalWorkspace)

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == originalWorkspace.id }))

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: currentWorkspace))
    }

    func testReopenCollapsedSplitFromDifferentWorkspaceFocusesBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let sourcePanelId = workspace1.focusedPanelId,
              let splitBrowserId = manager.newBrowserSplit(
                tabId: workspace1.id,
                fromPanelId: sourcePanelId,
                orientation: .horizontal,
                insertFirst: false,
                url: URL(string: "https://example.com/collapsed-split")
              ) else {
            XCTFail("Expected to create browser split")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(splitBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFromDifferentWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let preReopenPanelId = workspace1.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-cross-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace1.panels.keys)
        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace1, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace1.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertEqual(workspace1.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace1.panels[reopenedPanelId] is BrowserPanel)
    }

    func testReopenInSameWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let preReopenPanelId = workspace.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-same-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace.panels.keys)
        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(workspace.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace.panels[reopenedPanelId] is BrowserPanel)
    }

    private func isFocusedPanelBrowser(in workspace: Workspace) -> Bool {
        guard let focusedPanelId = workspace.focusedPanelId else { return false }
        return workspace.panels[focusedPanelId] is BrowserPanel
    }

    private func singleNewPanelId(in workspace: Workspace, comparedTo previousPanelIds: Set<UUID>) -> UUID? {
        let newPanelIds = Set(workspace.panels.keys).subtracting(previousPanelIds)
        guard newPanelIds.count == 1 else { return nil }
        return newPanelIds.first
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        let result = XCTWaiter().wait(for: [expectation], timeout: 3.0)
        XCTAssertEqual(result, .completed)
    }
}
