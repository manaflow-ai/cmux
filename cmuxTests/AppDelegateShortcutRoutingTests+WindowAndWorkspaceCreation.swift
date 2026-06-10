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

// MARK: - Window and workspace creation shortcut tests
extension AppDelegateShortcutRoutingTests {
    func testCreateMainWindowDoesNotDisallowFullScreenTilingByDefault() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        XCTAssertFalse(
            window.collectionBehavior.contains(.fullScreenDisallowsTiling),
            "Main windows should still support standard macOS Split View when not created from a fullscreen source"
        )
    }

    func testCreateMainWindowTemporarilyDisallowsFullScreenTilingFromFullscreenSource() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        appDelegate.debugCreateMainWindowSourceIsNativeFullScreenOverride = true

        let newWindowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: newWindowId)
        }

        guard let newWindow = window(withId: newWindowId) else {
            XCTFail("Expected new window")
            return
        }

        XCTAssertTrue(
            newWindow.collectionBehavior.contains(.fullScreenDisallowsTiling),
            "New windows should temporarily opt out of fullscreen tiling while opening from a fullscreen source"
        )

        appDelegate.debugCreateMainWindowSourceIsNativeFullScreenOverride = nil
        waitUntil(timeout: 1.0) {
            !newWindow.collectionBehavior.contains(.fullScreenDisallowsTiling)
        }

        XCTAssertFalse(
            newWindow.collectionBehavior.contains(.fullScreenDisallowsTiling),
            "The fullscreen tiling opt-out should be cleared after initial presentation so Split View keeps working"
        )
    }

    func testAddWorkspaceInPreferredMainWindowIgnoresStaleTabManagerPointer() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        secondWindow.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Force a stale app-level pointer to a different manager.
        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        _ = appDelegate.addWorkspaceInPreferredMainWindow()

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Stale pointer must not receive menu-driven workspace creation")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Workspace creation should target key/main window context")
    }

    func testToggleSidebarInActiveMainWindowIgnoresStaleTabManagerPointer() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstVisibleBefore = appDelegate.sidebarVisibility(windowId: firstWindowId),
              let secondVisibleBefore = appDelegate.sidebarVisibility(windowId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Force a stale app-level pointer to another manager. Window-local UI
        // controls should still target the key/main window, not this stale pointer.
        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        XCTAssertTrue(appDelegate.toggleSidebarInActiveMainWindow())

        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: firstWindowId),
            firstVisibleBefore,
            "Stale active-manager pointer must not receive sidebar toggles"
        )
        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: secondWindowId),
            !secondVisibleBefore,
            "Sidebar toggle should target the key/main window context"
        )
    }

    func testWelcomeWindowSidebarShortcutsUseSharedToggleCommands() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleSidebar.label,
            String(localized: "shortcut.toggleLeftSidebar.label", defaultValue: "Toggle Left Sidebar"),
            "Welcome should expose the shared left-sidebar toggle command"
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleSidebar.defaultShortcut,
            StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleRightSidebar.label,
            String(localized: "shortcut.toggleRightSidebar.label", defaultValue: "Toggle Right Sidebar"),
            "Welcome should expose the shared right-sidebar toggle command, not a File Explorer-only action"
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleRightSidebar.defaultShortcut,
            StoredShortcut(key: "b", command: true, shift: false, option: true, control: false)
        )

        let defaults = UserDefaults.standard
        let previousRightSidebarVisibility = defaults.object(forKey: "fileExplorer.isVisible")
        defer {
            restoreDefaultsValue(previousRightSidebarVisibility, forKey: "fileExplorer.isVisible", defaults: defaults)
        }

        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")

        let tabManager = TabManager()
        let sidebarState = SidebarState(isVisible: true)
        let sidebarSelectionState = SidebarSelectionState()
        let fileExplorerState = FileExplorerState()
        fileExplorerState.setVisible(false)

        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState
        )

        defer {
            window.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let leftSidebarEvent = makeKeyDownEvent(
            key: "b",
            modifiers: [.command],
            keyCode: 11,
            windowNumber: window.windowNumber
        ), let rightSidebarEvent = makeKeyDownEvent(
            key: "b",
            modifiers: [.command, .option],
            keyCode: 11,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct sidebar shortcut events")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: leftSidebarEvent))
        XCTAssertFalse(sidebarState.isVisible, "Cmd+B should toggle the Welcome window left sidebar")

        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: rightSidebarEvent))
        _ = waitForCondition { fileExplorerState.isVisible }
        XCTAssertTrue(fileExplorerState.isVisible, "Cmd+Option+B should toggle the Welcome window right sidebar")
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testDockMenuNewWindowItemCreatesMainWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let existingWindowId = appDelegate.createMainWindow()
        var createdWindowId: UUID?
        defer {
            if let createdWindowId {
                closeWindow(withId: createdWindowId)
            }
            closeWindow(withId: existingWindowId)
        }

        let existingWindowIds = mainWindowIds()

        let delegate: NSApplicationDelegate = appDelegate
        guard let dockMenu = delegate.applicationDockMenu?(NSApp) else {
            XCTFail("Expected Dock menu")
            return
        }

        let expectedTitle = String(localized: "menu.file.newWindow", defaultValue: "New Window")
        guard let item = dockMenu.items.first(where: { $0.action == #selector(AppDelegate.openNewMainWindow(_:)) }) else {
            XCTFail("Expected New Window item in Dock menu")
            return
        }

        XCTAssertEqual(item.title, expectedTitle)
        XCTAssertTrue(NSApp.sendAction(#selector(AppDelegate.openNewMainWindow(_:)), to: item.target, from: item))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let newWindowIds = mainWindowIds().subtracting(existingWindowIds)
        XCTAssertEqual(newWindowIds.count, 1, "Dock menu New Window should create one main window")
        createdWindowId = newWindowIds.first
    }

    func testRestorePreviousSessionSnapshotCreatesNewWindowWithoutClosingCurrentWindows() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let baselineWindowIds = mainWindowIds()
        let liveWindowId = appDelegate.createMainWindow(shouldActivate: false)
        defer {
            for windowId in mainWindowIds().subtracting(baselineWindowIds) {
                closeWindow(withId: windowId)
            }
        }

        guard let liveManager = appDelegate.tabManagerFor(windowId: liveWindowId),
              let liveWorkspace = liveManager.selectedWorkspace else {
            XCTFail("Expected live window manager and workspace")
            return
        }
        liveWorkspace.setCustomTitle("Current Work")
        let windowIdsAfterLiveWindow = mainWindowIds()

        let restoredManager = TabManager(autoWelcomeIfNeeded: false)
        let restoredWorkspace = try XCTUnwrap(restoredManager.selectedWorkspace)
        restoredWorkspace.setCustomTitle("Previous Work")
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_700_000_000,
            windows: [sessionWindowSnapshot(tabManager: restoredManager)]
        )

        XCTAssertTrue(appDelegate.restorePreviousSessionSnapshot(snapshot, shouldActivate: false))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let finalWindowIds = mainWindowIds()
        XCTAssertTrue(finalWindowIds.contains(liveWindowId))
        XCTAssertEqual(liveManager.selectedWorkspace?.customTitle, "Current Work")

        let createdWindowIds = finalWindowIds.subtracting(windowIdsAfterLiveWindow)
        XCTAssertEqual(createdWindowIds.count, 1)
        let restoredWindowId = try XCTUnwrap(createdWindowIds.first)
        let restoredWindowManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: restoredWindowId))
        XCTAssertEqual(restoredWindowManager.selectedWorkspace?.customTitle, "Previous Work")
    }

    func testRestorePreviousSessionSnapshotRemapsClosedWorkspaceWindowIds() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let baselineWindowIds = mainWindowIds()
        let liveWindowId = appDelegate.createMainWindow(shouldActivate: false)
        defer {
            for windowId in mainWindowIds().subtracting(baselineWindowIds) {
                closeWindow(withId: windowId)
            }
        }

        let liveManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: liveWindowId))
        let oldRestoredWindowId = UUID()

        let restoredManager = TabManager(autoWelcomeIfNeeded: false)
        let restoredWorkspace = try XCTUnwrap(restoredManager.selectedWorkspace)
        restoredWorkspace.setCustomTitle("Previous Work")

        let closedWorkspaceManager = TabManager(autoWelcomeIfNeeded: false)
        let closedWorkspace = try XCTUnwrap(closedWorkspaceManager.selectedWorkspace)
        closedWorkspace.setCustomTitle("Closed Previous Workspace")
        let closedRecordId = UUID()
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: closedRecordId,
            closedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: closedWorkspace.id,
                windowId: oldRestoredWindowId,
                workspaceIndex: 1,
                snapshot: closedWorkspace.sessionSnapshot(includeScrollback: false)
            ))
        ))

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_700_000_001,
            windows: [sessionWindowSnapshot(tabManager: restoredManager, windowId: oldRestoredWindowId)]
        )

        XCTAssertTrue(appDelegate.restorePreviousSessionSnapshot(snapshot, shouldActivate: false))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let restoredWindowIds = mainWindowIds().subtracting(baselineWindowIds).subtracting([liveWindowId])
        XCTAssertEqual(restoredWindowIds.count, 1)
        let restoredWindowId = try XCTUnwrap(restoredWindowIds.first)
        let restoredWindowManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: restoredWindowId))

        XCTAssertTrue(
            appDelegate.reopenClosedHistoryItem(
                id: closedRecordId,
                preferredTabManager: liveManager,
                shouldActivate: false
            )
        )
        XCTAssertTrue(restoredWindowManager.tabs.contains { $0.customTitle == "Closed Previous Workspace" })
        XCTAssertFalse(liveManager.tabs.contains { $0.customTitle == "Closed Previous Workspace" })
    }

    func testFailedClosedWindowRestoreDoesNotRemapClosedPanelHistoryToDiscardedWindow() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let baselineWindowIds = mainWindowIds()
        defer {
            for windowId in mainWindowIds().subtracting(baselineWindowIds) {
                closeWindow(withId: windowId)
            }
        }

        let sourceManager = TabManager(autoWelcomeIfNeeded: false)
        let sourceWorkspace = try XCTUnwrap(sourceManager.selectedWorkspace)
        let originalWorkspaceId = sourceWorkspace.id
        var closedPanelSnapshot = try XCTUnwrap(sourceWorkspace.sessionSnapshot(includeScrollback: false).panels.first)
        closedPanelSnapshot.customTitle = "Panel From Failed Window"
        let closedPanelRecordId = UUID()
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: closedPanelRecordId,
            closedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: originalWorkspaceId,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: closedPanelSnapshot
            ))
        ))

        var invalidWorkspaceSnapshot = sourceWorkspace.sessionSnapshot(includeScrollback: false)
        var invalidPanelSnapshot = try XCTUnwrap(invalidWorkspaceSnapshot.panels.first)
        invalidPanelSnapshot.type = .markdown
        invalidPanelSnapshot.title = "Broken Markdown"
        invalidPanelSnapshot.customTitle = "Broken Markdown"
        invalidPanelSnapshot.terminal = nil
        invalidPanelSnapshot.browser = nil
        invalidPanelSnapshot.markdown = nil
        invalidPanelSnapshot.filePreview = nil
        invalidPanelSnapshot.rightSidebarTool = nil
        invalidWorkspaceSnapshot.panels = [invalidPanelSnapshot]
        invalidWorkspaceSnapshot.layout = .pane(SessionPaneLayoutSnapshot(
            panelIds: [invalidPanelSnapshot.id],
            selectedPanelId: invalidPanelSnapshot.id
        ))

        let originalWindowId = UUID()
        let failedWindowRecordId = UUID()
        let failedWindowSnapshot = SessionWindowSnapshot(
            windowId: originalWindowId,
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [invalidWorkspaceSnapshot]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: failedWindowRecordId,
            closedAt: Date(timeIntervalSince1970: 1_700_000_001),
            entry: .window(ClosedWindowHistoryEntry(
                windowId: originalWindowId,
                snapshot: failedWindowSnapshot,
                workspaceIds: [originalWorkspaceId]
            ))
        ))

        XCTAssertFalse(appDelegate.reopenClosedHistoryItem(
            id: failedWindowRecordId,
            shouldActivate: false
        ))

        let record = try XCTUnwrap(ClosedItemHistoryStore.shared.removeRecord(id: closedPanelRecordId)?.record)
        guard case .panel(let panelEntry) = record.entry else {
            return XCTFail("Expected closed panel history")
        }
        XCTAssertEqual(panelEntry.workspaceId, originalWorkspaceId)
        XCTAssertTrue(panelEntry.restoreInOriginalPane)
    }

    func testCmdShiftNCreatesWindowFromEventWindowWithoutAddingWorkspace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()
        var createdWindowId: UUID?

        defer {
            if let createdWindowId {
                closeWindow(withId: createdWindowId)
            }
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let firstWindow = window(withId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let visibleFrame = (secondWindow.screen ?? NSScreen.main)?.visibleFrame else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstFrame = NSRect(
            x: visibleFrame.minX + 40,
            y: visibleFrame.maxY - 460,
            width: 760,
            height: 420
        )
        let secondFrame = NSRect(
            x: min(visibleFrame.minX + 180, visibleFrame.maxX - 600),
            y: max(visibleFrame.minY + 80, visibleFrame.maxY - 560),
            width: 560,
            height: 380
        )
        firstWindow.setFrame(firstFrame, display: true)
        secondWindow.setFrame(secondFrame, display: true)
        firstWindow.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let eventSourceFrame = secondWindow.frame
        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count
        let existingWindowIds = mainWindowIds()

        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command, .shift],
            keyCode: 45,
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let newWindowIds = mainWindowIds().subtracting(existingWindowIds)
        XCTAssertEqual(newWindowIds.count, 1, "Cmd+Shift+N should create one new main window")
        createdWindowId = newWindowIds.first

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Cmd+Shift+N must not create a workspace in the key window")
        XCTAssertEqual(secondManager.tabs.count, secondCount, "Cmd+Shift+N must not create a workspace in the event window")

        guard let createdWindowId,
              let createdWindow = window(withId: createdWindowId) else {
            XCTFail("Expected created window")
            return
        }

        XCTAssertEqual(createdWindow.frame.width, eventSourceFrame.width, accuracy: 1)
        XCTAssertEqual(createdWindow.frame.height, eventSourceFrame.height, accuracy: 1)
        XCTAssertTrue(
            visibleFrame.contains(createdWindow.frame),
            "New window should be placed inside the source window display"
        )
    }

    func testAddWorkspaceInPreferredMainWindowUsesKeyWindowWhenObjectKeyLookupIsMismatched() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
        XCTAssertTrue(appDelegate.debugInjectWindowContextKeyMismatch(windowId: secondWindowId))
