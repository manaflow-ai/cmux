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


