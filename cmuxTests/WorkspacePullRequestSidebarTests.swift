import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class CommandRunnerInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

@MainActor
final class WorkspacePullRequestSidebarTests: XCTestCase {
    func testSidebarPullRequestsIgnoreStaleWorkspaceLevelCacheWithoutPanelState() throws {
        let workspace = Workspace(title: "Test")
        let panelId = UUID()
        let staleURL = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/1640"))

        workspace.pullRequest = SidebarPullRequestState(
            number: 1640,
            label: "PR",
            url: staleURL,
            status: .open,
            branch: "main"
        )
        workspace.gitBranch = SidebarGitBranchState(branch: "main", isDirty: false)

        XCTAssertEqual(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [panelId]), [])
    }

    func testSidebarPullRequestsFilterBranchMismatchPerPanel() throws {
        let workspace = Workspace(title: "Test")
        let panelId = UUID()
        let staleURL = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/1640"))

        workspace.panelGitBranches[panelId] = SidebarGitBranchState(branch: "main", isDirty: false)
        workspace.panelPullRequests[panelId] = SidebarPullRequestState(
            number: 1640,
            label: "PR",
            url: staleURL,
            status: .open,
            branch: "feature/old"
        )

        XCTAssertEqual(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [panelId]), [])
    }

    func testSidebarPullRequestsPreferBestStateAcrossPanels() throws {
        let workspace = Workspace(title: "Test")
        let firstPanelId = UUID()
        let secondPanelId = UUID()
        let url = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/1640"))

        workspace.panelGitBranches[firstPanelId] = SidebarGitBranchState(branch: "feature/work", isDirty: false)
        workspace.panelGitBranches[secondPanelId] = SidebarGitBranchState(branch: "feature/work", isDirty: false)
        workspace.panelPullRequests[firstPanelId] = SidebarPullRequestState(
            number: 1640,
            label: "PR",
            url: url,
            status: .open,
            branch: "feature/work",
            isStale: true
        )
        workspace.panelPullRequests[secondPanelId] = SidebarPullRequestState(
            number: 1640,
            label: "PR",
            url: url,
            status: .merged,
            branch: "feature/work"
        )

        XCTAssertEqual(
            workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [firstPanelId, secondPanelId]),
            [
                SidebarPullRequestState(
                    number: 1640,
                    label: "PR",
                    url: url,
                    status: .merged,
                    branch: "feature/work"
                )
            ]
        )
    }

    func testPullRequestRefreshRepositoryDiscoveryDoesNotBlockMainRunLoop() throws {
        let invocationCounter = CommandRunnerInvocationCounter()
        let commandDelay: TimeInterval = 0.03
        TabManager.commandRunnerForTesting = { _, executable, arguments, _ in
            if executable == "git", arguments == ["remote", "-v"] {
                invocationCounter.increment()
                Thread.sleep(forTimeInterval: commandDelay)
                return TabManager.CommandResult(
                    stdout: "origin\tssh://example.invalid/not-github.git (fetch)\n",
                    stderr: "",
                    exitStatus: 0,
                    timedOut: false,
                    executionError: nil
                )
            }
            return TabManager.CommandResult(
                stdout: "",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        defer {
            TabManager.commandRunnerForTesting = nil
        }

        let manager = TabManager()
        var seededPanels: [(workspaceId: UUID, panelId: UUID)] = []
        let workspaceCount = 45
        var workspaces = manager.tabs
        while workspaces.count < workspaceCount {
            workspaces.append(manager.addWorkspace(select: false, eagerLoadTerminal: false))
        }

        for (index, workspace) in workspaces.enumerated() {
            let panelId = try XCTUnwrap(workspace.focusedPanelId)
            workspace.updatePanelDirectory(
                panelId: panelId,
                directory: "/tmp/cmux-pr-refresh-main-thread-\(index)"
            )
            workspace.updatePanelGitBranch(
                panelId: panelId,
                branch: "issue-3033-\(index)",
                isDirty: false
            )
            seededPanels.append((workspace.id, panelId))
        }

        let monitorDuration: TimeInterval = 0.7
        let allowedMainThreadGap: TimeInterval = 0.25
        let finishedMonitoring = expectation(description: "main run loop remained responsive")
        let monitorStartedAt = Date()
        var lastTickAt = monitorStartedAt
        var maxTickGap: TimeInterval = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            let now = Date()
            maxTickGap = max(maxTickGap, now.timeIntervalSince(lastTickAt))
            lastTickAt = now
            if now.timeIntervalSince(monitorStartedAt) >= monitorDuration {
                timer.invalidate()
                finishedMonitoring.fulfill()
            }
        }

        let triggerPanel = try XCTUnwrap(seededPanels.first)
        manager.updateSurfaceShellActivity(
            tabId: triggerPanel.workspaceId,
            surfaceId: triggerPanel.panelId,
            state: .promptIdle
        )

        let result = XCTWaiter().wait(for: [finishedMonitoring], timeout: monitorDuration + 1.5)
        timer.invalidate()
        XCTAssertEqual(result, .completed)
        XCTAssertGreaterThan(invocationCounter.value, 0)
        XCTAssertLessThan(
            maxTickGap,
            allowedMainThreadGap,
            "Pull request refresh blocked the main run loop for \(maxTickGap) seconds"
        )
    }
}