#else
        XCTFail("debugInjectWindowContextKeyMismatch is only available in DEBUG")
#endif

        // Stale pointer should not receive the new workspace.
        appDelegate.tabManager = firstManager

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        _ = appDelegate.addWorkspaceInPreferredMainWindow()

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Menu-driven add workspace should not route to stale window")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Menu-driven add workspace should still route to key window context when object-key lookup misses")
    }

    func testAddWorkspaceInPreferredMainWindowPrunesOrphanedContextWithoutLiveWindow() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let orphanWindowId = UUID()
        let orphanManager = TabManager()
        let orphanSidebarState = SidebarState()
        let orphanSidebarSelectionState = SidebarSelectionState()
        let orphanFileExplorerState = FileExplorerState()

        autoreleasepool {
            var orphanWindow: NSWindow? = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            orphanWindow?.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(orphanWindowId.uuidString)")
            appDelegate.registerMainWindow(
                orphanWindow!,
                windowId: orphanWindowId,
                tabManager: orphanManager,
                sidebarState: orphanSidebarState,
                sidebarSelectionState: orphanSidebarSelectionState,
                fileExplorerState: orphanFileExplorerState
            )
            orphanWindow = nil
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertNil(appDelegate.mainWindow(for: orphanWindowId), "Test precondition: orphaned context should not have a live window")

        let orphanCount = orphanManager.tabs.count
        XCTAssertNil(
            appDelegate.addWorkspaceInPreferredMainWindow(),
            "Workspace creation should refuse orphaned contexts with no live window"
        )
        XCTAssertEqual(orphanManager.tabs.count, orphanCount, "Orphaned manager must not receive a new workspace")
        XCTAssertNil(appDelegate.tabManagerFor(windowId: orphanWindowId), "Orphaned context should be pruned after failed resolution")
    }

    func testCustomCmdTNewWorkspacePrunesOrphanedContextWithoutLiveWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let existingWindowIds = mainWindowIds()
        let orphanWindowId = UUID()
        let orphanManager = TabManager()
        let orphanSidebarState = SidebarState()
        let orphanSidebarSelectionState = SidebarSelectionState()
        let orphanFileExplorerState = FileExplorerState()

        autoreleasepool {
            var orphanWindow: NSWindow? = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            orphanWindow?.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(orphanWindowId.uuidString)")
            appDelegate.registerMainWindow(
                orphanWindow!,
                windowId: orphanWindowId,
                tabManager: orphanManager,
                sidebarState: orphanSidebarState,
                sidebarSelectionState: orphanSidebarSelectionState,
                fileExplorerState: orphanFileExplorerState
            )
            orphanWindow = nil
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertNil(appDelegate.mainWindow(for: orphanWindowId), "Test precondition: orphaned context should not have a live window")

        let orphanCount = orphanManager.tabs.count
        let remappedCmdT = StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)

        withTemporaryShortcut(action: .newTab, shortcut: remappedCmdT) {
            guard let event = makeKeyDownEvent(
                key: "t",
                modifiers: [.command],
                keyCode: 17, // kVK_ANSI_T
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct remapped Cmd+T event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        XCTAssertEqual(orphanManager.tabs.count, orphanCount, "Orphaned manager must not receive a new workspace from remapped Cmd+T")
        XCTAssertNil(appDelegate.tabManagerFor(windowId: orphanWindowId), "Remapped Cmd+T should prune the orphaned context after failed resolution")

        let createdWindowIds = mainWindowIds().subtracting(existingWindowIds)
        for windowId in createdWindowIds {
            closeWindow(withId: windowId)
        }
    }

    @discardableResult
    private func waitForCondition(
        timeout: TimeInterval = 1.0,
        interval: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
        }
        return condition()
    }

    private func mainWindowIds() -> Set<UUID> {
        Set(NSApp.windows.compactMap { window in
            guard let raw = window.identifier?.rawValue,
                  raw.hasPrefix("cmux.main.") else {
                return nil
            }
            return UUID(uuidString: String(raw.dropFirst("cmux.main.".count)))
        })
    }

}
