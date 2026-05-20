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

private final class IndexLockObserver: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "com.cmux.tests.index-lock-observer", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var storedObservationCount = 0

    init(path: String) {
        self.path = path
    }

    func start(pollInterval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.path) {
                self.lock.lock()
                self.storedObservationCount += 1
                self.lock.unlock()
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    var observationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedObservationCount
    }
}

private final class LockTouchingGitRunner: @unchecked Sendable {
    private let indexLockPath: String
    private let lock = NSLock()
    private var storedInvocationCount = 0

    init(indexLockPath: String) {
        self.indexLockPath = indexLockPath
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedInvocationCount
    }

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) -> TabManager.CommandResult? {
        guard executable == "git" else {
            return TabManager.CommandResult(
                stdout: "",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }

        lock.lock()
        storedInvocationCount += 1
        lock.unlock()

        FileManager.default.createFile(atPath: indexLockPath, contents: Data(), attributes: nil)
        Thread.sleep(forTimeInterval: 0.15)
        try? FileManager.default.removeItem(atPath: indexLockPath)

        if arguments == ["branch", "--show-current"] {
            return TabManager.CommandResult(
                stdout: "main\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        if arguments == ["status", "--porcelain", "-uno"] {
            return TabManager.CommandResult(
                stdout: "",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        if arguments == ["remote", "-v"] {
            return TabManager.CommandResult(
                stdout: "origin\thttps://github.com/manaflow-ai/cmux.git (fetch)\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        return TabManager.CommandResult(
            stdout: "",
            stderr: "unexpected git arguments: \(arguments.joined(separator: " "))",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        )
    }
}

private func writeMinimalGitRepository(at repoURL: URL) throws {
    let gitURL = repoURL.appendingPathComponent(".git", isDirectory: true)
    let refsURL = gitURL.appendingPathComponent("refs/heads", isDirectory: true)
    try FileManager.default.createDirectory(at: refsURL, withIntermediateDirectories: true)
    try "ref: refs/heads/main\n".write(
        to: gitURL.appendingPathComponent("HEAD"),
        atomically: true,
        encoding: .utf8
    )
    try "0000000000000000000000000000000000000000\n".write(
        to: refsURL.appendingPathComponent("main"),
        atomically: true,
        encoding: .utf8
    )
    try Data().write(to: gitURL.appendingPathComponent("index"))
    try """
    [remote "origin"]
        url = https://github.com/manaflow-ai/cmux.git
    """.write(
        to: gitURL.appendingPathComponent("config"),
        atomically: true,
        encoding: .utf8
    )
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
        TabManager.commandRunnerForTesting = gitRunner.run(directory:executable:arguments:timeout:)
        defer {
            TabManager.commandRunnerForTesting = nil
        }

        let observer = IndexLockObserver(path: indexLockPath)
        observer.start(pollInterval: 0.1)
        defer {
            observer.stop()
        }

        let manager = TabManager()
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
