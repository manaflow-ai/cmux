import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Window Selector & Workspace Command Routing
extension AppDelegateIssue2907RoutingTests {
    func testWorkspaceReorderManyRoutesByWorkspaceOwnerWhenWindowIsOmitted() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let managerA = TabManager(autoWelcomeIfNeeded: false)
        let managerB = TabManager(autoWelcomeIfNeeded: false)
        let windowAId = app.registerMainWindowContextForTesting(tabManager: managerA)
        let windowBId = app.registerMainWindowContextForTesting(tabManager: managerB)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowAId)
            app.unregisterMainWindowContextForTesting(windowId: windowBId)
        }

        TerminalController.shared.setActiveTabManager(managerA)
        let originalAOrder = managerA.tabs.map(\.id)
        let firstB = try XCTUnwrap(managerB.tabs.first)
        let secondB = managerB.addWorkspace(select: false, eagerLoadTerminal: false)
        let thirdB = managerB.addWorkspace(select: false, eagerLoadTerminal: false)

        let result = try v2Result(
            method: "workspace.reorder_many",
            params: [
                "workspace_ids": [thirdB.id.uuidString, firstB.id.uuidString]
            ]
        )

        XCTAssertEqual(result["window_id"] as? String, windowBId.uuidString)
        XCTAssertEqual(managerA.tabs.map(\.id), originalAOrder)
        XCTAssertEqual(managerB.tabs.map(\.id), [thirdB.id, firstB.id, secondB.id])
    }

    func testWorkspaceReorderManyRejectsEmptyOrderItems() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
        }

        TerminalController.shared.setActiveTabManager(manager)
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let originalOrder = manager.tabs.map(\.id)

        let orderError = try v2Error(
            method: "workspace.reorder_many",
            params: [
                "order": "\(first.id.uuidString),,\(second.id.uuidString)"
            ]
        )
        XCTAssertEqual(orderError["code"] as? String, "invalid_params")
        XCTAssertEqual(manager.tabs.map(\.id), originalOrder)

        let arrayError = try v2Error(
            method: "workspace.reorder_many",
            params: [
                "workspace_ids": [first.id.uuidString, " ", second.id.uuidString]
            ]
        )
        XCTAssertEqual(arrayError["code"] as? String, "invalid_params")
        XCTAssertEqual(manager.tabs.map(\.id), originalOrder)
    }

    func testSystemTreeWindowSelectorErrorsUseWindowContext() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let missingWindowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let conflict = try v2Error(
            method: "system.tree",
            params: ["window_id": windowId.uuidString, "all_windows": true]
        )
        XCTAssertEqual(conflict["code"] as? String, "invalid_params")
        XCTAssertTrue((conflict["message"] as? String)?.contains("Choose either --window") == true)
        let conflictData = try XCTUnwrap(conflict["data"] as? [String: Any])
        XCTAssertEqual(conflictData["window_id"] as? String, windowId.uuidString)
        XCTAssertNil(conflictData["window_ref"])

        let missing = try v2Error(
            method: "system.tree",
            params: [
                "window_id": missingWindowId.uuidString,
                "workspace_id": UUID().uuidString,
            ]
        )
        XCTAssertEqual(missing["code"] as? String, "not_found")
        XCTAssertTrue((missing["message"] as? String)?.contains("cmux list-windows") == true)
        let missingData = try XCTUnwrap(missing["data"] as? [String: Any])
        XCTAssertEqual(missingData["window_id"] as? String, missingWindowId.uuidString)
        XCTAssertNil(missingData["window_ref"])
    }

    func testPaneFocusWindowSelectorRejectsPaneFromOtherWindow() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId1 = UUID()
        let windowId2 = UUID()
        let window1 = makeMainWindow(id: windowId1)
        let window2 = makeMainWindow(id: windowId2)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId1)
            app.unregisterMainWindowContextForTesting(windowId: windowId2)
            window1.orderOut(nil)
            window2.orderOut(nil)
        }

        let manager1 = TabManager()
        let manager2 = TabManager()
        app.registerMainWindow(
            window1,
            windowId: windowId1,
            tabManager: manager1,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            window2,
            windowId: windowId2,
            tabManager: manager2,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager1)

        let workspace1 = try XCTUnwrap(manager1.selectedWorkspace)
        let workspace2 = try XCTUnwrap(manager2.selectedWorkspace)
        let surface2 = try XCTUnwrap(workspace2.focusedPanelId)
        let pane2 = try XCTUnwrap(workspace2.paneId(forPanelId: surface2)?.id)

        let error = try v2Error(
            method: "pane.focus",
            params: [
                "window_id": windowId1.uuidString,
                "pane_id": pane2.uuidString,
            ]
        )
        XCTAssertEqual(error["code"] as? String, "not_found")
        XCTAssertEqual(manager1.selectedTabId, workspace1.id)
        XCTAssertEqual(manager2.selectedTabId, workspace2.id)
    }

    func testUnresolvedWindowRefDoesNotFallBackToActiveWindow() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let error = try v2Error(
            method: "workspace.current",
            params: ["window_id": "window:999"]
        )
        XCTAssertEqual(error["code"] as? String, "unavailable")
    }

    func testWorkspaceListRejectsWindowAliasInsteadOfDefaultWindowFallback() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let firstWindowId = UUID()
        let secondWindowId = UUID()
        let firstWindow = makeMainWindow(id: firstWindowId)
        let secondWindow = makeMainWindow(id: secondWindowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            app.unregisterMainWindowContextForTesting(windowId: secondWindowId)
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }

        let firstManager = TabManager(autoWelcomeIfNeeded: false)
        let secondManager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            firstWindow,
            windowId: firstWindowId,
            tabManager: firstManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            secondWindow,
            windowId: secondWindowId,
            tabManager: secondManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(firstManager)

        let firstWorkspace = try XCTUnwrap(firstManager.selectedWorkspace)
        let secondWorkspace = try XCTUnwrap(secondManager.selectedWorkspace)

        let windowList = try v2Result(method: "window.list")
        let windows = try XCTUnwrap(windowList["windows"] as? [[String: Any]])
        let secondWindowRef = try XCTUnwrap(
            windows.first { ($0["id"] as? String) == secondWindowId.uuidString }?["ref"] as? String
        )

        let routedList = try v2Result(
            method: "workspace.list",
            params: ["window_id": secondWindowRef]
        )
        XCTAssertEqual(routedList["window_id"] as? String, secondWindowId.uuidString)
        try assertWorkspaceListContains(routedList, workspaceId: secondWorkspace.id)
        let routedWorkspaces = try XCTUnwrap(routedList["workspaces"] as? [[String: Any]])
        XCTAssertFalse(routedWorkspaces.contains { ($0["id"] as? String) == firstWorkspace.id.uuidString })

        let error = try v2Error(
            method: "workspace.list",
            params: ["window": secondWindowRef]
        )
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["unsupported_param"] as? String, "window")
        XCTAssertEqual(data["supported_param"] as? String, "window_id")
    }

    func testWorkspaceCreateRejectsWindowAliasInsteadOfDefaultWindowFallback() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let firstWindowId = UUID()
        let secondWindowId = UUID()
        let firstWindow = makeMainWindow(id: firstWindowId)
        let secondWindow = makeMainWindow(id: secondWindowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            app.unregisterMainWindowContextForTesting(windowId: secondWindowId)
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }

        let firstManager = TabManager(autoWelcomeIfNeeded: false)
        let secondManager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            firstWindow,
            windowId: firstWindowId,
            tabManager: firstManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            secondWindow,
            windowId: secondWindowId,
            tabManager: secondManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(firstManager)

        let windowList = try v2Result(method: "window.list")
        let windows = try XCTUnwrap(windowList["windows"] as? [[String: Any]])
        let secondWindowRef = try XCTUnwrap(
            windows.first { ($0["id"] as? String) == secondWindowId.uuidString }?["ref"] as? String
        )

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count
        let error = try v2Error(
            method: "workspace.create",
            params: [
                "window": secondWindowRef,
                "title": "should not create"
            ]
        )

        XCTAssertEqual(error["code"] as? String, "invalid_params")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["unsupported_param"] as? String, "window")
        XCTAssertEqual(data["supported_param"] as? String, "window_id")
        XCTAssertEqual(firstManager.tabs.count, firstCount)
        XCTAssertEqual(secondManager.tabs.count, secondCount)
    }

    func testWorkspaceListResolvesLiveSurfaceAfterMainWindowContextAssociationIsLost() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            window.orderOut(nil)
        }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let surfaceId = terminalPanel.id
        XCTAssertTrue(TerminalSurfaceRegistry.shared.surface(id: surfaceId) === terminalPanel.surface)
        XCTAssertEqual(terminalPanel.surface.debugLastKnownWorkspaceId(), workspace.id)

        try assertWorkspaceListContains(try workspaceListPayload(surfaceId: surfaceId), workspaceId: workspace.id)

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        TerminalController.shared.setActiveTabManager(nil)

        try assertWorkspaceListContains(try workspaceListPayload(surfaceId: surfaceId), workspaceId: workspace.id)
    }

}
