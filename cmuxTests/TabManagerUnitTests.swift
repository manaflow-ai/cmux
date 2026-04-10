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

private func makeTempGitRepoWithInitialCommit(
    prefix: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> URL {
    let fileManager = FileManager.default
    let repoURL = fileManager.temporaryDirectory.appendingPathComponent(
        "\(prefix)-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(at: repoURL, withIntermediateDirectories: true)

    do {
        try runGit(["init", "-b", "main"], in: repoURL, file: file, line: line)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL, file: file, line: line)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL, file: file, line: line)
        try "seed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repoURL, file: file, line: line)
        try runGit(["commit", "-m", "Initial commit"], in: repoURL, file: file, line: line)
        return repoURL
    } catch {
        try? fileManager.removeItem(at: repoURL)
        throw error
    }
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

    func testShouldSkipWorkspacePullRequestLookupOnlyForExactMainAndMaster() {
        XCTAssertTrue(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "main"))
        XCTAssertTrue(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "master"))
        XCTAssertTrue(TabManager.shouldSkipWorkspacePullRequestLookup(branch: " master \n"))

        XCTAssertFalse(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "Main"))
        XCTAssertFalse(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "mainline"))
        XCTAssertFalse(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "feature/main"))
        XCTAssertFalse(TabManager.shouldSkipWorkspacePullRequestLookup(branch: "release/master-fix"))
    }

    func testWorkspacePullRequestRefreshDoesNotAllowRepoCacheForCurrentReasons() {
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "localGitProbe"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "localGitProbe.followUp"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "gitFsEvent"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "gitFsEvent.followUp"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "branchChange"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "branchChange.followUp"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "directoryChange"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "shellPrompt"))
        XCTAssertFalse(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "commandHint:merge"))
    }

    func testWorkspacePullRequestRefreshAllowsRepoCacheForTimerReasons() {
        XCTAssertTrue(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "timer"))
        XCTAssertTrue(TabManager.workspacePullRequestRefreshAllowsRepoCache(reason: "timer.followUp"))
    }

    func testWorkspacePullRequestTimerRefreshRetriesEmptyCachedRepositorySlugs() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-pr-slug-retry")
        defer { try? fileManager.removeItem(at: repoURL) }

        try runGit(["remote", "add", "origin", "https://github.com/manaflow-ai/cmux.git"], in: repoURL)

        XCTAssertEqual(
            TabManager.resolvedRepositorySlugsForPullRequestRefreshForTesting(
                directory: repoURL.path,
                cachedRepositorySlugs: [],
                reason: "timer"
            ),
            ["manaflow-ai/cmux"]
        )
    }

    func testWorkspacePullRequestOnDemandRefreshUsesCurrentPanelDirectoryAfterRepoSwitch() throws {
        let fileManager = FileManager.default
        let oldRepoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-pr-old-repo")
        let newRepoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-pr-new-repo")
        defer {
            try? fileManager.removeItem(at: oldRepoURL)
            try? fileManager.removeItem(at: newRepoURL)
        }

        try runGit(["remote", "add", "origin", "https://github.com/manaflow-ai/cmux.git"], in: oldRepoURL)
        try runGit(["remote", "add", "origin", "https://github.com/ghostty-org/ghostty.git"], in: newRepoURL)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: oldRepoURL.path)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                manager.attachedWorkspaceGitWatcherPanelIdsForTesting(workspaceId: workspace.id)
                    .contains(panelId)
            }
        )

        workspace.updatePanelDirectory(panelId: panelId, directory: newRepoURL.path)

        XCTAssertEqual(
            manager.resolvedRepositorySlugsForPanelPullRequestRefreshForTesting(
                workspaceId: workspace.id,
                panelId: panelId,
                reason: "shellPrompt"
            ),
            ["ghostty-org/ghostty"]
        )
    }

    func testWorkspacePullRequestShouldRefreshHonorsScheduledPollsAndTerminalSweeps() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recentTerminalRefresh = now.addingTimeInterval(-60)

        XCTAssertTrue(
            TabManager.shouldRefreshWorkspacePullRequestForTesting(
                now: now,
                nextPollAt: .distantPast,
                lastTerminalStateRefreshAt: recentTerminalRefresh,
                currentPullRequestStatus: .merged
            )
        )
        XCTAssertFalse(
            TabManager.shouldRefreshWorkspacePullRequestForTesting(
                now: now,
                nextPollAt: now.addingTimeInterval(60),
                lastTerminalStateRefreshAt: recentTerminalRefresh,
                currentPullRequestStatus: .closed
            )
        )
        XCTAssertFalse(
            TabManager.shouldRefreshWorkspacePullRequestForTesting(
                now: now,
                nextPollAt: now.addingTimeInterval(60),
                lastTerminalStateRefreshAt: nil,
                currentPullRequestStatus: .open
            )
        )
    }

    func testWorkspacePullRequestRefreshThrottlesKnownAbsentBranchWithinCacheLifetime() {
        XCTAssertFalse(
            TabManager.shouldRefreshKnownAbsentWorkspacePullRequestForTesting(
                branch: "feature/no-pr",
                absentBranch: "feature/no-pr",
                absentAge: 14
            )
        )
        XCTAssertTrue(
            TabManager.shouldRefreshKnownAbsentWorkspacePullRequestForTesting(
                branch: "feature/no-pr",
                absentBranch: "feature/no-pr",
                absentAge: 16
            )
        )
        XCTAssertTrue(
            TabManager.shouldRefreshKnownAbsentWorkspacePullRequestForTesting(
                branch: "feature/no-pr",
                absentBranch: "feature/other",
                absentAge: 1
            )
        )
        XCTAssertTrue(
            TabManager.shouldRefreshKnownAbsentWorkspacePullRequestForTesting(
                branch: "feature/no-pr",
                absentBranch: nil,
                absentAge: nil
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

    func testPeriodicWorkspaceGitMetadataRefreshClearsDirtyStateWhenWatcherOptsOut() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-dirty-optout-refresh")
        defer { try? fileManager.removeItem(at: repoURL) }

        try "changed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main" &&
                    workspace.panelGitBranches[panelId]?.isDirty == true
            }
        )

        try "".write(
            to: repoURL.appendingPathComponent(".cmuxignore"),
            atomically: true,
            encoding: .utf8
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main" &&
                    workspace.panelGitBranches[panelId]?.isDirty == false
            }
        )
        XCTAssertEqual(workspace.gitBranch?.branch, "main")
        XCTAssertEqual(workspace.gitBranch?.isDirty, false)
    }

    func testFallbackWorkspaceGitMetadataRefreshUpdatesDirtyStateWhenWatcherStartFails() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-fallback-refresh")
        TabManager.setWorkspaceGitWatcherForceStartFailureForTesting(true)
        defer {
            TabManager.setWorkspaceGitWatcherForceStartFailureForTesting(false)
            try? fileManager.removeItem(at: repoURL)
        }

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && manager.attachedWorkspaceGitWatcherPanelIdsForTesting(workspaceId: workspace.id).isEmpty
            }
        )

        try "changed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        manager.refreshFallbackWorkspaceGitMetadataForTesting(now: .distantFuture)

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == true
            }
        )
    }

    func testFallbackWorkspaceGitMetadataRefreshRecoversAfterOptOutIsRemoved() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-fallback-optout-recovery")
        TabManager.setWorkspaceGitWatcherForceStartFailureForTesting(true)
        defer {
            TabManager.setWorkspaceGitWatcherForceStartFailureForTesting(false)
            try? fileManager.removeItem(at: repoURL)
        }

        try "".write(
            to: repoURL.appendingPathComponent(".cmuxignore"),
            atomically: true,
            encoding: .utf8
        )
        try "changed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
                    && manager.attachedWorkspaceGitWatcherPanelIdsForTesting(workspaceId: workspace.id).isEmpty
            }
        )

        try fileManager.removeItem(at: repoURL.appendingPathComponent(".cmuxignore"))

        manager.refreshFallbackWorkspaceGitMetadataForTesting(now: .distantFuture)

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == true
            }
        )
    }

    func testWorkspaceGitProbeResetsDirtyStateWhenStatusUnavailableAfterRepositoryChange() throws {
        let fileManager = FileManager.default
        let dirtyRepoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-status-fallback-dirty")
        let cleanRepoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-status-fallback-clean")
        defer {
            try? fileManager.removeItem(at: dirtyRepoURL)
            try? fileManager.removeItem(at: cleanRepoURL)
        }

        try "changed\n".write(
            to: dirtyRepoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: dirtyRepoURL.path)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == true
            }
        )

        TabManager.setWorkspaceGitStatusFailureForTesting(true)
        defer { TabManager.setWorkspaceGitStatusFailureForTesting(false) }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: cleanRepoURL.path)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            }
        )
    }

    func testDirectoryChangeClearsStaleSidebarGitMetadataWhenWorkspaceWatcherDisabled() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-disabled-dir-change")
        let nextDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-git-disabled-dir-change-target-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: nextDirectoryURL)
            try? fileManager.removeItem(at: repoURL)
        }

        try fileManager.createDirectory(at: nextDirectoryURL, withIntermediateDirectories: true)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)
        manager.setWorkspaceGitMetadataWatcherDisabled(workspaceIds: [workspace.id], disabled: true)

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/stale-sidebar", isDirty: true)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2048,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/2048")),
            status: .open,
            branch: "feature/stale-sidebar"
        )

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "feature/stale-sidebar")
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.number, 2048)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: nextDirectoryURL.path
        )

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId] == nil
                    && workspace.panelPullRequests[panelId] == nil
                    && workspace.gitBranch == nil
                    && workspace.pullRequest == nil
            }
        )
        XCTAssertTrue(workspace.sidebarGitBranchesInDisplayOrder().isEmpty)
        XCTAssertTrue(workspace.sidebarPullRequestsInDisplayOrder().isEmpty)
    }

    func testGlobalGitMetadataWatcherDisableClearsUnscopedSidebarMetadata() throws {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: GitMetadataWatcherSettings.disabledKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: GitMetadataWatcherSettings.disabledKey)
            } else {
                defaults.removeObject(forKey: GitMetadataWatcherSettings.disabledKey)
            }
        }

        defaults.set(false, forKey: GitMetadataWatcherSettings.disabledKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.gitBranch = SidebarGitBranchState(branch: "feature/unscoped", isDirty: true)
        workspace.pullRequest = SidebarPullRequestState(
            number: 2718,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/2718")),
            status: .open,
            branch: "feature/unscoped",
            isStale: false
        )

        defaults.set(true, forKey: GitMetadataWatcherSettings.disabledKey)
        manager.handleGitMetadataWatcherDefaultsChangeForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.gitBranch == nil && workspace.pullRequest == nil
            }
        )
    }

    func testGlobalGitMetadataWatcherDisablePreservesRemoteWorkspaceMetadata() throws {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: GitMetadataWatcherSettings.disabledKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: GitMetadataWatcherSettings.disabledKey)
            } else {
                defaults.removeObject(forKey: GitMetadataWatcherSettings.disabledKey)
            }
        }

        defaults.set(false, forKey: GitMetadataWatcherSettings.disabledKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
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
                relayPort: 64017,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        drainMainQueue()
        XCTAssertTrue(workspace.isRemoteWorkspace)

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/remote", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 3001,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/3001")),
            status: .open,
            branch: "feature/remote"
        )

        defaults.set(true, forKey: GitMetadataWatcherSettings.disabledKey)
        manager.handleGitMetadataWatcherDefaultsChangeForTesting()

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "feature/remote")
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.number, 3001)
        XCTAssertEqual(workspace.gitBranch?.branch, "feature/remote")
        XCTAssertEqual(workspace.pullRequest?.number, 3001)
    }

    func testGlobalGitMetadataWatcherDisableClearsSidebarMetadataFromDefaultsChange() throws {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: GitMetadataWatcherSettings.disabledKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: GitMetadataWatcherSettings.disabledKey)
            } else {
                defaults.removeObject(forKey: GitMetadataWatcherSettings.disabledKey)
            }
        }

        defaults.set(false, forKey: GitMetadataWatcherSettings.disabledKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/global-disable", isDirty: true)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2723,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/2723")),
            status: .open,
            branch: "feature/global-disable"
        )

        defaults.set(true, forKey: GitMetadataWatcherSettings.disabledKey)
        manager.handleGitMetadataWatcherDefaultsChangeForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId] == nil
                    && workspace.panelPullRequests[panelId] == nil
                    && workspace.gitBranch == nil
                    && workspace.pullRequest == nil
            }
        )
        XCTAssertTrue(workspace.sidebarGitBranchesInDisplayOrder().isEmpty)
        XCTAssertTrue(workspace.sidebarPullRequestsInDisplayOrder().isEmpty)
    }

    func testGlobalGitMetadataWatcherEnableSkipsFocusedBrowserPanelReprobe() throws {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: GitMetadataWatcherSettings.disabledKey)
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-browser-reenable")
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: GitMetadataWatcherSettings.disabledKey)
            } else {
                defaults.removeObject(forKey: GitMetadataWatcherSettings.disabledKey)
            }
            try? fileManager.removeItem(at: repoURL)
        }

        defaults.set(false, forKey: GitMetadataWatcherSettings.disabledKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId) else {
            XCTFail("Expected selected workspace with focused terminal")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: terminalPanelId, directory: repoURL.path)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                workspace.panelGitBranches[terminalPanelId]?.branch == "main"
            }
        )

        guard let browserPanel = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected browser panel")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        defaults.set(true, forKey: GitMetadataWatcherSettings.disabledKey)
        manager.handleGitMetadataWatcherDefaultsChangeForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[terminalPanelId] == nil
                    && workspace.panelGitBranches[browserPanel.id] == nil
                    && workspace.gitBranch == nil
            }
        )

        defaults.set(false, forKey: GitMetadataWatcherSettings.disabledKey)
        manager.handleGitMetadataWatcherDefaultsChangeForTesting()

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                workspace.focusedPanelId == browserPanel.id
                    && workspace.panelGitBranches[terminalPanelId]?.branch == "main"
                    && workspace.panelGitBranches[browserPanel.id] == nil
                    && workspace.panelPullRequests[browserPanel.id] == nil
                    && workspace.gitBranch == nil
                    && workspace.pullRequest == nil
            }
        )
    }

    func testRepoLevelGitOptOutExcludesPanelFromPullRequestRefreshCandidates() throws {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: GitMetadataWatcherSettings.disabledKey)
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-pr-optout")
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: GitMetadataWatcherSettings.disabledKey)
            } else {
                defaults.removeObject(forKey: GitMetadataWatcherSettings.disabledKey)
            }
            try? fileManager.removeItem(at: repoURL)
        }

        defaults.set(false, forKey: GitMetadataWatcherSettings.disabledKey)

        try runGit(["checkout", "-b", "feature/optout-pr"], in: repoURL)
        try "".write(
            to: repoURL.appendingPathComponent(".cmuxignore"),
            atomically: true,
            encoding: .utf8
        )

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                workspace.panelGitBranches[panelId]?.branch == "feature/optout-pr"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            }
        )

        XCTAssertEqual(
            manager.trackedWorkspacePullRequestRefreshCandidatePanelIdsForTesting(workspaceId: workspace.id),
            Set<UUID>()
        )
    }

    func testIncludedGitConfigWatcherRefreshesDirtyStateAfterLiveOptOutChange() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-live-include-watch")
        defer { try? fileManager.removeItem(at: repoURL) }

        let gitDirectoryURL = repoURL.appendingPathComponent(".git", isDirectory: true)
        let configURL = gitDirectoryURL.appendingPathComponent("config")
        let includedConfigURL = gitDirectoryURL.appendingPathComponent("cmux-live-include.cfg")
        let existingConfig = try String(contentsOf: configURL, encoding: .utf8)
        try (
            existingConfig
            + """

            [include]
                path = cmux-live-include.cfg
            """
        ).write(to: configURL, atomically: true, encoding: .utf8)
        try """
        [cmux]
            metadataWatcher = false
        """.write(to: includedConfigURL, atomically: false, encoding: .utf8)
        try "changed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
                    && manager.attachedWorkspaceGitWatcherPanelIdsForTesting(workspaceId: workspace.id)
                    .contains(panelId)
            }
        )

        try """
        [cmux]
            metadataWatcher = true
        """.write(to: includedConfigURL, atomically: false, encoding: .utf8)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == true
            }
        )
        XCTAssertEqual(workspace.gitBranch?.branch, "main")
        XCTAssertEqual(workspace.gitBranch?.isDirty, true)
    }

    func testWorkspaceGitMetadataSummaryHonorsCmuxIgnoreOptOut() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-ignore-optout")
        defer { try? fileManager.removeItem(at: repoURL) }
        try "changed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: repoURL.appendingPathComponent(".cmuxignore"),
            atomically: true,
            encoding: .utf8
        )

        let summary = TabManager.workspaceGitMetadataSummaryForTesting(directory: repoURL.path)
        XCTAssertEqual(summary.branch, "main")
        XCTAssertNil(summary.isDirty)
        XCTAssertTrue(summary.isWatcherOptedOut)
        XCTAssertFalse(fileManager.fileExists(atPath: repoURL.appendingPathComponent(".git/index.lock").path))
    }

    func testWorkspaceGitMetadataSummaryHonorsGitConfigOptOut() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-config-optout")
        defer { try? fileManager.removeItem(at: repoURL) }
        try runGit(["config", "cmux.metadataWatcher", "false"], in: repoURL)
        try "changed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let summary = TabManager.workspaceGitMetadataSummaryForTesting(directory: repoURL.path)
        XCTAssertEqual(summary.branch, "main")
        XCTAssertNil(summary.isDirty)
        XCTAssertTrue(summary.isWatcherOptedOut)
        XCTAssertFalse(fileManager.fileExists(atPath: repoURL.appendingPathComponent(".git/index.lock").path))
    }

    func testWorkspaceGitMetadataSummaryHonorsIncludedGitConfigOptOut() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-include-optout")
        defer { try? fileManager.removeItem(at: repoURL) }

        let gitDirectoryURL = repoURL.appendingPathComponent(".git", isDirectory: true)
        let configURL = gitDirectoryURL.appendingPathComponent("config")
        let existingConfig = try String(contentsOf: configURL, encoding: .utf8)
        try (
            existingConfig
            + """

            [include]
                path = cmux-include.cfg
            """
        ).write(to: configURL, atomically: true, encoding: .utf8)
        try """
        [cmux]
            metadataWatcher = false
        """.write(
            to: gitDirectoryURL.appendingPathComponent("cmux-include.cfg"),
            atomically: true,
            encoding: .utf8
        )
        try "changed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let summary = TabManager.workspaceGitMetadataSummaryForTesting(directory: repoURL.path)
        XCTAssertEqual(summary.branch, "main")
        XCTAssertNil(summary.isDirty)
        XCTAssertTrue(summary.isWatcherOptedOut)
    }

    func testWorkspaceGitMetadataSummaryHonorsIncludeIfGitConfigOptOut() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-include-if-optout")
        defer { try? fileManager.removeItem(at: repoURL) }

        let gitDirectoryURL = repoURL.appendingPathComponent(".git", isDirectory: true)
        let configURL = gitDirectoryURL.appendingPathComponent("config")
        let existingConfig = try String(contentsOf: configURL, encoding: .utf8)
        try (
            existingConfig
            + """

            [includeIf "onbranch:main"]
                path = cmux-include-if.cfg
            """
        ).write(to: configURL, atomically: true, encoding: .utf8)
        try """
        [cmux]
            metadataWatcher = false
        """.write(
            to: gitDirectoryURL.appendingPathComponent("cmux-include-if.cfg"),
            atomically: true,
            encoding: .utf8
        )
        try "changed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let summary = TabManager.workspaceGitMetadataSummaryForTesting(directory: repoURL.path)
        XCTAssertEqual(summary.branch, "main")
        XCTAssertNil(summary.isDirty)
        XCTAssertTrue(summary.isWatcherOptedOut)
    }

    func testWorkspaceGitMetadataSummaryKeepsCleanRepoClean() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-clean")
        defer { try? fileManager.removeItem(at: repoURL) }

        let summary = TabManager.workspaceGitMetadataSummaryForTesting(directory: repoURL.path)
        XCTAssertEqual(summary.branch, "main")
        XCTAssertEqual(summary.isDirty, false)
        XCTAssertFalse(summary.isWatcherOptedOut)
        XCTAssertFalse(fileManager.fileExists(atPath: repoURL.appendingPathComponent(".git/index.lock").path))
    }

    func testWorkspaceGitMetadataSummaryReadsDirtyRepoWithoutCreatingIndexLock() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-no-lock")
        defer { try? fileManager.removeItem(at: repoURL) }
        try "changed\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let summary = TabManager.workspaceGitMetadataSummaryForTesting(directory: repoURL.path)
        XCTAssertEqual(summary.branch, "main")
        XCTAssertEqual(summary.isDirty, true)
        XCTAssertFalse(summary.isWatcherOptedOut)
        XCTAssertFalse(fileManager.fileExists(atPath: repoURL.appendingPathComponent(".git/index.lock").path))
    }

    func testWorkspaceGitMetadataSummaryUsesGlobalOptionalLocksFlagForStatus() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-global-optional-locks")
        let shimDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-git-shim-\(UUID().uuidString)",
            isDirectory: true
        )
        let shimURL = shimDirectoryURL.appendingPathComponent("git")
        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
            }
            try? fileManager.removeItem(at: shimDirectoryURL)
            try? fileManager.removeItem(at: repoURL)
        }

        try fileManager.createDirectory(at: shimDirectoryURL, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        if [ "$1" = "--no-optional-locks" ]; then
          shift
        fi
        if [ "$1" = "status" ]; then
          if [ "${GIT_OPTIONAL_LOCKS:-}" != "0" ]; then
            echo "status missing GIT_OPTIONAL_LOCKS=0" >&2
            exit 98
          fi
          case " $* " in
            *" --no-optional-locks "*) echo "status received --no-optional-locks after subcommand" >&2; exit 97 ;;
          esac
        fi
        exec /usr/bin/git "$@"
        """.write(to: shimURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)

        let shimPath = "\(shimDirectoryURL.path):\(originalPath ?? "/usr/bin:/bin:/usr/sbin:/sbin")"
        setenv("PATH", shimPath, 1)

        let summary = TabManager.workspaceGitMetadataSummaryForTesting(directory: repoURL.path)
        XCTAssertEqual(summary.branch, "main")
        XCTAssertEqual(summary.isDirty, false)
        XCTAssertFalse(summary.isWatcherOptedOut)
    }

    func testWorkspaceGitMetadataSummaryResolvesSymlinkedRepoDirectory() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-symlink")
        let nestedDirectoryURL = repoURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("subdir", isDirectory: true)
        let symlinkURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-git-symlink-link-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: symlinkURL)
            try? fileManager.removeItem(at: repoURL)
        }

        try fileManager.createDirectory(at: nestedDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: nestedDirectoryURL.path)

        let summary = TabManager.workspaceGitMetadataSummaryForTesting(directory: symlinkURL.path)
        XCTAssertEqual(summary.branch, "main")
        XCTAssertEqual(summary.isDirty, false)
        XCTAssertFalse(summary.isWatcherOptedOut)
    }

    func testGitHubRepositorySlugsForTestingReadsGitConfigRemotes() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-config-remotes")
        defer { try? fileManager.removeItem(at: repoURL) }

        try runGit(["remote", "add", "origin", "https://github.com/manaflow-ai/cmux.git"], in: repoURL)
        try runGit(["remote", "add", "upstream", "git@github.com:ghostty-org/ghostty.git"], in: repoURL)

        XCTAssertEqual(
            TabManager.githubRepositorySlugsForTesting(directory: repoURL.path),
            ["ghostty-org/ghostty", "manaflow-ai/cmux"]
        )
    }

    func testWorkspaceGitMetadataSummaryHonorsGitConfigOptOutInLinkedWorktree() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-worktree-optout")
        let worktreeURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-git-worktree-optout-linked-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: worktreeURL)
            try? fileManager.removeItem(at: repoURL)
        }

        try runGit(["config", "cmux.metadataWatcher", "false"], in: repoURL)
        try runGit(["worktree", "add", "-b", "feature/worktree-optout", worktreeURL.path], in: repoURL)

        let summary = TabManager.workspaceGitMetadataSummaryForTesting(directory: worktreeURL.path)
        XCTAssertEqual(summary.branch, "feature/worktree-optout")
        XCTAssertNil(summary.isDirty)
        XCTAssertTrue(summary.isWatcherOptedOut)
    }

    func testGitHubRepositorySlugsForTestingReadsRewrittenRemotesInLinkedWorktree() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-worktree-rewrite")
        let worktreeURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-git-worktree-rewrite-linked-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: worktreeURL)
            try? fileManager.removeItem(at: repoURL)
        }

        try runGit(["config", "url.git@github.com:.insteadOf", "gh:"], in: repoURL)
        try runGit(["remote", "add", "origin", "gh:manaflow-ai/cmux.git"], in: repoURL)
        try runGit(["remote", "add", "upstream", "gh:ghostty-org/ghostty.git"], in: repoURL)
        try runGit(["worktree", "add", "-b", "feature/worktree-rewrite", worktreeURL.path], in: repoURL)

        XCTAssertEqual(
            TabManager.githubRepositorySlugsForTesting(directory: worktreeURL.path),
            ["ghostty-org/ghostty", "manaflow-ai/cmux"]
        )
    }

    func testAttachWorkspaceReattachesGitWatcherAfterCrossWindowMove() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-move-watcher")
        defer { try? fileManager.removeItem(at: repoURL) }

        let sourceManager = TabManager()
        guard let workspace = sourceManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        sourceManager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)
        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                sourceManager.attachedWorkspaceGitWatcherPanelIdsForTesting(workspaceId: workspace.id)
                    .contains(panelId)
            }
        )

        let destinationManager = TabManager()
        let movedWorkspace = try XCTUnwrap(sourceManager.detachWorkspace(tabId: workspace.id))

        XCTAssertEqual(
            sourceManager.attachedWorkspaceGitWatcherPanelIdsForTesting(workspaceId: movedWorkspace.id),
            Set<UUID>()
        )

        destinationManager.attachWorkspace(movedWorkspace)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                destinationManager.attachedWorkspaceGitWatcherPanelIdsForTesting(workspaceId: movedWorkspace.id)
                    .contains(panelId)
            }
        )
    }

    func testAttachWorkspaceClearsGitMetadataWhenDestinationManagerGloballyDisabled() throws {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: GitMetadataWatcherSettings.disabledKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: GitMetadataWatcherSettings.disabledKey)
            } else {
                defaults.removeObject(forKey: GitMetadataWatcherSettings.disabledKey)
            }
        }

        defaults.set(false, forKey: GitMetadataWatcherSettings.disabledKey)

        let sourceManager = TabManager()
        guard let workspace = sourceManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/moved-disabled", isDirty: true)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 411,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/411")),
            status: .open,
            branch: "feature/moved-disabled"
        )

        let movedWorkspace = try XCTUnwrap(sourceManager.detachWorkspace(tabId: workspace.id))

        defaults.set(true, forKey: GitMetadataWatcherSettings.disabledKey)

        let destinationManager = TabManager()
        destinationManager.attachWorkspace(movedWorkspace)

        XCTAssertTrue(
            waitForCondition {
                movedWorkspace.panelGitBranches[panelId] == nil
                    && movedWorkspace.panelPullRequests[panelId] == nil
                    && movedWorkspace.gitBranch == nil
                    && movedWorkspace.pullRequest == nil
            }
        )
    }

    func testAttachWorkspaceClearsGitMetadataWhenWorkspaceWatcherDisabled() throws {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: GitMetadataWatcherSettings.disabledKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: GitMetadataWatcherSettings.disabledKey)
            } else {
                defaults.removeObject(forKey: GitMetadataWatcherSettings.disabledKey)
            }
        }

        defaults.set(false, forKey: GitMetadataWatcherSettings.disabledKey)

        let sourceManager = TabManager()
        guard let workspace = sourceManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/workspace-disabled", isDirty: true)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 512,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/512")),
            status: .open,
            branch: "feature/workspace-disabled"
        )

        let movedWorkspace = try XCTUnwrap(sourceManager.detachWorkspace(tabId: workspace.id))
        movedWorkspace.gitMetadataWatcherDisabled = true

        let destinationManager = TabManager()
        destinationManager.attachWorkspace(movedWorkspace)

        XCTAssertTrue(
            waitForCondition {
                movedWorkspace.panelGitBranches[panelId] == nil
                    && movedWorkspace.panelPullRequests[panelId] == nil
                    && movedWorkspace.gitBranch == nil
                    && movedWorkspace.pullRequest == nil
            }
        )
    }

    func testRestoreSessionSnapshotClearsGitWatchersForReplacedWorkspaces() throws {
        let fileManager = FileManager.default
        let repoURL = try makeTempGitRepoWithInitialCommit(prefix: "cmux-git-restore-watchers")
        defer { try? fileManager.removeItem(at: repoURL) }

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: panelId, directory: repoURL.path)
        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                manager.attachedWorkspaceGitWatcherPanelIdsForTesting(workspaceId: workspace.id)
                    .contains(panelId)
            }
        )

        manager.restoreSessionSnapshot(
            SessionTabManagerSnapshot(
                selectedWorkspaceIndex: nil,
                workspaces: []
            )
        )

        XCTAssertEqual(
            manager.attachedWorkspaceGitWatcherPanelIdsForTesting(workspaceId: workspace.id),
            Set<UUID>()
        )
    }

    func testRestoreSessionSnapshotClearsUnscopedGitBranchWhenGlobalWatcherDisabled() throws {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: GitMetadataWatcherSettings.disabledKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: GitMetadataWatcherSettings.disabledKey)
            } else {
                defaults.removeObject(forKey: GitMetadataWatcherSettings.disabledKey)
            }
        }

        defaults.set(false, forKey: GitMetadataWatcherSettings.disabledKey)

        let sourceManager = TabManager()
        guard let sourceWorkspace = sourceManager.selectedWorkspace else {
            XCTFail("Expected source workspace")
            return
        }

        sourceWorkspace.gitBranch = SidebarGitBranchState(branch: "feature/restored", isDirty: true)
        let snapshot = sourceManager.sessionSnapshot(includeScrollback: false)

        defaults.set(true, forKey: GitMetadataWatcherSettings.disabledKey)

        let restoredManager = TabManager()
        restoredManager.restoreSessionSnapshot(snapshot)

        XCTAssertTrue(
            waitForCondition {
                restoredManager.selectedWorkspace?.gitBranch == nil
            }
        )
    }

    func testRestoreSessionSnapshotClearsPanelGitBranchesWhenWorkspaceWatcherDisabled() {
        let sourceManager = TabManager()
        guard let sourceWorkspace = sourceManager.selectedWorkspace,
              let panelId = sourceWorkspace.focusedPanelId else {
            XCTFail("Expected source workspace with focused panel")
            return
        }

        sourceWorkspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/restored-disabled",
            isDirty: true
        )
        sourceWorkspace.gitMetadataWatcherDisabled = true

        let snapshot = sourceManager.sessionSnapshot(includeScrollback: false)
        let restoredManager = TabManager()
        restoredManager.restoreSessionSnapshot(snapshot)

        XCTAssertTrue(
            waitForCondition {
                guard let restoredWorkspace = restoredManager.selectedWorkspace else {
                    return false
                }
                return restoredWorkspace.gitMetadataWatcherDisabled
                    && restoredWorkspace.gitBranch == nil
                    && restoredWorkspace.panelGitBranches.isEmpty
                    && restoredWorkspace.sidebarGitBranchesInDisplayOrder().isEmpty
            }
        )
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
        wait(for: [expectation], timeout: 1.0)
    }
}
