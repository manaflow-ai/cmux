import XCTest
import Darwin
import CmuxProcess

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Refresh repository discovery and index lock behavior
extension WorkspacePullRequestSidebarTests {
    func testPullRequestRefreshRepositoryDiscoveryDoesNotBlockMainRunLoop() throws {
        let invocationCounter = CommandRunnerInvocationCounter()
        let commandDelay: TimeInterval = 0.03
        let commandRunner = StubCommandRunner { _, executable, arguments, _ in
            if executable == "git", arguments == ["remote", "-v"] {
                invocationCounter.increment()
                Thread.sleep(forTimeInterval: commandDelay)
                return CommandResult(
                    stdout: "origin\tssh://example.invalid/not-github.git (fetch)\n",
                    stderr: "",
                    exitStatus: 0,
                    timedOut: false,
                    executionError: nil
                )
            }
            return CommandResult(
                stdout: "",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }

        let manager = TabManager(commandRunner: commandRunner)
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

    func testNoIndexLockTouchDuringSidebarGitMetadataRefreshWindow() throws {
        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-index-lock-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        let indexLockPath = repoURL.appendingPathComponent(".git/index.lock").path
        let gitRunner = LockTouchingGitRunner(indexLockPath: indexLockPath)

        let observer = IndexLockObserver(path: indexLockPath)
        observer.start(pollInterval: 0.1)
        defer {
            observer.stop()
        }

        let manager = TabManager(commandRunner: gitRunner)
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )

        let completedRefreshWindow = expectation(description: "sidebar git metadata refresh window completed")
        let refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            manager.refreshTrackedWorkspaceGitMetadataForTesting()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90.5) {
            refreshTimer.invalidate()
            completedRefreshWindow.fulfill()
        }

        let result = XCTWaiter().wait(for: [completedRefreshWindow], timeout: 92)
        refreshTimer.invalidate()
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(
            gitRunner.invocationCount,
            0,
            "Sidebar git metadata refresh must not spawn git commands."
        )
        XCTAssertEqual(
            workspace.panelGitBranches[panelId]?.branch,
            "main",
            "The test must exercise the sidebar git-refresh path."
        )
        XCTAssertEqual(
            observer.observationCount,
            0,
            "Sidebar git metadata refresh must never create or observe .git/index.lock during a 90s window."
        )
    }

}
