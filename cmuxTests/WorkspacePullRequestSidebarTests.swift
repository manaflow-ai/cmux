import XCTest
import Darwin
import CmuxFoundation

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A `CommandRunning` fake that routes each call through a closure, replacing the
/// former `TabManager.commandRunnerForTesting` static hook.
private struct StubCommandRunner: CommandRunning {
    let handler: @Sendable (String, String, [String], TimeInterval?) -> CommandResult
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        handler(directory, executable, arguments, timeout)
    }
}

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

/// Records whether any observation happened on the main thread. Used to assert
/// that off-main work (e.g. PR-refresh git commands) never executes on the main
/// thread, a deterministic signal that does not depend on wall-clock timing.
private final class MainThreadObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedObservedOnMainThread = false

    func recordCurrentThread() {
        let onMain = Thread.isMainThread
        lock.lock()
        if onMain {
            storedObservedOnMainThread = true
        }
        lock.unlock()
    }

    var observedOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedObservedOnMainThread
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

private final class LockTouchingGitRunner: CommandRunning, @unchecked Sendable {
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

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        guard executable == "git" else {
            return CommandResult(
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
            return CommandResult(
                stdout: "main\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        if arguments == ["status", "--porcelain", "-uno"] {
            return CommandResult(
                stdout: "",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        if arguments == ["remote", "-v"] {
            return CommandResult(
                stdout: "origin\thttps://github.com/manaflow-ai/cmux.git (fetch)\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        return CommandResult(
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

private func writeMinimalGitRepository(
    at repoURL: URL,
    headCommit: String = "0000000000000000000000000000000000000000",
    indexData: Data = Data()
) throws {
    let gitURL = repoURL.appendingPathComponent(".git", isDirectory: true)
    let refsURL = gitURL.appendingPathComponent("refs/heads", isDirectory: true)
    try FileManager.default.createDirectory(at: refsURL, withIntermediateDirectories: true)
    try "ref: refs/heads/main\n".write(
        to: gitURL.appendingPathComponent("HEAD"),
        atomically: true,
        encoding: .utf8
    )
    try "\(headCommit)\n".write(
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
    signatureByte: UInt8,
    objectIDBytes: [UInt8] = Array(repeating: 0, count: 20)
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
    data.append(contentsOf: objectIDBytes.prefix(20))
    if objectIDBytes.count < 20 {
        data.append(Data(repeating: 0, count: 20 - objectIDBytes.count))
    }

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

private func gitObjectIDBytes(_ hex: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        bytes.append(UInt8(hex[index..<nextIndex], radix: 16) ?? 0)
        index = nextIndex
    }
    return bytes
}

private func writeGitIndexVersion3SkipWorktreeEntry(
    at repoURL: URL,
    trackedPath: String,
    signatureByte: UInt8
) throws {
    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(3, to: &data)
    appendBigEndianUInt32(1, to: &data)

    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0o100644, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    data.append(Data(repeating: 0, count: 20))

    let pathBytes = Array(trackedPath.utf8)
    appendBigEndianUInt16(UInt16(min(pathBytes.count, 0x0fff)) | 0x4000, to: &data)
    appendBigEndianUInt16(0x4000, to: &data)
    data.append(contentsOf: pathBytes)
    data.append(0)
    while data.count % 8 != 0 {
        data.append(0)
    }
    data.append(Data(repeating: signatureByte, count: 20))

    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

private func writeGitIndexVersion2EntryFromStat(
    at repoURL: URL,
    trackedPath: String,
    indexMode: UInt32,
    signatureByte: UInt8,
    objectIDBytes: [UInt8] = Array(repeating: 0, count: 20),
    baseFlags: UInt16 = 0
) throws {
    let fileURL = repoURL.appendingPathComponent(trackedPath)
    var statValue = stat()
    guard lstat(fileURL.path, &statValue) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
    }

    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(2, to: &data)
    appendBigEndianUInt32(1, to: &data)

    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ctimespec.tv_sec), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ctimespec.tv_nsec), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mtimespec.tv_sec), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mtimespec.tv_nsec), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_dev), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ino), to: &data)
    appendBigEndianUInt32(indexMode, to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_uid), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_gid), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_size), to: &data)
    data.append(contentsOf: objectIDBytes.prefix(20))
    if objectIDBytes.count < 20 {
        data.append(Data(repeating: 0, count: 20 - objectIDBytes.count))
    }

    let pathBytes = Array(trackedPath.utf8)
    appendBigEndianUInt16(UInt16(min(pathBytes.count, 0x0fff)) | baseFlags, to: &data)
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
    try writeGitIndexVersion4(at: repoURL, trackedPaths: [trackedPath], signatureByte: signatureByte)
}

