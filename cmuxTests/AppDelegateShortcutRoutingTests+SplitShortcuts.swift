import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Split and diff viewer shortcut tests
extension AppDelegateShortcutRoutingTests {
    func testCmdDRoutesSplitToEventWindowWhenKeyWindowIsDifferent() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = UUID()
        let secondWindowId = UUID()
        let firstWindow = makeRegisteredShortcutRoutingWindow(id: firstWindowId)
        let secondWindow = makeRegisteredShortcutRoutingWindow(id: secondWindowId)
        let firstManager = TabManager()
        let secondManager = TabManager()
        let firstSidebarState = SidebarState(isVisible: true)
        let secondSidebarState = SidebarState(isVisible: true)

        appDelegate.registerMainWindow(
            firstWindow,
            windowId: firstWindowId,
            tabManager: firstManager,
            sidebarState: firstSidebarState,
            sidebarSelectionState: SidebarSelectionState()
        )
        appDelegate.registerMainWindow(
            secondWindow,
            windowId: secondWindowId,
            tabManager: secondManager,
            sidebarState: secondSidebarState,
            sidebarSelectionState: SidebarSelectionState()
        )
        defer {
            closeRegisteredShortcutRoutingWindow(firstWindow, id: firstWindowId)
            closeRegisteredShortcutRoutingWindow(secondWindow, id: secondWindowId)
        }

        firstWindow.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let firstVisibleBefore = firstSidebarState.isVisible
        let secondVisibleBefore = secondSidebarState.isVisible

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2, // kVK_ANSI_D
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        withTemporaryShortcut(
            action: .toggleSidebar,
            shortcut: StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
        ) {
#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: firstWindowId), firstVisibleBefore, "Cmd+D must not route to the stale key window")
        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: secondWindowId), !secondVisibleBefore, "Cmd+D should route to the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Shortcut routing should keep the event window active")
    }

    func testCmdDPropagatesWhenSplitRightShortcutIsCleared() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window, manager, and workspace")
            return
        }

        window.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialPanelCount = workspace.panels.count

        withTemporaryShortcut(action: .splitRight, shortcut: .unbound) {
            guard let event = makeKeyDownEvent(
                key: "d",
                modifiers: [.command],
                keyCode: 2,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+D event")
                return
            }

#if DEBUG
            XCTAssertFalse(
                appDelegate.debugHandleCustomShortcut(event: event),
                "Cleared Cmd+D split shortcut should not be consumed by cmux"
            )
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(
            workspace.panels.count,
            initialPanelCount,
            "Cleared Cmd+D split shortcut should propagate instead of creating a new pane"
        )
    }

    func testPerformSplitShortcutSplitsFocusedTerminalSurfaceWhenSelectedWorkspaceIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let originalPanelIds = Set(workspace.panels.keys)

        guard let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let leftPaneBefore = workspace.paneId(forPanelId: leftPanel.id),
              let rightPaneBefore = workspace.paneId(forPanelId: rightPanel.id) else {
            XCTFail("Expected split pane IDs")
            return
        }
        let layoutBefore = workspace.bonsplitController.layoutSnapshot()
        guard let leftPaneBeforeFrame = layoutBefore.panes.first(where: { $0.paneId == leftPaneBefore.id.uuidString })?.frame,
              let rightPaneBeforeFrame = layoutBefore.panes.first(where: { $0.paneId == rightPaneBefore.id.uuidString })?.frame else {
            XCTFail("Expected pane frames before shortcut split")
            return
        }
        XCTAssertLessThan(leftPaneBeforeFrame.x, rightPaneBeforeFrame.x, "Expected baseline layout to start left-to-right")

        guard let leftSurfaceView = surfaceView(in: leftPanel.hostedView) else {
            XCTFail("Expected left terminal surface view")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        workspace.focusPanel(rightPanel.id)
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id, "Expected Bonsplit selection to stay on the right pane")
        leftPanel.hostedView.suppressReparentFocus()
        XCTAssertTrue(window.makeFirstResponder(leftSurfaceView))
        leftPanel.hostedView.clearSuppressReparentFocus()
        XCTAssertTrue(window.firstResponder === leftSurfaceView, "Expected left Ghostty surface to stay first responder")
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id, "Expected selected pane to stay stale after first-responder change")
        XCTAssertEqual(leftSurfaceView.tabId, workspace.id, "Expected focused Ghostty view to keep its workspace ID")
        XCTAssertEqual(leftSurfaceView.terminalSurface?.id, leftPanel.id, "Expected focused Ghostty view to keep its surface ID")

        XCTAssertTrue(
            appDelegate.performSplitShortcut(direction: .right, preferredWindow: window),
            "Split shortcut should use the focused terminal surface even when selectedTabId is stale"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))

        let newPanelIds = Set(workspace.panels.keys)
            .subtracting(originalPanelIds)
            .subtracting([rightPanel.id])
        guard newPanelIds.count == 1, let newPanelId = newPanelIds.first else {
            XCTFail("Expected exactly one shortcut-created split panel")
            return
        }
        guard let newPaneId = workspace.paneId(forPanelId: newPanelId),
              let rightPaneAfter = workspace.paneId(forPanelId: rightPanel.id) else {
            XCTFail("Expected pane IDs after shortcut split")
            return
        }
        let layoutAfter = workspace.bonsplitController.layoutSnapshot()
        guard let newPaneFrame = layoutAfter.panes.first(where: { $0.paneId == newPaneId.id.uuidString })?.frame,
              let rightPaneAfterFrame = layoutAfter.panes.first(where: { $0.paneId == rightPaneAfter.id.uuidString })?.frame else {
            XCTFail("Expected pane frames after shortcut split")
            return
        }
        XCTAssertEqual(layoutAfter.panes.count, 3, "Cmd+D should create a third pane")
        XCTAssertLessThan(
            newPaneFrame.x,
            rightPaneAfterFrame.x,
            "Cmd+D should split the focused left terminal pane, not the stale selected right pane"
        )
    }

    func testOpenDiffViewerShortcutDefaultsToCmdCtrlDAndRoutesToSharedDiffPath() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Default is Cmd+Ctrl+Shift+D. Plain Cmd+Ctrl+D is reserved by macOS ("Look Up")
        // and never reaches the app, and the rest of the Cmd+D family is taken by split
        // actions; the default must be conflict-free so the recorder accepts it as-is.
        let cmdCtrlShiftD = StoredShortcut(key: "d", command: true, shift: true, option: false, control: true)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .openDiffViewer), cmdCtrlShiftD)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.openDiffViewer.normalizedRecordedShortcutResult(cmdCtrlShiftD),
            .accepted(cmdCtrlShiftD),
            "Default Open Diff Viewer shortcut must not conflict with any other action"
        )
        XCTAssertTrue(
            KeyboardShortcutSettings.settingsVisibleActions.contains(.openDiffViewer),
            "Open Diff Viewer must be visible/editable in Settings → Keyboard Shortcuts"
        )

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        // Intercept the shared diff-open path so the dispatch test never spawns a
        // subprocess; we only assert the shortcut routes here.
        var openDiffViewerCount = 0
        appDelegate.debugOpenDiffViewerHandler = { openDiffViewerCount += 1 }
        defer { appDelegate.debugOpenDiffViewerHandler = nil }

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command, .control, .shift],
            keyCode: 2, // kVK_ANSI_D
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+Shift+D event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+Ctrl+Shift+D should be consumed by the Open Diff Viewer shortcut"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertEqual(
            openDiffViewerCount,
            1,
            "Cmd+Ctrl+Shift+D must route to the shared diff-open path (same path as the command palette)"
        )
    }

}
