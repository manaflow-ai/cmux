import XCTest
import Darwin

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

private func writeMinimalGitRepository(at repoURL: URL, indexData: Data = Data()) throws {
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
    try indexData.write(to: gitURL.appendingPathComponent("index"))
    try """
    [remote "origin"]
        url = https://github.com/manaflow-ai/cmux.git
    """.write(
        to: gitURL.appendingPathComponent("config"),
        atomically: true,
        encoding: .utf8
    )
}

private func writeEmptyGitIndex(at repoURL: URL, signatureByte: UInt8) throws {
    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(2, to: &data)
    appendBigEndianUInt32(0, to: &data)
    data.append(Data(repeating: signatureByte, count: 20))
    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

private func writeGitIndexVersion2Entry(
    at repoURL: URL,
    trackedPath: String,
    mode: UInt32,
    size: UInt32,
    signatureByte: UInt8
) throws {
    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(2, to: &data)
    appendBigEndianUInt32(1, to: &data)

    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(mode, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(size, to: &data)
    data.append(Data(repeating: 0, count: 20))

    let pathBytes = Array(trackedPath.utf8)
    appendBigEndianUInt16(UInt16(min(pathBytes.count, 0x0fff)), to: &data)
    data.append(contentsOf: pathBytes)
    data.append(0)
    while data.count % 8 != 0 {
        data.append(0)
    }
    data.append(Data(repeating: signatureByte, count: 20))

    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

private func writeGitIndexVersion4(
    at repoURL: URL,
    trackedPath: String,
    signatureByte: UInt8
) throws {
    let fileURL = repoURL.appendingPathComponent(trackedPath)
    var statValue = stat()
    guard lstat(fileURL.path, &statValue) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
    }

    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(4, to: &data)
    appendBigEndianUInt32(1, to: &data)

    appendBigEndianUInt32(UInt32(clamping: statValue.st_ctimespec.tv_sec), to: &data)
    appendBigEndianUInt32(UInt32(clamping: statValue.st_ctimespec.tv_nsec), to: &data)
    appendBigEndianUInt32(UInt32(clamping: statValue.st_mtimespec.tv_sec), to: &data)
    appendBigEndianUInt32(UInt32(clamping: statValue.st_mtimespec.tv_nsec), to: &data)
    appendBigEndianUInt32(UInt32(clamping: statValue.st_dev), to: &data)
    appendBigEndianUInt32(UInt32(clamping: statValue.st_ino), to: &data)
    appendBigEndianUInt32(UInt32(clamping: statValue.st_mode), to: &data)
    appendBigEndianUInt32(UInt32(clamping: statValue.st_uid), to: &data)
    appendBigEndianUInt32(UInt32(clamping: statValue.st_gid), to: &data)
    appendBigEndianUInt32(UInt32(clamping: statValue.st_size), to: &data)
    data.append(Data(repeating: 0, count: 20))

    let pathBytes = Array(trackedPath.utf8)
    appendBigEndianUInt16(UInt16(min(pathBytes.count, 0x0fff)), to: &data)
    data.append(0)
    data.append(contentsOf: pathBytes)
    data.append(0)
    data.append(Data(repeating: signatureByte, count: 20))

    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

private func appendBigEndianUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendBigEndianUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
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

    func testBranchOnlyGitReportDoesNotClearExistingDirtyState() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "main",
            isDirty: true
        )
        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "main",
            isDirty: nil
        )

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "main")
        XCTAssertEqual(
            workspace.panelGitBranches[panelId]?.isDirty,
            true,
            "Branch-only shell reports must not clear dirty state computed by the sidebar watcher."
        )
    }

    func testBranchOnlyGitReportClearsDirtyStateWhenBranchChanges() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "feature/old",
            isDirty: true
        )
        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "feature/new",
            isDirty: nil
        )

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "feature/new")
        XCTAssertEqual(
            workspace.panelGitBranches[panelId]?.isDirty,
            false,
            "Branch-only shell reports for a new branch must not reuse the previous branch's dirty state."
        )
    }

    func testDisablingGitWatchClearsCachedPullRequestBadgesWhenPullRequestsAreShownByDefault() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let previousShowPullRequests = defaults.object(forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
            restoreUserDefault(previousShowPullRequests, key: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defaults.removeObject(forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        XCTAssertTrue(
            SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: defaults),
            "PR badges should be enabled by default so this covers the stale badge users see."
        )

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let url = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/2722"))

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "issue-2722-git-index-lock-poll",
            isDirty: false
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2722,
            label: "#2722",
            url: url,
            status: .open,
            branch: "issue-2722-git-index-lock-poll"
        )

        XCTAssertFalse(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [panelId]).isEmpty)

        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertNil(workspace.gitBranch)
        XCTAssertNil(workspace.pullRequest)
        XCTAssertTrue(workspace.panelGitBranches.isEmpty)
        XCTAssertTrue(workspace.panelPullRequests.isEmpty)
        XCTAssertEqual(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [panelId]), [])
    }

    func testReenablingGitWatchRestartsRefreshFromCurrentPanelDirectories() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-reenable-git-watch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )
        XCTAssertNil(workspace.panelGitBranches[panelId])

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
            },
            "Re-enabling git watch must restart probes from the panel's current directory."
        )
    }

    func testUnrelatedDefaultsChangeDoesNotRestartGitMetadataRefreshes() throws {
        let defaults = UserDefaults.standard
        let unrelatedDefaultsKey = "cmux.tests.unrelated-defaults-\(UUID().uuidString)"
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            defaults.removeObject(forKey: unrelatedDefaultsKey)
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let workingDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-unrelated-defaults-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workingDirectoryURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                manager.activeWorkspaceGitProbePanelIdsForTesting(workspaceId: workspace.id).isEmpty
            }
        )

        workspace.currentDirectory = workingDirectoryURL.path
        defaults.set(UUID().uuidString, forKey: unrelatedDefaultsKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertEqual(
            manager.activeWorkspaceGitProbePanelIdsForTesting(workspaceId: workspace.id),
            Set<UUID>(),
            "Unrelated UserDefaults writes must not restart sidebar git probes for every panel."
        )
        XCTAssertNil(workspace.panelGitBranches[panelId])
    }

    func testGitIndexVersionFourRefreshTracksIndexSignatureChanges() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-index-v4-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try "seed\n".write(
            to: repoURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try writeMinimalGitRepository(at: repoURL)
        try writeGitIndexVersion4(at: repoURL, trackedPath: "tracked.txt", signatureByte: 0x11)
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "The sidebar refresh path should parse Git index v4 entries as clean when file stats match."
        )

        try writeGitIndexVersion4(at: repoURL, trackedPath: "tracked.txt", signatureByte: 0x22)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Index v4 signature changes should keep staged/index-only changes visible as dirty."
        )
    }

    func testEmptyGitIndexRefreshTracksIndexSignatureChanges() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-empty-index-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try writeEmptyGitIndex(at: repoURL, signatureByte: 0x11)
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "A valid empty index should establish a clean signature baseline."
        )

        try writeEmptyGitIndex(at: repoURL, signatureByte: 0x22)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Empty-index signature changes should keep staged deletes visible as dirty."
        )
    }

    func testGitlinkIndexEntriesDoNotMakeSubmoduleReposPermanentlyDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-gitlink-index-\(UUID().uuidString)",
            isDirectory: true
        )
        let submoduleURL = repoURL.appendingPathComponent("vendor/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: submoduleURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try writeGitIndexVersion2Entry(
            at: repoURL,
            trackedPath: "vendor/lib",
            mode: 0o160000,
            size: 0,
            signatureByte: 0x33
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "Gitlink entries represent submodule commits and should not be compared to directory stats."
        )
    }
}

private func restoreUserDefault(_ value: Any?, key: String) {
    let defaults = UserDefaults.standard
    if let value {
        defaults.set(value, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
}