private func writeGitIndexVersion4(
    at repoURL: URL,
    trackedPaths: [String],
    signatureByte: UInt8
) throws {
    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(4, to: &data)
    appendBigEndianUInt32(UInt32(trackedPaths.count), to: &data)

    var previousPathBytes: [UInt8] = []
    for trackedPath in trackedPaths.sorted() {
        let fileURL = repoURL.appendingPathComponent(trackedPath)
        var statValue = stat()
        guard lstat(fileURL.path, &statValue) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }

        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ctimespec.tv_sec), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ctimespec.tv_nsec), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mtimespec.tv_sec), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mtimespec.tv_nsec), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_dev), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ino), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mode), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_uid), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_gid), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_size), to: &data)
        data.append(Data(repeating: 0, count: 20))

        let pathBytes = Array(trackedPath.utf8)
        appendBigEndianUInt16(UInt16(min(pathBytes.count, 0x0fff)), to: &data)
        let commonPrefixLength = zip(previousPathBytes, pathBytes).prefix { pair in
            pair.0 == pair.1
        }.count
        let stripLength = previousPathBytes.count - commonPrefixLength
        data.append(contentsOf: gitIndexV4PathStripLengthBytes(stripLength))
        data.append(contentsOf: pathBytes.dropFirst(commonPrefixLength))
        data.append(0)
        previousPathBytes = pathBytes
    }

    data.append(Data(repeating: signatureByte, count: 20))

    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

