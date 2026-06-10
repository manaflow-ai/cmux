import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import CmuxGit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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

private func restoreUserDefaultForTabManagerTests(_ value: Any?, key: String) {
    let defaults = UserDefaults.standard
    if let value {
        defaults.set(value, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
}

private actor BlockingWorkspaceGitMetadataReader: WorkspaceGitMetadataReading {
    private let metadata: GitWorkspaceMetadata
    private var callCount = 0
    private var maxActiveCallCount = 0
    private var activeCallCount = 0
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(metadata: GitWorkspaceMetadata) {
        self.metadata = metadata
    }

    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        callCount += 1
        activeCallCount += 1
        maxActiveCallCount = max(maxActiveCallCount, activeCallCount)
        resumeSatisfiedCallCountWaiters()
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        activeCallCount -= 1
        return metadata
    }

    func waitForCallCount(_ expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((expected, continuation))
        }
    }

    func releaseAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    var observedCallCount: Int {
        callCount
    }

    var observedMaxActiveCallCount: Int {
        maxActiveCallCount
    }

    private func resumeSatisfiedCallCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callCountWaiters {
            if callCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callCountWaiters = remaining
    }
}

private struct ProcessRunResult {
    let status: Int32
    let stdout: String
    let stderr: String
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

    func testFocusedPanelTitleRefreshesAutoWorkspaceTitleInSplitWorkspace() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)

        XCTAssertTrue(workspace.updatePanelTitle(panelId: focusedPanelId, title: "Waiting - grok"))
        XCTAssertEqual(workspace.title, "Waiting - grok")

        let splitPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal, focus: false)
        )
        XCTAssertEqual(workspace.focusedPanelId, focusedPanelId)
        XCTAssertEqual(workspace.panels.count, 2)

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Processing Simple Addition Query - grok"
            ]
        )

        XCTAssertTrue(
            waitForCondition(timeout: 1.0) {
                workspace.panelTitles[focusedPanelId] == "Processing Simple Addition Query - grok" &&
                    workspace.title == "Processing Simple Addition Query - grok"
            }
        )
        XCTAssertNil(workspace.customTitle)
        XCTAssertNotEqual(workspace.panelTitles[splitPanel.id], Optional(workspace.title))
    }
}

@MainActor
final class TabManagerPullRequestProbeTests: XCTestCase {

    // Pure pull-request selection/policy tests moved to the CmuxGit package
    // (CmuxGitTests.PullRequestProbeServiceTests) with the extraction.

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

    func testSameDirectoryInitialGitMetadataProbesShareOneSnapshotRead() async throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefaultForTabManagerTests(
                previousWatchGitStatus,
                key: SidebarWorkspaceDetailDefaults.watchGitStatusKey
            )
        }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-git-coalesced-probes-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let reader = BlockingWorkspaceGitMetadataReader(
            metadata: GitWorkspaceMetadata(
                isRepository: true,
                branch: "main",
                isDirty: false,
                indexSignature: "index",
                indexContentSignature: "content",
                headSignature: "head"
            )
        )
        defer {
            Task {
                await reader.releaseAll()
            }
        }

        let manager = TabManager(workspaceGitMetadataReader: reader)
        guard let workspace = manager.selectedWorkspace,
              let mainPanelId = workspace.focusedPanelId,
              let paneId = workspace.bonsplitController.focusedPaneId,
              let splitPanel = workspace.newTerminalSplit(from: mainPanelId, orientation: .horizontal, focus: false),
              let tabPanel = workspace.newTerminalSurface(inPane: paneId) else {
            XCTFail("Expected selected workspace with three terminal panels")
            return
        }

        let panelIds = [mainPanelId, splitPanel.id, tabPanel.id]
        for panelId in panelIds {
            manager.updateSurfaceDirectory(
                tabId: workspace.id,
                surfaceId: panelId,
                directory: directoryURL.path
            )
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        let firstRead = expectation(description: "first git snapshot read started")
        Task {
            await reader.waitForCallCount(1)
            firstRead.fulfill()
        }
        await fulfillment(of: [firstRead], timeout: 1.0)

        let uncoalescedSecondRead = expectation(description: "uncoalesced second git snapshot read")
        uncoalescedSecondRead.isInverted = true
        Task {
            await reader.waitForCallCount(2)
            uncoalescedSecondRead.fulfill()
        }
        await fulfillment(of: [uncoalescedSecondRead], timeout: 0.2)

        let observedCallCount = await reader.observedCallCount
        let observedMaxActiveCallCount = await reader.observedMaxActiveCallCount
        XCTAssertEqual(observedCallCount, 1)
        XCTAssertEqual(observedMaxActiveCallCount, 1)

        await reader.releaseAll()
        XCTAssertTrue(
            waitForCondition {
                panelIds.allSatisfy { workspace.panelGitBranches[$0]?.branch == "main" }
            },
            "One same-directory snapshot should update every queued panel."
        )
        let finalObservedCallCount = await reader.observedCallCount
        XCTAssertEqual(finalObservedCallCount, 1)
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

    // testResolvedCommandPathFallsBackOutsideAppPATH moved to
    // CmuxProcessTests.resolvesCommandViaFallbackDirectoryOutsidePath when the
    // command runner was extracted into the CmuxProcess package.

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


