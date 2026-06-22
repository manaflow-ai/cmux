import XCTest
import CmuxCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import CmuxGit
import CmuxSidebarGit
import CmuxSidebar
import CmuxTerminal
import CmuxSettings

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

private func splitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
    switch node {
    case .pane:
        return []
    case .split(let split):
        return [split] + splitNodes(in: split.first) + splitNodes(in: split.second)
    }
}

@discardableResult
private func assertProportionalEqualizedSplitTree(
    _ node: ExternalTreeNode,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Int {
    switch node {
    case .pane:
        return 1
    case .split(let split):
        let firstLeafCount = assertProportionalEqualizedSplitTree(split.first, file: file, line: line)
        let secondLeafCount = assertProportionalEqualizedSplitTree(split.second, file: file, line: line)
        let totalLeafCount = firstLeafCount + secondLeafCount
        XCTAssertEqual(
            split.dividerPosition,
            Double(firstLeafCount) / Double(totalLeafCount),
            accuracy: 0.000_1,
            file: file,
            line: line
        )
        return totalLeafCount
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

    func testChildExitOnLastRemotePanelKeepsWorkspaceDisconnected() throws {
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
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertNil(workspace.panels[remotePanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, remotePanelId)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    func testManualCloseOnLastRemotePanelKeepsWorkspaceDisconnected() throws {
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
                relayPort: 64017,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(remotePanelId))

        XCTAssertTrue(workspace.closePanel(remotePanelId, force: true))
        drainMainQueue()
        drainMainQueue()

        let replacement = try XCTUnwrap(workspace.focusedTerminalPanel)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertNil(workspace.panels[remotePanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(replacement.id, remotePanelId)
        XCTAssertNotNil(replacement.surface.initialCommand)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)

        let firstPlaceholderId = replacement.id
        XCTAssertTrue(workspace.closePanel(firstPlaceholderId, force: true))
        drainMainQueue()
        drainMainQueue()

        let secondReplacement = try XCTUnwrap(workspace.focusedTerminalPanel)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertNil(workspace.panels[firstPlaceholderId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(secondReplacement.id, firstPlaceholderId)
        XCTAssertNotNil(secondReplacement.surface.initialCommand)
    }

    func testChildExitOnLastPersistentRemotePanelKeepsExitedSurfaceVisibleAndClearsPTYState() throws {
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
                relayPort: 64017,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-child-exit-test"
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
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertNotNil(workspace.panels[remotePanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertEqual(workspace.focusedPanelId, remotePanelId)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(remotePanelId))
        XCTAssertNil(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == remotePanelId }?.terminal?.remotePTYSessionID
        )
    }

    func testPaneCloseOnLastRemotePanelKeepsWorkspaceDisconnected() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let remotePanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                transport: .websocket,
                destination: "vm:issue-4509",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "cmux remote websocket"
            ),
            autoConnect: false
        )

        guard let browserPanel = workspace.newBrowserSplit(
            from: remotePanelId,
            orientation: .horizontal,
            focus: false,
            creationPolicy: .restoration
        ),
              let remotePaneId = workspace.paneId(forPanelId: remotePanelId) else {
            XCTFail("Expected split browser and remote terminal panes")
            return
        }

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(remotePanelId))
        XCTAssertEqual(workspace.remoteConnectionState, .connected)

        XCTAssertTrue(workspace.bonsplitController.closePane(remotePaneId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertNil(workspace.panels[remotePanelId])
        XCTAssertNotNil(workspace.panels[browserPanel.id])
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    func testChildExitAfterPersistentAttachEndKeepsExitedSurfaceVisible() throws {
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
                relayPort: 64020,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-attach-end-test.sock",
                terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-child-exit-after-attach-end"
            ),
            autoConnect: false
        )
        let sessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: remotePanelId)

        let outcome = workspace.markRemotePTYAttachEnded(surfaceId: remotePanelId, sessionID: sessionID)

        XCTAssertTrue(outcome.clearedRemotePTYSession)
        XCTAssertTrue(outcome.untrackedRemoteTerminal)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(remotePanelId))
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
        XCTAssertTrue(workspace.shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(remotePanelId))

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: remotePanelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertNotNil(workspace.panels[remotePanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertEqual(workspace.focusedPanelId, remotePanelId)
        XCTAssertFalse(workspace.shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(remotePanelId))
        XCTAssertNil(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == remotePanelId }?.terminal?.remotePTYSessionID
        )
    }

    func testChildExitOnSplitPersistentRemotePanelKeepsExitedSurfaceVisibleAndClearsOnlyThatPTYState() throws {
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
                relayPort: 64018,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-split-test.sock",
                terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-child-exit-split-test"
            ),
            autoConnect: false
        )
        let siblingPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: remotePanelId, orientation: .horizontal, focus: false)
        )

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(remotePanelId))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(siblingPanel.id))

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: remotePanelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertNotNil(workspace.panels[remotePanelId])
        XCTAssertNotNil(workspace.panels[siblingPanel.id])
        XCTAssertEqual(workspace.panels.count, 2)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(remotePanelId))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(siblingPanel.id))
        XCTAssertNil(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == remotePanelId }?.terminal?.remotePTYSessionID
        )
        XCTAssertNotNil(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == siblingPanel.id }?.terminal?.remotePTYSessionID
        )
    }

    func testFocusedRemoteChildExitWithMultipleTerminalsDisconnectsWorkspace() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        guard let splitPanel = workspace.newTerminalSplit(
            from: initialPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected split terminal panel")
            return
        }
        XCTAssertEqual(workspace.focusedPanelId, initialPanelId)

        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                transport: .websocket,
                destination: "vm:issue-4509-untracked",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "cmux remote websocket"
            ),
            autoConnect: false
        )

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(initialPanelId))
        XCTAssertFalse(workspace.isRemoteTerminalSurface(splitPanel.id))
        XCTAssertEqual(workspace.remoteConnectionState, .connected)

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: initialPanelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertNotNil(workspace.panels[splitPanel.id])
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    func testChildExitAfterRemoteSessionEndKeepsWorkspaceDisconnected() throws {
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

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: remotePanelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(manager.tabs.first?.id, workspace.id)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
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

    func testChildExitWindowCloseRequestsNoClosedWindowHistory() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        var closeRequest: (tabId: UUID, recordHistory: Bool)?
        appDelegate.closeMainWindowContainingTabIdObserverForTesting = { tabId, recordHistory in
            closeRequest = (tabId, recordHistory)
        }
        defer {
            appDelegate.closeMainWindowContainingTabIdObserverForTesting = nil
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        appDelegate.recordClosedWindowHistoryForTesting(windowId: windowId)
        XCTAssertTrue(ClosedItemHistoryStore.shared.canReopen)
        ClosedItemHistoryStore.shared.removeAll()

        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panelId)
        drainMainQueue()

        XCTAssertEqual(closeRequest?.tabId, workspace.id)
        XCTAssertEqual(closeRequest?.recordHistory, false)

        appDelegate.suppressClosedWindowHistoryForTesting(windowId: windowId)
        appDelegate.recordClosedWindowHistoryForTesting(windowId: windowId)
        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)
        XCTAssertFalse(appDelegate.isClosedWindowHistorySuppressedForTesting(windowId: windowId))
    }

    func testSessionSnapshotKeepsWindowWithNoRestorableWorkspaces() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "wss://remote.example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            AppDelegate.shared = originalAppDelegate
        }

        XCTAssertFalse(workspace.isRestorableInSessionSnapshot)
        let snapshot = try XCTUnwrap(appDelegate.sessionSnapshotForTesting())
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertTrue(snapshot.windows[0].tabManager.workspaces.isEmpty)
    }

    func testClosedWindowHistorySkipsWindowWithNoRestorableWorkspaces() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "wss://remote.example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        appDelegate.recordClosedWindowHistoryForTesting(windowId: windowId)

        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)
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

    func testGhosttyDidSetTitleEnqueuesTitleUpdateForOwnedTab() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Owned Title"
            ]
        )

        let enqueued = waitForCondition(timeout: 1.0, pollInterval: 0.002) {
            manager.pendingPanelTitleUpdateCountForTesting() > 0
        }
        XCTAssertTrue(enqueued, "owning manager should enqueue title update for its own tab")
    }

    func testGhosttyDidSetTitleDoesNotEnqueueForTabOwnedByAnotherManager() throws {
        let owningManager = TabManager()
        let foreignManager = TabManager()
        let workspace = try XCTUnwrap(owningManager.selectedWorkspace)
        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Owner Only"
            ]
        )

        // .ghosttyDidSetTitle is observed with object: nil, so every alive
        // TabManager receives it. Waiting for the owning manager to enqueue
        // proves the notification has been delivered to both observers.
        let delivered = waitForCondition(timeout: 1.0, pollInterval: 0.002) {
            owningManager.pendingPanelTitleUpdateCountForTesting() > 0
        }
        XCTAssertTrue(delivered, "owning manager should enqueue title update for its own tab")

        // Checked before the 30 Hz coalescer fires, so the non-owning manager's
        // pending queue must still be empty if the boundary guard held.
        // Before the fix this was 1 (2x fan-out across managers — see #6551).
        XCTAssertEqual(
            foreignManager.pendingPanelTitleUpdateCountForTesting(),
            0,
            "non-owning manager must not enqueue title updates for foreign tabs"
        )
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

    func testCloseWorkspacesWithConfirmationHonorsWarnBeforeClosingTabDisabled() {
        let defaults = UserDefaults.standard
        let originalWarnBeforeClosingTab = defaults.object(forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey)
        defaults.set(false, forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey)
        defer {
            if let originalWarnBeforeClosingTab {
                defaults.set(originalWarnBeforeClosingTab, forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey)
            }
        }

        let manager = TabManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")
        manager.setCustomTitle(tabId: third.id, title: "Gamma")

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeWorkspacesWithConfirmation([manager.tabs[0].id, second.id], allowPinned: true)

        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(manager.tabs.map(\.title), ["Gamma"])
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

    func testCloseWorkspaceEnqueuesTerminalRuntimeTeardownOffMainThread() {
        let manager = TabManager()
        let workspace = manager.addWorkspace()
        manager.selectWorkspace(workspace)

        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let fakeSurface: ghostty_surface_t = UnsafeMutableRawPointer(bitPattern: 0x5282)!
        terminalPanel.surface.installRuntimeSurfaceForTesting(fakeSurface)
        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)

        let nativeFreeStarted = expectation(description: "native free started")
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            XCTAssertFalse(Thread.isMainThread, "Native surface free must not run on the main thread")
            nativeFreeStarted.fulfill()
        }
        defer {
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil
        }

        manager.confirmCloseHandler = { _, _, _ in true }

        XCTAssertTrue(manager.closeWorkspaceWithConfirmation(workspace))
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == workspace.id }))
        XCTAssertNil(terminalPanel.surface.surface)

        wait(for: [nativeFreeStarted], timeout: 3.0)
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
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"

    func testCloseCurrentPanelHonorsWarnBeforeClosingTabDisabledFromCmuxJSON() throws {
        try assertCloseCurrentPanelConfirmation(
            warnBeforeClosingTab: false,
            expectedPromptCount: 0,
            expectedPanelClosed: true
        )
    }

    func testCloseCurrentPanelHonorsWarnBeforeClosingTabEnabledFromCmuxJSON() throws {
        try assertCloseCurrentPanelConfirmation(
            warnBeforeClosingTab: true,
            expectedPromptCount: 1,
            expectedPanelClosed: false
        )
    }

    func testCloseCurrentPanelWarnBeforeClosingTabDefaultsToEnabledWhenUnset() throws {
        try assertCloseCurrentPanelConfirmation(
            warnBeforeClosingTab: nil,
            expectedPromptCount: 1,
            expectedPanelClosed: false
        )
    }

    func testTabCloseButtonWarningHonorsCmuxJSON() throws {
        try withCloseTabConfig(warnBeforeClosingTabXButton: true) {
            XCTAssertTrue(
                CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                    requiresConfirmation: false,
                    source: .tabCloseButton
                )
            )
        }
    }

    func testHideTabCloseButtonHonorsCmuxJSON() throws {
        try withCloseTabConfig(hideTabCloseButton: true) {
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace else {
                XCTFail("Expected selected workspace")
                return
            }

            XCTAssertFalse(workspace.bonsplitController.configuration.allowCloseTabs)
        }
    }

    func testTabCloseButtonWarningDefaultsOffForCleanPanel() throws {
        try assertTabCloseButtonConfirmation(
            warnBeforeClosingTab: nil,
            warnBeforeClosingTabXButton: nil,
            panelNeedsConfirmation: false,
            expectedPromptCount: 0,
            expectedPanelClosed: true
        )
    }

    func testTabCloseButtonWarningPromptsWhenEnabledForCleanPanel() throws {
        try assertTabCloseButtonConfirmation(
            warnBeforeClosingTab: nil,
            warnBeforeClosingTabXButton: true,
            panelNeedsConfirmation: false,
            expectedPromptCount: 1,
            expectedPanelClosed: false
        )
    }

    func testMiddleClickCloseDoesNotUseXButtonWarning() throws {
        try assertTabCloseButtonConfirmation(
            warnBeforeClosingTab: nil,
            warnBeforeClosingTabXButton: true,
            panelNeedsConfirmation: false,
            marksTabCloseButtonSource: false,
            expectedPromptCount: 0,
            expectedPanelClosed: true
        )
    }

    func testTabCloseButtonPreservesExistingDirtyPanelWarningWhenXButtonSettingIsOff() throws {
        try assertTabCloseButtonConfirmation(
            warnBeforeClosingTab: nil,
            warnBeforeClosingTabXButton: nil,
            panelNeedsConfirmation: true,
            expectedPromptCount: 1,
            expectedPanelClosed: false
        )
    }

    func testHideTabCloseButtonDisablesBonsplitTabCloseAffordances() throws {
        try withCloseTabUserDefaults(hideTabCloseButton: true) {
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace else {
                XCTFail("Expected selected workspace")
                return
            }

            XCTAssertFalse(workspace.bonsplitController.configuration.allowCloseTabs)
        }
    }

    func testTabCloseButtonVisibilityRefreshesFromDefaults() throws {
        try withCloseTabUserDefaults(hideTabCloseButton: false) {
            let defaults = UserDefaults.standard
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace else {
                XCTFail("Expected selected workspace")
                return
            }

            XCTAssertTrue(workspace.bonsplitController.configuration.allowCloseTabs)
            defaults.set(true, forKey: AppCatalogSection().hideTabCloseButton.userDefaultsKey)
            manager.refreshTabCloseButtonVisibility()

            XCTAssertFalse(workspace.bonsplitController.configuration.allowCloseTabs)
        }
    }

    func testCloseCurrentPanelHonorsWarnBeforeClosingTabDisabledForPinnedWorkspaceLastSurface() throws {
        try assertPinnedWorkspaceLastSurfaceConfirmation(
            warnBeforeClosingTab: false,
            expectedPromptCount: 0,
            expectedWorkspaceClosed: true
        )
    }

    func testCloseCurrentPanelHonorsWarnBeforeClosingTabEnabledForPinnedWorkspaceLastSurface() throws {
        try assertPinnedWorkspaceLastSurfaceConfirmation(
            warnBeforeClosingTab: true,
            expectedPromptCount: 1,
            expectedWorkspaceClosed: false
        )
    }

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

    private func assertCloseCurrentPanelConfirmation(
        warnBeforeClosingTab: Bool?,
        expectedPromptCount: Int,
        expectedPanelClosed: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try withWarnBeforeClosingTabConfig(warnBeforeClosingTab) {
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace,
                  let paneId = workspace.bonsplitController.focusedPaneId,
                  let initialPanelId = workspace.focusedPanelId,
                  let initialTerminalPanel = workspace.terminalPanel(for: initialPanelId),
                  workspace.newTerminalSurface(inPane: paneId, focus: false) != nil else {
                XCTFail("Expected workspace with two terminal surfaces", file: file, line: line)
                return
            }
            workspace.focusPanel(initialPanelId)
            initialTerminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)

            var promptCount = 0
            manager.confirmCloseHandler = { _, _, _ in
                promptCount += 1
                return false
            }

            manager.closeCurrentPanelWithConfirmation()
            drainMainQueue()
            drainMainQueue()
            drainMainQueue()

            XCTAssertEqual(promptCount, expectedPromptCount, file: file, line: line)
            if expectedPanelClosed {
                XCTAssertNil(workspace.panels[initialPanelId], file: file, line: line)
            } else {
                XCTAssertNotNil(workspace.panels[initialPanelId], file: file, line: line)
            }
        }
    }

    private func assertPinnedWorkspaceLastSurfaceConfirmation(
        warnBeforeClosingTab: Bool?,
        expectedPromptCount: Int,
        expectedWorkspaceClosed: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try withWarnBeforeClosingTabConfig(warnBeforeClosingTab) {
            let manager = TabManager()
            let firstWorkspace = manager.tabs[0]
            let pinnedWorkspace = manager.addWorkspace()
            manager.setPinned(pinnedWorkspace, pinned: true)
            manager.selectWorkspace(pinnedWorkspace)

            guard let pinnedPanelId = pinnedWorkspace.focusedPanelId else {
                XCTFail("Expected focused panel in pinned workspace", file: file, line: line)
                return
            }

            var promptCount = 0
            manager.confirmCloseHandler = { _, _, _ in
                promptCount += 1
                return false
            }

            manager.closeCurrentPanelWithConfirmation()
            drainMainQueue()
            drainMainQueue()
            drainMainQueue()

            XCTAssertEqual(promptCount, expectedPromptCount, file: file, line: line)
            if expectedWorkspaceClosed {
                XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id], file: file, line: line)
                XCTAssertNil(pinnedWorkspace.panels[pinnedPanelId], file: file, line: line)
            } else {
                XCTAssertTrue(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }), file: file, line: line)
                XCTAssertNotNil(pinnedWorkspace.panels[pinnedPanelId], file: file, line: line)
            }
        }
    }

    private func assertTabCloseButtonConfirmation(
        warnBeforeClosingTab: Bool?,
        warnBeforeClosingTabXButton: Bool?,
        panelNeedsConfirmation: Bool,
        marksTabCloseButtonSource: Bool = true,
        expectedPromptCount: Int,
        expectedPanelClosed: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try withCloseTabUserDefaults(
            warnBeforeClosingTab: warnBeforeClosingTab,
            warnBeforeClosingTabXButton: warnBeforeClosingTabXButton,
            hideTabCloseButton: false
        ) {
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace,
                  let paneId = workspace.bonsplitController.focusedPaneId,
                  let initialPanelId = workspace.focusedPanelId,
                  let initialTerminalPanel = workspace.terminalPanel(for: initialPanelId),
                  workspace.newTerminalSurface(inPane: paneId, focus: false) != nil,
                  let initialSurfaceId = workspace.surfaceIdFromPanelId(initialPanelId) else {
                XCTFail("Expected workspace with two terminal surfaces", file: file, line: line)
                return
            }
            workspace.focusPanel(initialPanelId)
            initialTerminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(panelNeedsConfirmation)

            var promptCount = 0
            manager.confirmCloseHandler = { _, _, _ in
                promptCount += 1
                return false
            }

            if marksTabCloseButtonSource {
                workspace.markTabCloseButtonClose(surfaceId: initialSurfaceId)
            } else {
                workspace.markExplicitClose(surfaceId: initialSurfaceId)
            }
            _ = workspace.bonsplitController.closeTab(initialSurfaceId)
            drainMainQueue()
            drainMainQueue()
            drainMainQueue()

            XCTAssertEqual(promptCount, expectedPromptCount, file: file, line: line)
            if expectedPanelClosed {
                XCTAssertNil(workspace.panels[initialPanelId], file: file, line: line)
            } else {
                XCTAssertNotNil(workspace.panels[initialPanelId], file: file, line: line)
            }
        }
    }

    private func withCloseTabUserDefaults(
        warnBeforeClosingTab: Bool? = nil,
        warnBeforeClosingTabXButton: Bool? = nil,
        hideTabCloseButton: Bool? = nil,
        run: () throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let originalWarnBeforeClosingTab = defaults.object(forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey)
        let originalWarnBeforeClosingTabXButton = defaults.object(forKey: AppCatalogSection().warnBeforeClosingTabXButton.userDefaultsKey)
        let originalHideTabCloseButton = defaults.object(forKey: AppCatalogSection().hideTabCloseButton.userDefaultsKey)
        defer {
            restore(originalWarnBeforeClosingTab, forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey, defaults: defaults)
            restore(originalWarnBeforeClosingTabXButton, forKey: AppCatalogSection().warnBeforeClosingTabXButton.userDefaultsKey, defaults: defaults)
            restore(originalHideTabCloseButton, forKey: AppCatalogSection().hideTabCloseButton.userDefaultsKey, defaults: defaults)
        }

        setOrRemove(warnBeforeClosingTab, forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey, defaults: defaults)
        setOrRemove(warnBeforeClosingTabXButton, forKey: AppCatalogSection().warnBeforeClosingTabXButton.userDefaultsKey, defaults: defaults)
        setOrRemove(hideTabCloseButton, forKey: AppCatalogSection().hideTabCloseButton.userDefaultsKey, defaults: defaults)

        try run()
    }

    private func setOrRemove(_ value: Bool?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func restore(_ value: Any?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func withWarnBeforeClosingTabConfig(
        _ warnBeforeClosingTab: Bool?,
        run: () throws -> Void
    ) throws {
        try withCloseTabConfig(warnBeforeClosingTab: warnBeforeClosingTab, run: run)
    }

    private func withCloseTabConfig(
        warnBeforeClosingTab: Bool? = nil,
        warnBeforeClosingTabXButton: Bool? = nil,
        hideTabCloseButton: Bool? = nil,
        run: () throws -> Void
    ) throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let defaults = UserDefaults.standard
        let originalWarnBeforeClosingTab = defaults.object(forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey)
        let originalWarnBeforeClosingTabXButton = defaults.object(forKey: AppCatalogSection().warnBeforeClosingTabXButton.userDefaultsKey)
        let originalHideTabCloseButton = defaults.object(forKey: AppCatalogSection().hideTabCloseButton.userDefaultsKey)
        let originalBackups = defaults.object(forKey: settingsFileBackupsDefaultsKey)
        defaults.removeObject(forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey)
        defaults.removeObject(forKey: AppCatalogSection().warnBeforeClosingTabXButton.userDefaultsKey)
        defaults.removeObject(forKey: AppCatalogSection().hideTabCloseButton.userDefaultsKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            restore(originalWarnBeforeClosingTab, forKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey, defaults: defaults)
            restore(originalWarnBeforeClosingTabXButton, forKey: AppCatalogSection().warnBeforeClosingTabXButton.userDefaultsKey, defaults: defaults)
            restore(originalHideTabCloseButton, forKey: AppCatalogSection().hideTabCloseButton.userDefaultsKey, defaults: defaults)
            if let originalBackups {
                defaults.set(originalBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WarnBeforeClosingTabTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        let settingLines = [
            warnBeforeClosingTab.map { #"    "warnBeforeClosingTab": \#($0)"# },
            warnBeforeClosingTabXButton.map { #"    "warnBeforeClosingTabXButton": \#($0)"# },
            hideTabCloseButton.map { #"    "hideTabCloseButton": \#($0)"# },
        ].compactMap { $0 }
        let appBody = settingLines.isEmpty ? "" : "\n\(settingLines.joined(separator: ",\n"))\n  "
        try """
        {
          "app": {\(appBody)}
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        try run()
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

    func testClosingSelectedTabInZoomedPaneClearsSplitZoomBeforeSelectingNextTab() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let firstPanelId = workspace.focusedPanelId,
              let firstPaneId = workspace.bonsplitController.focusedPaneId,
              workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal) != nil,
              let secondTabPanel = workspace.newTerminalSurface(inPane: firstPaneId, focus: true) else {
            XCTFail("Expected split workspace with two tabs in the first pane")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, secondTabPanel.id)
        XCTAssertTrue(workspace.toggleSplitZoom(panelId: secondTabPanel.id), "Expected split zoom to enable")
        XCTAssertTrue(workspace.bonsplitController.isSplitZoomed, "Expected workspace to start zoomed")

        XCTAssertTrue(workspace.closePanel(secondTabPanel.id, force: true), "Expected selected tab close to succeed")
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(workspace.focusedPanelId, firstPanelId, "Expected the surviving tab in the pane to become focused")
        XCTAssertFalse(
            workspace.bonsplitController.isSplitZoomed,
            "Closing the selected tab that owns zoom must not transfer the maximized layout to the next tab"
        )
        XCTAssertTrue(
            workspace.toggleSplitZoom(panelId: firstPanelId),
            "The surviving tab should still be zoomable on demand"
        )
        XCTAssertTrue(workspace.bonsplitController.isSplitZoomed)
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
    func testFocusTextBoxOnNewTerminalsDefaultAppliesToNewWorkspaceAndTerminalSurfaces() {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        let previousShowValue = defaults.object(forKey: showKey)
        let previousFocusValue = defaults.object(forKey: focusKey)
        defer {
            if let previousShowValue {
                defaults.set(previousShowValue, forKey: showKey)
            } else {
                defaults.removeObject(forKey: showKey)
            }
            if let previousFocusValue {
                defaults.set(previousFocusValue, forKey: focusKey)
            } else {
                defaults.removeObject(forKey: focusKey)
            }
        }

        defaults.set(false, forKey: showKey)
        defaults.set(true, forKey: focusKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanel = workspace.focusedTerminalPanel,
              let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected initial terminal workspace")
            return
        }

        XCTAssertTrue(initialPanel.isTextBoxActive)
        XCTAssertEqual(initialPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))

        guard let newTabPanel = workspace.newTerminalSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected new terminal tab")
            return
        }

        XCTAssertTrue(newTabPanel.isTextBoxActive)
        XCTAssertEqual(newTabPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))

        guard let splitPanel = workspace.newTerminalSplit(from: newTabPanel.id, orientation: .horizontal) else {
            XCTFail("Expected new terminal split")
            return
        }

        XCTAssertTrue(splitPanel.isTextBoxActive)
        XCTAssertEqual(splitPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
    }

    func testShowTextBoxOnNewTerminalsDefaultShowsWithoutStealingFocus() {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        let previousShowValue = defaults.object(forKey: showKey)
        let previousFocusValue = defaults.object(forKey: focusKey)
        defer {
            if let previousShowValue {
                defaults.set(previousShowValue, forKey: showKey)
            } else {
                defaults.removeObject(forKey: showKey)
            }
            if let previousFocusValue {
                defaults.set(previousFocusValue, forKey: focusKey)
            } else {
                defaults.removeObject(forKey: focusKey)
            }
        }

        defaults.set(true, forKey: showKey)
        defaults.set(false, forKey: focusKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanel = workspace.focusedTerminalPanel,
              let paneId = workspace.bonsplitController.focusedPaneId,
              let newTabPanel = workspace.newTerminalSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected initial and new terminal panels")
            return
        }

        XCTAssertTrue(initialPanel.isTextBoxActive)
        XCTAssertNotEqual(initialPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
        XCTAssertTrue(newTabPanel.isTextBoxActive)
        XCTAssertNotEqual(newTabPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
    }

    func testFocusTextBoxOnNewTerminalsDefaultLeavesNewTerminalsHiddenWhenDisabled() {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        let previousShowValue = defaults.object(forKey: showKey)
        let previousFocusValue = defaults.object(forKey: focusKey)
        defer {
            if let previousShowValue {
                defaults.set(previousShowValue, forKey: showKey)
            } else {
                defaults.removeObject(forKey: showKey)
            }
            if let previousFocusValue {
                defaults.set(previousFocusValue, forKey: focusKey)
            } else {
                defaults.removeObject(forKey: focusKey)
            }
        }

        defaults.set(false, forKey: showKey)
        defaults.set(false, forKey: focusKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanel = workspace.focusedTerminalPanel,
              let paneId = workspace.bonsplitController.focusedPaneId,
              let newTabPanel = workspace.newTerminalSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected initial and new terminal panels")
            return
        }

        XCTAssertFalse(initialPanel.isTextBoxActive)
        XCTAssertFalse(newTabPanel.isTextBoxActive)
    }

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

    func testToggleOmnibarFocusedBrowserIsSurfaceSpecific() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected focused browser panel")
            return
        }

        XCTAssertTrue(browserPanel.isOmnibarVisible)
        XCTAssertTrue(manager.toggleOmnibarFocusedBrowser())
        XCTAssertFalse(browserPanel.isOmnibarVisible)

        let otherBrowser = workspace.newBrowserSurface(
            inPane: workspace.paneId(forPanelId: browserPanelId) ?? workspace.bonsplitController.allPaneIds[0],
            focus: true
        )
        XCTAssertTrue(otherBrowser?.isOmnibarVisible ?? false)
    }

    func testNewBrowserSurfaceCanSelectBackgroundPaneWithoutTakingFocus() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: sourcePanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightPanel.id),
              let url = URL(string: "file:///tmp/cmux-diff.html") else {
            XCTFail("Expected split setup to succeed")
            return
        }
        workspace.focusPanel(sourcePanelId)
        let sourcePaneBefore = workspace.bonsplitController.focusedPaneId

        guard let browserPanel = workspace.newBrowserSurface(
            inPane: rightPaneId,
            url: url,
            focus: false,
            selectWhenNotFocused: true,
            omnibarVisible: false
        ), let browserSurfaceId = workspace.surfaceIdFromPanelId(browserPanel.id) else {
            XCTFail("Expected background browser surface to be created")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, sourcePanelId)
        XCTAssertEqual(workspace.bonsplitController.focusedPaneId, sourcePaneBefore)
        XCTAssertEqual(workspace.bonsplitController.selectedTab(inPane: rightPaneId)?.id, browserSurfaceId)
        XCTAssertFalse(browserPanel.isOmnibarVisible)
    }

    func testDuplicateBrowserPreservesDiffViewerChromeAndProxyBypass() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/token/diff.html#cmux-diff-viewer"))
        let browserPanel = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: true,
                omnibarVisible: false,
                bypassRemoteProxy: true
            )
        )
        guard browserPanel.setMuted(true) else {
            throw XCTSkip("WKWebView page-audio mute selector is unavailable")
        }

        let duplicate = try XCTUnwrap(workspace.duplicateBrowserToRight(panelId: browserPanel.id, focus: false))
        let duplicateTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(duplicate.id))
        let duplicateTab = try XCTUnwrap(workspace.bonsplitController.tab(duplicateTabId))

        XCTAssertFalse(duplicate.isOmnibarVisible)
        XCTAssertTrue(duplicate.bypassesRemoteWorkspaceProxyForTabDuplication)
        XCTAssertTrue(duplicate.isMuted)
        XCTAssertTrue(duplicateTab.isAudioMuted)
    }

    func testBrowserAudioMuteContextActionTogglesPanelAndTabState() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let browserPanel = try XCTUnwrap(workspace.newBrowserSurface(inPane: paneId, focus: true))
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(browserPanel.id))
        guard browserPanel.setMuted(false) else {
            throw XCTSkip("WKWebView page-audio mute selector is unavailable")
        }

        let initialTab = try XCTUnwrap(workspace.bonsplitController.tab(tabId))
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .toggleAudioMute,
            for: initialTab,
            inPane: paneId
        )

        XCTAssertTrue(browserPanel.isMuted)
        XCTAssertTrue(try XCTUnwrap(workspace.bonsplitController.tab(tabId)).isAudioMuted)

        let mutedTab = try XCTUnwrap(workspace.bonsplitController.tab(tabId))
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .toggleAudioMute,
            for: mutedTab,
            inPane: paneId
        )

        XCTAssertFalse(browserPanel.isMuted)
        XCTAssertFalse(try XCTUnwrap(workspace.bonsplitController.tab(tabId)).isAudioMuted)
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
    func testEqualizeSplitsKeepsMultiTabPaneAndBrowserAtHalfWidth() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: .horizontal,
                split: 0.2,
                children: [
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .terminal, name: "Terminal A"),
                        CmuxSurfaceDefinition(type: .terminal, name: "Terminal B")
                    ])),
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .browser, name: "Browser", url: "https://example.com")
                    ]))
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        guard case .split(let root) = workspace.bonsplitController.treeSnapshot() else {
            XCTFail("Expected horizontal root split")
            return
        }
        XCTAssertEqual(root.orientation, "horizontal")
        XCTAssertEqual(root.dividerPosition, 0.5, accuracy: 0.000_1)

        guard case .pane(let terminalPane) = root.first else {
            XCTFail("Expected first child to remain one pane containing multiple tabs")
            return
        }
        XCTAssertEqual(terminalPane.tabs.count, 2)
    }

    func testEqualizeSplitsBalancesThreeSameAxisSiblingPanesIntoThirds() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: .horizontal,
                split: 0.2,
                children: [
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .terminal, name: "Left")
                    ])),
                    .split(CmuxSplitDefinition(
                        direction: .horizontal,
                        split: 0.8,
                        children: [
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .terminal, name: "Middle")
                            ])),
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .browser, name: "Right", url: "https://example.com")
                            ]))
                        ]
                    ))
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        guard case .split(let root) = workspace.bonsplitController.treeSnapshot(),
              case .split(let rightColumn) = root.second else {
            XCTFail("Expected three-pane same-axis split tree")
            return
        }
        XCTAssertEqual(root.orientation, "horizontal")
        XCTAssertEqual(root.dividerPosition, 1.0 / 3.0, accuracy: 0.000_1)
        XCTAssertEqual(rightColumn.orientation, "horizontal")
        XCTAssertEqual(rightColumn.dividerPosition, 0.5, accuracy: 0.000_1)
    }

    func testEqualizeSplitsCountsCrossAxisSubtreeAsOneSpan() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: .horizontal,
                split: 0.2,
                children: [
                    .split(CmuxSplitDefinition(
                        direction: .vertical,
                        split: 0.8,
                        children: [
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .terminal, name: "Top Terminal")
                            ])),
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .terminal, name: "Bottom Terminal")
                            ]))
                        ]
                    )),
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .browser, name: "Browser", url: "https://example.com")
                    ]))
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        guard case .split(let root) = workspace.bonsplitController.treeSnapshot(),
              case .split(let leftStack) = root.first else {
            XCTFail("Expected browser beside a vertically stacked terminal subtree")
            return
        }
        XCTAssertEqual(root.orientation, "horizontal")
        XCTAssertEqual(root.dividerPosition, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(leftStack.orientation, "vertical")
        XCTAssertEqual(leftStack.dividerPosition, 0.5, accuracy: 0.000_1)
    }

    func testEqualizeSplitsDoesNotPropagateSameAxisSpansThroughCrossAxisBoundary() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: .horizontal,
                split: 0.2,
                children: [
                    .split(CmuxSplitDefinition(
                        direction: .vertical,
                        split: 0.8,
                        children: [
                            .split(CmuxSplitDefinition(
                                direction: .horizontal,
                                split: 0.8,
                                children: [
                                    .pane(CmuxPaneDefinition(surfaces: [
                                        CmuxSurfaceDefinition(type: .terminal, name: "Top Left")
                                    ])),
                                    .pane(CmuxPaneDefinition(surfaces: [
                                        CmuxSurfaceDefinition(type: .terminal, name: "Top Right")
                                    ]))
                                ]
                            )),
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .terminal, name: "Bottom")
                            ]))
                        ]
                    )),
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .browser, name: "Browser", url: "https://example.com")
                    ]))
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        guard case .split(let root) = workspace.bonsplitController.treeSnapshot(),
              case .split(let leftStack) = root.first,
              case .split(let topRow) = leftStack.first else {
            XCTFail("Expected browser beside a mixed nested terminal subtree")
            return
        }
        XCTAssertEqual(root.orientation, "horizontal")
        XCTAssertEqual(root.dividerPosition, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(leftStack.orientation, "vertical")
        XCTAssertEqual(leftStack.dividerPosition, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(topRow.orientation, "horizontal")
        XCTAssertEqual(topRow.dividerPosition, 0.5, accuracy: 0.000_1)
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

    func testTemporaryDiffViewerTabCloseDoesNotStageRestoreSnapshot() throws {
        let workspace = Workspace()
        let diffViewerURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/token/diff.html#cmux-diff-viewer"))
        guard let paneId = workspace.bonsplitController.focusedPaneId,
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, url: diffViewerURL, focus: false),
              let tabId = workspace.surfaceIdFromPanelId(browserPanel.id),
              let tab = workspace.bonsplitController.tab(tabId) else {
            XCTFail("Expected diff viewer browser panel setup")
            return
        }

        var closedSnapshot: ClosedBrowserPanelRestoreSnapshot?
        workspace.onClosedBrowserPanel = { snapshot in
            closedSnapshot = snapshot
        }

        XCTAssertTrue(workspace.splitTabBar(workspace.bonsplitController, shouldCloseTab: tab, inPane: paneId))
        workspace.splitTabBar(workspace.bonsplitController, didCloseTab: tabId, fromPane: paneId)

        XCTAssertNil(closedSnapshot)
    }

    func testBrowserWebViewDidCloseClosesPanelAndCmdShiftTRestoresIt() {
        let manager = TabManager()
        let expectedURL = URL(string: "https://example.com/self-close")
        guard let workspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: expectedURL),
              let browserPanel = workspace.panels[closedBrowserId] as? BrowserPanel else {
            XCTFail("Expected browser panel setup")
            return
        }

        drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        drainMainQueue()

        XCTAssertNil(workspace.panels[closedBrowserId])
        let panelIdsAfterClose = Set(workspace.panels.keys)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsAfterClose),
              let reopenedPanel = workspace.panels[reopenedPanelId] as? BrowserPanel else {
            XCTFail("Expected Cmd+Shift+T to restore the self-closed browser panel")
            return
        }
        XCTAssertEqual(reopenedPanel.currentURL, expectedURL)
        XCTAssertEqual(workspace.focusedPanelId, reopenedPanelId)
    }

    func testReopenClosedItemFallsBackToLegacyClosedBrowserStack() {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let expectedURL = URL(string: "https://example.com/self-close-item-fallback")
        guard let workspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: expectedURL),
              let browserPanel = workspace.panels[closedBrowserId] as? BrowserPanel else {
            XCTFail("Expected browser panel setup")
            return
        }

        drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        drainMainQueue()

        XCTAssertNil(workspace.panels[closedBrowserId])
        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)

        XCTAssertTrue(appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: manager))
        drainMainQueue()

        guard let reopenedPanel = workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first else {
            XCTFail("Expected reopened browser panel")
            return
        }
        XCTAssertEqual(reopenedPanel.currentURL, expectedURL)
    }

    func testReopenClosedItemUsesNewerLegacyBrowserBeforeOlderClosedStore() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let expectedURL = URL(string: "https://example.com/newer-legacy-browser")
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        var olderPanelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        olderPanelSnapshot.customTitle = "Older Stored Panel"
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 1),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: paneId.id,
                tabIndex: 0,
                snapshot: olderPanelSnapshot
            ))
        ))

        guard let closedBrowserId = manager.openBrowser(url: expectedURL),
              let browserPanel = workspace.panels[closedBrowserId] as? BrowserPanel else {
            XCTFail("Expected browser panel setup")
            return
        }

        drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        drainMainQueue()

        XCTAssertNil(workspace.panels[closedBrowserId])
        let panelIdsAfterClose = Set(workspace.panels.keys)

        XCTAssertTrue(appDelegate.reopenMostRecentlyClosedItem(
            preferredTabManager: manager,
            shouldActivate: false
        ))
        drainMainQueue()

        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsAfterClose),
              let reopenedPanel = workspace.panels[reopenedPanelId] as? BrowserPanel else {
            XCTFail("Expected Cmd+Shift+T to restore the newer self-closed browser before the older stored tab")
            return
        }
        XCTAssertEqual(reopenedPanel.currentURL, expectedURL)
        XCTAssertTrue(ClosedItemHistoryStore.shared.canReopen)
    }

    func testClearRecentlyClosedHistoryClearsLegacyBrowserStack() {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let expectedURL = URL(string: "https://example.com/clear-legacy-reopen")
        guard let workspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: expectedURL),
              let browserPanel = workspace.panels[closedBrowserId] as? BrowserPanel else {
            XCTFail("Expected browser panel setup")
            return
        }

        drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        drainMainQueue()

        XCTAssertNil(workspace.panels[closedBrowserId])
        appDelegate.clearRecentlyClosedHistory(preferredTabManager: manager)

        XCTAssertFalse(appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: manager))
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

    func testReopenDropsBrowserSnapshotWhenOriginalWorkspaceDeleted() {
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
        let currentPanelCountBefore = currentWorkspace.panels.count
        manager.closeWorkspace(originalWorkspace, recordHistory: false)

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == originalWorkspace.id }))

        XCTAssertFalse(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertEqual(currentWorkspace.panels.count, currentPanelCountBefore)
        XCTAssertFalse(isFocusedPanelBrowser(in: currentWorkspace))
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

/// Behavioral coverage for the cross-window workspace move primitive that backs
/// dragging a workspace from one window's sidebar into another window's sidebar
/// (`AppDelegate.moveWorkspaceToWindow(workspaceId:windowId:atIndex:focus:)`).
/// The app-level routing needs live windows, but the underlying mechanism —
/// `detachWorkspace` from the source manager + `attachWorkspace(at:)` on the
/// destination manager — is the move and is exercised directly here.
@MainActor
final class CrossWindowWorkspaceMoveTests: XCTestCase {
    func testMoveInsertsAtDropIndexInDestination() {
        let source = TabManager()
        let destination = TabManager()
        let moving = source.addWorkspace()
        _ = source.addWorkspace()

        let destFirst = destination.tabs[0]
        let destSecond = destination.addWorkspace()

        guard let detached = source.detachWorkspace(tabId: moving.id) else {
            XCTFail("Expected to detach the dragged workspace from the source window")
            return
        }
        XCTAssertEqual(detached.id, moving.id)
        destination.attachWorkspace(detached, at: 1, select: true)

        XCTAssertEqual(
            destination.tabs.map(\.id),
            [destFirst.id, moving.id, destSecond.id],
            "Moved workspace should land at the requested drop index in the destination"
        )
        XCTAssertEqual(destination.selectedTabId, moving.id)
        XCTAssertFalse(
            source.tabs.contains { $0.id == moving.id },
            "Source window must no longer contain the moved workspace"
        )
        XCTAssertTrue(
            destination.tabs.allSatisfy { $0.owningTabManager === destination },
            "Destination workspaces should be owned by the destination manager"
        )
    }

    func testMoveAppendsWhenNoDropIndex() {
        let source = TabManager()
        let destination = TabManager()
        let moving = source.addWorkspace()
        _ = source.addWorkspace()

        let existingDestIds = destination.tabs.map(\.id)

        guard let detached = source.detachWorkspace(tabId: moving.id) else {
            XCTFail("Expected to detach the dragged workspace")
            return
        }
        destination.attachWorkspace(detached, at: nil, select: true)

        XCTAssertEqual(
            destination.tabs.map(\.id),
            existingDestIds + [moving.id],
            "With no drop index the moved workspace appends to the destination"
        )
    }

    func testMovingLastWorkspaceKeepsSourceNonEmpty() {
        let source = TabManager()
        let destination = TabManager()
        let onlyWorkspace = source.tabs[0]

        guard let detached = source.detachWorkspace(tabId: onlyWorkspace.id) else {
            XCTFail("Expected to detach the only workspace")
            return
        }
        destination.attachWorkspace(detached, at: nil, select: true)

        XCTAssertFalse(
            source.tabs.isEmpty,
            "Detaching the last workspace must leave the source window with a fresh workspace"
        )
        XCTAssertFalse(
            source.tabs.contains { $0.id == onlyWorkspace.id },
            "The moved workspace should no longer be in the source window"
        )
        XCTAssertTrue(destination.tabs.contains { $0.id == onlyWorkspace.id })
    }

    func testMovingPinnedWorkspaceLandsAtFrontEvenWhenDroppedBelowUnpinnedRows() {
        let source = TabManager()
        let destination = TabManager()
        let destFirst = destination.tabs[0]   // unpinned
        let moving = source.tabs[0]
        source.setPinned(moving, pinned: true)

        guard let detached = source.detachWorkspace(tabId: moving.id) else {
            XCTFail("Expected to detach the pinned workspace")
            return
        }
        XCTAssertTrue(detached.isPinned, "Detach must preserve the pinned state")

        // Request a drop position *below* the destination's unpinned row.
        destination.attachWorkspace(detached, at: 1, select: true)

        XCTAssertEqual(
            destination.tabs.first?.id,
            moving.id,
            "A pinned workspace must land in the leading pinned segment regardless of drop index"
        )
        XCTAssertTrue(destination.tabs.contains { $0.id == destFirst.id })
    }

    func testMovingWorkspaceIntoMiddleOfGroupRunKeepsGroupContiguous() {
        let source = TabManager()
        let destination = TabManager()

        // Build a destination group with an anchor + two members.
        let memberA = destination.tabs[0]
        let memberB = destination.addWorkspace()
        guard let groupId = destination.createWorkspaceGroup(
            name: "Group",
            childWorkspaceIds: [memberA.id, memberB.id]
        ) else {
            XCTFail("Expected to create a destination group")
            return
        }

        let moving = source.tabs[0]
        guard let detached = source.detachWorkspace(tabId: moving.id) else {
            XCTFail("Expected to detach the workspace")
            return
        }
        XCTAssertNil(detached.groupId, "Detach must clear group membership")

        // Aim the insert into the middle of the group's contiguous run.
        let middle = max(1, destination.tabs.count - 1)
        destination.attachWorkspace(detached, at: middle, select: true)

        // The moved (ungrouped) workspace must not sit between grouped rows.
        let groupedOffsets = destination.tabs.enumerated()
            .filter { $0.element.groupId == groupId }
            .map(\.offset)
        XCTAssertFalse(groupedOffsets.isEmpty)
        let isContiguous = groupedOffsets.max()! - groupedOffsets.min()! == groupedOffsets.count - 1
        XCTAssertTrue(
            isContiguous,
            "The destination group's rows must stay contiguous after a cross-window move"
        )
        XCTAssertTrue(destination.tabs.contains { $0.id == moving.id })
    }
}