private func gitIndexV4PathStripLengthBytes(_ value: Int) -> [UInt8] {
    precondition(value >= 0)
    var remaining = value
    var bytes = [UInt8(remaining & 0x7f)]
    remaining >>= 7
    while remaining != 0 {
        remaining -= 1
        bytes.append(0x80 | UInt8(remaining & 0x7f))
        remaining >>= 7
    }
    return Array(bytes.reversed())
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

private func gitIndexUInt32Field<T: BinaryInteger>(_ value: T) -> UInt32 {
    UInt32(truncatingIfNeeded: UInt64(truncatingIfNeeded: value))
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
        let gitThreadObservation = MainThreadObservationBox()
        let commandDelay: TimeInterval = 0.03
        let commandRunner = StubCommandRunner { _, executable, arguments, _ in
            if executable == "git", arguments == ["remote", "-v"] {
                invocationCounter.increment()
                gitThreadObservation.recordCurrentThread()
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
        // Generous bound far above macOS CI scheduling noise (GC, unrelated test
        // work, run-loop jitter can stall the main thread well past a few hundred
        // ms on a loaded shared runner). This catches gross main-thread blocking
        // without failing on routine host jitter; the deterministic non-main-thread
        // assertion below is the real regression signal.
        let allowedMainThreadGap: TimeInterval = 2.0
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
        // Deterministic regression signal: the blocking git work must have run off
        // the main thread. This does not depend on wall-clock timing, so it cannot
        // flake from host scheduling noise.
        XCTAssertFalse(
            gitThreadObservation.observedOnMainThread,
            "Pull request refresh ran its blocking git command on the main thread"
        )
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

    func testTabScopedGitBranchUnknownStatusClearsDirtyWhenBranchChanges() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        workspace.gitBranch = SidebarGitBranchState(branch: "main", isDirty: true)

        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
        }

        let response = TerminalController.shared.handleSocketLine(
            "report_git_branch feature/new --status=unknown --tab=\(workspace.id.uuidString)"
        )

        XCTAssertEqual(response, "OK")
        XCTAssertEqual(workspace.gitBranch?.branch, "feature/new")
        XCTAssertEqual(
            workspace.gitBranch?.isDirty,
            false,
            "Tab-scoped branch-only reports for a new branch must not reuse the previous branch's dirty state."
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

        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
        }
        let response = TerminalController.shared.handleSocketLine(
            "report_pr 2722 https://github.com/manaflow-ai/cmux/pull/2722 --label=PR --state=open --branch=issue-2722-git-index-lock-poll --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        XCTAssertEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertTrue(
            workspace.panelPullRequests.isEmpty,
            "Stale shell report_pr messages must not repopulate PR badges while sidebar.watchGitStatus is disabled."
        )
        XCTAssertEqual(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [panelId]), [])

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "issue-2722-git-index-lock-poll",
            isDirty: false
        )
        XCTAssertFalse(workspace.panelGitBranches.isEmpty)

        let branchResponse = TerminalController.shared.handleSocketLine(
            "report_git_branch main --status=unknown --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        XCTAssertEqual(branchResponse, "OK")
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertTrue(
            workspace.panelGitBranches.isEmpty,
            "Stale shell report_git_branch messages must not repopulate branch badges while sidebar.watchGitStatus is disabled."
        )
    }

    func testHiddenPullRequestsDoNotSchedulePullRequestPollingFromBranchReports() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let previousShowPullRequests = defaults.object(forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
            restoreUserDefault(previousShowPullRequests, key: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "issue-2746-rate-limit",
            isDirty: false
        )

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "issue-2746-rate-limit")
        XCTAssertTrue(
            manager.workspacePullRequestTrackedPanelIdsForTesting(workspaceId: workspace.id).isEmpty,
            "Branch reports should keep branch metadata but must not arm any PR polling while sidebar.showPullRequests is false."
        )
    }

    func testHidingPullRequestSidebarPreservesPassiveReportsWithoutPolling() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let previousShowPullRequests = defaults.object(forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
            restoreUserDefault(previousShowPullRequests, key: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let url = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/2746"))

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "issue-2746-rate-limit",
            isDirty: false
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2746,
            label: "PR",
            url: url,
            status: .open,
            branch: "issue-2746-rate-limit"
        )
        XCTAssertNotNil(workspace.panelPullRequests[panelId])

        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "issue-2746-rate-limit")
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.number, 2746)
        XCTAssertEqual(workspace.pullRequest?.number, 2746)
        XCTAssertTrue(
            manager.workspacePullRequestTrackedPanelIdsForTesting(workspaceId: workspace.id).isEmpty,
            "Hiding PR rows should stop PR polling without discarding passive metadata."
        )

        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
        }
        let response = TerminalController.shared.handleSocketLine(
            "report_pr 2747 https://github.com/manaflow-ai/cmux/pull/2747 --label=PR --state=open --branch=issue-2746-rate-limit --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        XCTAssertEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()
        XCTAssertEqual(
            workspace.panelPullRequests[panelId]?.number,
            2747,
            "Hidden PR rows should continue accepting passive reports."
        )

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "issue-2746-rate-limit")
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.number, 2747)
        XCTAssertEqual(
            manager.workspacePullRequestTrackedPanelIdsForTesting(workspaceId: workspace.id),
            Set([panelId]),
            "Showing PR rows again should restart polling without losing passive metadata."
        )
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

    func testDetachedHeadRepositoryKeepsGitMetadataWatcherForLaterCheckout() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-detached-head-watch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try "0000000000000000000000000000000000000000\n".write(
            to: repoURL.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
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
                manager.trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: workspace.id).contains(panelId)
            },
            "Detached HEAD repos must stay tracked so later .git/HEAD updates refresh sidebar metadata."
        )
        XCTAssertNil(workspace.panelGitBranches[panelId])

        try "ref: refs/heads/main\n".write(
            to: repoURL.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
            },
            "Refreshing a tracked detached-HEAD repo after checkout must restore branch metadata."
        )
    }

    // Removed testBackgroundGitMetadataFallbackContinuesWithinOversizedWorkspace:
    // it asserted the branch's batched/cursor git-metadata polling
    // (backgroundGitMetadataPollBatchLimit), which main's refactor replaced with
    // a full sweep (refreshTrackedWorkspaceGitMetadata now returns Void). Git
    // metadata behavior is covered by CmuxGit/GitMetadataServiceTests; restoring
    // the batched throttle + this test is a deliberate follow-up if mobile-host
    // scale needs it.

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

    func testCleanIndexSignatureRebaselinesWhenIndexRewriteKeepsTrackedContentClean() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-stash-clean-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "seed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        let cleanObjectID = Array(repeating: UInt8(0x11), count: 20)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x11,
            objectIDBytes: cleanObjectID
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
            "A matching index and worktree should establish a clean baseline."
        )

        try "changed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "A worktree edit should make the sidebar dirty before a simulated stash."
        )

        try "seed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x22,
            objectIDBytes: cleanObjectID
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "A stash-like index rewrite with unchanged tracked content should become the new clean baseline."
        )
    }

    func testIndexContentChangeAfterWorktreeDirtyRemainsDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-staged-after-dirty-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "seed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x11,
            objectIDBytes: Array(repeating: UInt8(0x11), count: 20)
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
            "A matching index and worktree should establish a clean baseline."
        )

        try "changed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "A worktree edit should make the sidebar dirty before staging."
        )

        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x22,
            objectIDBytes: Array(repeating: UInt8(0x22), count: 20)
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Staging changed content should remain dirty even when the index stat cache matches the worktree."
        )
    }

    func testAssumeUnchangedGitIndexEntriesDoNotMarkModifiedWorktreeDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-assume-unchanged-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "seed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        let cleanObjectID = Array(repeating: UInt8(0x11), count: 20)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x11,
            objectIDBytes: cleanObjectID
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
            "A matching index and worktree should establish a clean baseline."
        )

        let assumeUnchangedFlag: UInt16 = 0x8000
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x22,
            objectIDBytes: cleanObjectID,
            baseFlags: assumeUnchangedFlag
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "Setting assume-unchanged should rebaseline as clean because tracked index content did not change."
        )

        try "changed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "Assume-unchanged index entries should not stat modified worktree files."
        )
    }

    func testGitIndexVersionFourRefreshDecodesMultiByteStripLengths() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-index-v4-varint-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        let longTrackedPath = [
            "a",
            String(repeating: "a", count: 120),
            String(repeating: "b", count: 120),
            "tracked0.txt"
        ].joined(separator: "/")
        XCTAssertEqual(longTrackedPath.utf8.count, 256)
        XCTAssertEqual(gitIndexV4PathStripLengthBytes(256), [0x81, 0x00])

        let longTrackedFileURL = repoURL.appendingPathComponent(longTrackedPath)
        try FileManager.default.createDirectory(
            at: longTrackedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "alpha\n".write(to: longTrackedFileURL, atomically: true, encoding: .utf8)
        try "beta\n".write(to: repoURL.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try writeMinimalGitRepository(at: repoURL)
        try writeGitIndexVersion4(
            at: repoURL,
            trackedPaths: [longTrackedPath, "b.txt"],
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
            "Index v4 multi-byte path strip lengths should decode to the tracked path instead of marking the repo dirty."
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

    func testSkipWorktreeGitIndexEntriesDoNotMarkSparseCheckoutDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-sparse-index-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try writeGitIndexVersion3SkipWorktreeEntry(
            at: repoURL,
            trackedPath: "sparse-only.txt",
            signatureByte: 0x44
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("sparse-only.txt").path),
            "The sparse-checkout entry should be absent from the worktree."
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
            "Skip-worktree index entries should be ignored by dirty detection when sparse files are absent."
        )
    }

    func testMissingGitlinkSubmoduleMarksSidebarDirty() throws {
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
                    && workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Missing or uninitialized gitlink submodules should make the parent sidebar dirty."
        )
    }

    func testGitlinkIndexEntriesTrackSubmoduleCommitChanges() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-gitlink-commit-\(UUID().uuidString)",
            isDirectory: true
        )
        let submoduleURL = repoURL.appendingPathComponent("vendor/lib", isDirectory: true)
        let indexedCommit = String(repeating: "1", count: 40)
        let updatedCommit = String(repeating: "2", count: 40)
        try FileManager.default.createDirectory(at: submoduleURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try writeMinimalGitRepository(at: submoduleURL, headCommit: indexedCommit)
        try writeGitIndexVersion2Entry(
            at: repoURL,
            trackedPath: "vendor/lib",
            mode: 0o160000,
            size: 0,
            signatureByte: 0x66,
            objectIDBytes: gitObjectIDBytes(indexedCommit)
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
            "A gitlink whose worktree HEAD matches the indexed submodule commit should be clean."
        )

        try "\(updatedCommit)\n".write(
            to: submoduleURL.appendingPathComponent(".git/refs/heads/main"),
            atomically: true,
            encoding: .utf8
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Submodule HEAD changes should make the parent sidebar dirty without spawning git."
        )
    }

    // Git-metadata resolution, watched-path derivation (including submodule
    // gitlinks), and remote-slug parsing now live in the CmuxGit package and are
    // unit-tested there (CmuxGitTests: GitMetadataServiceTests / GitConfigIncludeTests).
    // The watcher's leading-edge coalescing is verified in CmuxFileWatch's package
    // tests (RecursivePathWatcherTests) with an injected clock and no real waiting.
    // The tests below keep exercising the end-to-end refresh path through TabManager.

    func testModeOnlyTrackedChangesMarkSidebarDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-mode-only-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let scriptURL = repoURL.appendingPathComponent("script.sh")
        try "echo ok\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(scriptURL.path, 0o644), 0)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "script.sh",
            indexMode: 0o100644,
            signatureByte: 0x44
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
            "A tracked file with matching size, mtime, and mode should establish a clean baseline."
        )

        XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Mode-only changes should be visible as dirty without invoking git."
        )
    }

    func testLargeTrackedFileSizeMatchesGitIndexTruncation() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-large-file-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let largeURL = repoURL.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: largeURL.path, contents: Data(), attributes: nil))
        let handle = try FileHandle(forWritingTo: largeURL)
        try handle.truncate(atOffset: UInt64(UInt32.max) + 257)
        try handle.close()
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "large.bin",
            indexMode: 0o100644,
            signatureByte: 0x55
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
            "Git index stores file size as a 32-bit field; matching large sparse files should compare with truncation, not clamping."
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
