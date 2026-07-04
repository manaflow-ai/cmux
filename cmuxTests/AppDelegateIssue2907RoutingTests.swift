import XCTest
import CmuxTerminal
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateIssue2907RoutingTests: XCTestCase {
    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    private func decodeV2Response(_ response: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = try XCTUnwrap(response.data(using: .utf8), file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    private func v2Envelope(
        method: String,
        params: [String: Any] = [:],
        id: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (raw: String, envelope: [String: Any]) {
        let request: [String: Any] = [
            "id": id ?? method,
            "method": method,
            "params": params
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try XCTUnwrap(String(data: requestData, encoding: .utf8), file: file, line: line)
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        return (raw, try decodeV2Response(raw, file: file, line: line))
    }

    private func v2Result(
        method: String,
        params: [String: Any] = [:],
        id: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let (raw, envelope) = try v2Envelope(method: method, params: params, id: id, file: file, line: line)
        XCTAssertEqual(envelope["ok"] as? Bool, true, raw, file: file, line: line)
        return try XCTUnwrap(envelope["result"] as? [String: Any], raw, file: file, line: line)
    }

    private func v2Error(
        method: String,
        params: [String: Any] = [:],
        id: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let (raw, envelope) = try v2Envelope(method: method, params: params, id: id, file: file, line: line)
        XCTAssertEqual(envelope["ok"] as? Bool, false, raw, file: file, line: line)
        return try XCTUnwrap(envelope["error"] as? [String: Any], raw, file: file, line: line)
    }

    private func workspaceListPayload(surfaceId: UUID, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try v2Result(
            method: "workspace.list",
            params: ["surface_id": surfaceId.uuidString],
            id: "workspace-list",
            file: file,
            line: line
        )
    }

    private func assertWorkspaceListContains(
        _ payload: [String: Any],
        workspaceId: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let workspaces = try XCTUnwrap(payload["workspaces"] as? [[String: Any]], file: file, line: line)
        XCTAssertTrue(
            workspaces.contains { ($0["id"] as? String) == workspaceId.uuidString },
            "workspace.list should include \(workspaceId.uuidString)",
            file: file,
            line: line
        )
    }

    func testReportPwdPathOptionKeepsDisplayLabelSeparateFromFilesystemDirectory() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let filesystemDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-report-pwd-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: filesystemDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: filesystemDirectory) }

        let displayLabel = "MyPackage  mainline"
        let response = TerminalController.shared.handleSocketLine(
            "report_pwd \"\(displayLabel)\" --path=\(filesystemDirectory.path) --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        XCTAssertEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertEqual(workspace.currentDirectory, filesystemDirectory.path)
        XCTAssertEqual(workspace.panelDirectories[panelId], filesystemDirectory.path)
        XCTAssertEqual(workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: [panelId]), [displayLabel])
        XCTAssertEqual(workspace.sidebarFinderDirectory(), filesystemDirectory.path)
    }

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

    func testWorkspaceGetCwdRejectsExplicitWorkspaceOutsideExplicitWindow() throws {
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
        let workspaceB = try XCTUnwrap(managerB.selectedWorkspace)
        workspaceB.setDefaultWorkingDirectory("/tmp/cmux-window-b-\(UUID().uuidString)")

        let error = try v2Error(
            method: "workspace.get_cwd",
            params: [
                "window_id": windowAId.uuidString,
                "workspace_id": workspaceB.id.uuidString,
            ]
        )

        XCTAssertEqual(error["code"] as? String, "not_found")
    }

    func testWorkspaceSetCwdRejectsExplicitWorkspaceOutsideExplicitWindow() throws {
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
        let workspaceB = try XCTUnwrap(managerB.selectedWorkspace)
        let originalDefaultDirectory = "/tmp/cmux-window-b-original-\(UUID().uuidString)"
        let wrongWindowDirectory = "/tmp/cmux-window-b-wrong-\(UUID().uuidString)"
        workspaceB.setDefaultWorkingDirectory(originalDefaultDirectory)

        let error = try v2Error(
            method: "workspace.set_cwd",
            params: [
                "window_id": windowAId.uuidString,
                "workspace_id": workspaceB.id.uuidString,
                "cwd": wrongWindowDirectory,
            ]
        )

        XCTAssertEqual(error["code"] as? String, "not_found")
        XCTAssertEqual(workspaceB.defaultWorkingDirectory, originalDefaultDirectory)
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
        XCTAssertTrue(GhosttyApp.terminalSurfaceRegistry.surface(id: surfaceId) === terminalPanel.surface)
        XCTAssertEqual(terminalPanel.surface.debugLastKnownWorkspaceId(), workspace.id)

        try assertWorkspaceListContains(try workspaceListPayload(surfaceId: surfaceId), workspaceId: workspace.id)

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        TerminalController.shared.setActiveTabManager(nil)

        try assertWorkspaceListContains(try workspaceListPayload(surfaceId: surfaceId), workspaceId: workspace.id)
    }

    func testSurfaceResumeSetRejectsSurfaceOutsideExplicitWindow() throws {
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

        let secondWorkspace = try XCTUnwrap(secondManager.selectedWorkspace)
        let secondPanelId = try XCTUnwrap(secondWorkspace.focusedPanelId)
        let (raw, envelope) = try v2Envelope(
            method: "surface.resume.set",
            params: [
                "window_id": firstWindowId.uuidString,
                "surface_id": secondPanelId.uuidString,
                "command": "echo wrong-window"
            ]
        )

        XCTAssertEqual(envelope["ok"] as? Bool, false, raw)
        XCTAssertNil(secondWorkspace.surfaceResumeBinding(panelId: secondPanelId))
    }

    func testSurfaceResumeRejectsMalformedSurfaceOrTabIdWithoutFocusedFallback() throws {
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

        let manager = TabManager(autoWelcomeIfNeeded: false)
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(command: "echo keep", source: "test"),
            panelId: panelId
        ))

        for key in ["surface_id", "tab_id"] {
            for method in ["surface.resume.set", "surface.resume.get", "surface.resume.clear"] {
                var params: [String: Any] = [
                    "window_id": windowId.uuidString,
                    key: "not-a-surface"
                ]
                if method == "surface.resume.set" {
                    params["command"] = "echo bad"
                }

                let (raw, envelope) = try v2Envelope(method: method, params: params)

                XCTAssertEqual(envelope["ok"] as? Bool, false, raw)
                let error = try XCTUnwrap(envelope["error"] as? [String: Any], raw)
                XCTAssertEqual(error["code"] as? String, "invalid_params", raw)
                XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.command, "echo keep")
            }
        }
    }

    func testSurfaceResumeUsesTabIdAliasForTargetSurface() throws {
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

        let manager = TabManager(autoWelcomeIfNeeded: false)
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
        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let focusedPanel = try XCTUnwrap(workspace.terminalPanel(for: focusedPanelId))
        let splitPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: focusedPanel.id,
            orientation: .horizontal,
            focus: false
        ))

        let setResult = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "tab_id": splitPanel.id.uuidString,
                "command": "tmux attach -t alias-target",
                "checkpoint_id": "alias-target",
            ]
        )
        XCTAssertEqual(setResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: focusedPanel.id))
        XCTAssertEqual(
            workspace.surfaceResumeBinding(panelId: splitPanel.id)?.command,
            "tmux attach -t alias-target"
        )

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "tab_id": splitPanel.id.uuidString,
            ]
        )
        XCTAssertEqual(getResult["surface_id"] as? String, splitPanel.id.uuidString)
        let getBinding = try XCTUnwrap(getResult["resume_binding"] as? [String: Any])
        XCTAssertEqual(getBinding["checkpoint_id"] as? String, "alias-target")

        let clearResult = try v2Result(
            method: "surface.resume.clear",
            params: [
                "window_id": windowId.uuidString,
                "tab_id": splitPanel.id.uuidString,
                "checkpoint_id": "alias-target",
            ]
        )
        XCTAssertEqual(clearResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertEqual(clearResult["cleared"] as? Bool, true)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: splitPanel.id))
    }

    func testSurfaceResumePayloadIncludesEnvironment() throws {
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

        let manager = TabManager(autoWelcomeIfNeeded: false)
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let environment = [
            "EMPTY": "",
            "SPACED": "  keep exact  ",
            "ANTHROPIC_API_KEY": "should-not-persist",
        ]
        let setResult = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "command": "tmux attach -t dogfood",
                "environment": environment,
            ]
        )
        let setBinding = try XCTUnwrap(setResult["resume_binding"] as? [String: Any])
        let setEnvironment = try XCTUnwrap(setBinding["environment"] as? [String: Any])
        XCTAssertEqual(setEnvironment["EMPTY"] as? String, "")
        XCTAssertEqual(setEnvironment["SPACED"] as? String, "  keep exact  ")
        XCTAssertNil(setEnvironment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(setBinding["auto_resume"] as? Bool, false)

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let getBinding = try XCTUnwrap(getResult["resume_binding"] as? [String: Any])
        let getEnvironment = try XCTUnwrap(getBinding["environment"] as? [String: Any])
        XCTAssertEqual(getEnvironment["EMPTY"] as? String, "")
        XCTAssertEqual(getEnvironment["SPACED"] as? String, "  keep exact  ")
        XCTAssertNil(getEnvironment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(getBinding["auto_resume"] as? Bool, false)
    }

    func testSurfaceResumeSetCannotEnableAutoResumeFromSocket() throws {
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

        let manager = TabManager(autoWelcomeIfNeeded: false)
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let result = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "command": "tmux attach -t sticky",
                "source": "process-detected",
                "auto_resume": true,
            ]
        )

        let binding = try XCTUnwrap(result["resume_binding"] as? [String: Any])
        XCTAssertEqual(binding["auto_resume"] as? Bool, false)
        XCTAssertEqual(binding["source"] as? String, "manual")
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume, false)
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.source, "manual")
    }

    func testSurfaceResumeSetAllowsAgentHookAutoResume() throws {
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

        let manager = TabManager(autoWelcomeIfNeeded: false)
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let result = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "command": "codex resume session",
                "source": "agent-hook",
                "auto_resume": true,
            ]
        )

        let binding = try XCTUnwrap(result["resume_binding"] as? [String: Any])
        XCTAssertEqual(binding["auto_resume"] as? Bool, true)
        XCTAssertEqual(binding["source"] as? String, "agent-hook")
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume, true)
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.source, "agent-hook")
    }

    func testSurfaceResumeClearCheckpointGuardKeepsDifferentBinding() throws {
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

        let manager = TabManager(autoWelcomeIfNeeded: false)
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
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        _ = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "surface_id": panelId.uuidString,
                "command": "codex resume new-session",
                "checkpoint_id": "new-session",
                "source": "agent-hook",
            ]
        )

        let clearResult = try v2Result(
            method: "surface.resume.clear",
            params: [
                "window_id": windowId.uuidString,
                "surface_id": panelId.uuidString,
                "checkpoint_id": "old-session",
                "source": "agent-hook",
            ]
        )

        XCTAssertEqual(clearResult["cleared"] as? Bool, false)
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.checkpointId, "new-session")
    }

    func testIssue2907TabManagerDependentSocketCommandsRecoverLiveSurfaceContext() throws {
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

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let surfaceId = terminalPanel.id
        XCTAssertTrue(GhosttyApp.terminalSurfaceRegistry.surface(id: surfaceId) === terminalPanel.surface)
        XCTAssertEqual(terminalPanel.surface.debugLastKnownWorkspaceId(), workspace.id)

        try assertWorkspaceListContains(try v2Result(method: "workspace.list"), workspaceId: workspace.id)
        let baselineTree = try v2Result(method: "system.tree")
        let baselineWindows = try XCTUnwrap(baselineTree["windows"] as? [[String: Any]])
        XCTAssertTrue(baselineWindows.contains { ($0["id"] as? String) == windowId.uuidString })

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        TerminalController.shared.setActiveTabManager(nil)

        let ping = try v2Result(method: "system.ping")
        XCTAssertEqual(ping["pong"] as? Bool, true)
        _ = try v2Result(method: "system.capabilities")

        let tree = try v2Result(method: "system.tree")
        let debugTerminals = try v2Result(method: "debug.terminals")
        let terminals = try XCTUnwrap(debugTerminals["terminals"] as? [[String: Any]])
        let originalTerminal = try XCTUnwrap(
            terminals.first { ($0["surface_id"] as? String) == surfaceId.uuidString }
        )
        XCTAssertEqual(originalTerminal["mapped"] as? Bool, true)
        XCTAssertEqual(originalTerminal["workspace_id"] as? String, workspace.id.uuidString)
        XCTAssertEqual(originalTerminal["last_known_workspace_id"] as? String, workspace.id.uuidString)

        let recoveredTreeWindows = try XCTUnwrap(tree["windows"] as? [[String: Any]])
        XCTAssertTrue(
            recoveredTreeWindows.contains { ($0["id"] as? String) == windowId.uuidString },
            "system.tree should not report an empty world while a live terminal surface is still associated with its workspace"
        )

        let currentWindow = try v2Result(method: "window.current")
        XCTAssertEqual(currentWindow["window_id"] as? String, windowId.uuidString)

        let currentWorkspace = try v2Result(method: "workspace.current")
        XCTAssertEqual(currentWorkspace["workspace_id"] as? String, workspace.id.uuidString)

        let workspaceList = try v2Result(method: "workspace.list")
        try assertWorkspaceListContains(workspaceList, workspaceId: workspace.id)

        let workspaceListBySurface = try v2Result(method: "workspace.list", params: ["surface_id": surfaceId.uuidString])
        try assertWorkspaceListContains(workspaceListBySurface, workspaceId: workspace.id)

        let surfaces = try v2Result(method: "surface.list", params: ["surface_id": surfaceId.uuidString])
        XCTAssertEqual(surfaces["workspace_id"] as? String, workspace.id.uuidString)

        let currentSurface = try v2Result(method: "surface.current", params: ["surface_id": surfaceId.uuidString])
        XCTAssertEqual(currentSurface["workspace_id"] as? String, workspace.id.uuidString)

        let panes = try v2Result(method: "pane.list", params: ["surface_id": surfaceId.uuidString])
        XCTAssertEqual(panes["workspace_id"] as? String, workspace.id.uuidString)

        let health = try v2Result(method: "surface.health", params: ["surface_id": surfaceId.uuidString])
        XCTAssertEqual(health["workspace_id"] as? String, workspace.id.uuidString)

        let split = try v2Result(
            method: "surface.split",
            params: [
                "surface_id": surfaceId.uuidString,
                "direction": "right",
                "focus": false
            ]
        )
        XCTAssertNotNil(split["surface_id"] as? String)
    }

    func testIssue2907NoTargetCommandsPreferKeyRecoveredWindowOverRegisteredWindow() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let registeredWindowId = UUID()
        let recoveredWindowId = UUID()
        let registeredWindow = makeMainWindow(id: registeredWindowId)
        let recoveredWindow = makeMainWindow(id: recoveredWindowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: registeredWindowId)
            app.unregisterMainWindowContextForTesting(windowId: recoveredWindowId)
            registeredWindow.orderOut(nil)
            recoveredWindow.orderOut(nil)
        }

        let registeredManager = TabManager()
        let recoveredManager = TabManager()
        app.registerMainWindow(
            registeredWindow,
            windowId: registeredWindowId,
            tabManager: registeredManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            recoveredWindow,
            windowId: recoveredWindowId,
            tabManager: recoveredManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        registeredWindow.makeKeyAndOrderFront(nil)
        recoveredWindow.makeKeyAndOrderFront(nil)
        TerminalController.shared.setActiveTabManager(recoveredManager)

        let recoveredWorkspace = try XCTUnwrap(recoveredManager.selectedWorkspace)
        let recoveredTerminal = try XCTUnwrap(recoveredWorkspace.focusedTerminalPanel)
        XCTAssertTrue(GhosttyApp.terminalSurfaceRegistry.surface(id: recoveredTerminal.id) === recoveredTerminal.surface)

        app.unregisterMainWindowContextForTesting(windowId: recoveredWindowId)
        TerminalController.shared.setActiveTabManager(nil)

        let currentWindow = try v2Result(method: "window.current")
        XCTAssertEqual(currentWindow["window_id"] as? String, recoveredWindowId.uuidString)

        let currentWorkspace = try v2Result(method: "workspace.current")
        XCTAssertEqual(currentWorkspace["workspace_id"] as? String, recoveredWorkspace.id.uuidString)
    }

    func testIssue2907BonsplitTabLookupUsesRecoveredRoute() throws {
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

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let bonsplitTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(terminalPanel.id)?.uuid)

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        TerminalController.shared.setActiveTabManager(nil)

        let located = try XCTUnwrap(app.locateBonsplitSurface(tabId: bonsplitTabId))
        XCTAssertEqual(located.windowId, windowId)
        XCTAssertEqual(located.workspaceId, workspace.id)
        XCTAssertEqual(located.panelId, terminalPanel.id)
        XCTAssertTrue(located.tabManager === manager)
    }

    func testRecoveredRouteRequiresTerminalOwnedBySameTabManager() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let terminalWindowId = UUID()
        let browserOnlyWindowId = UUID()
        let terminalWindow = makeMainWindow(id: terminalWindowId)
        let browserOnlyWindow = makeMainWindow(id: browserOnlyWindowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: terminalWindowId)
            app.unregisterMainWindowContextForTesting(windowId: browserOnlyWindowId)
            terminalWindow.orderOut(nil)
            browserOnlyWindow.orderOut(nil)
        }

        let terminalManager = TabManager()
        let browserOnlyManager = TabManager()
        app.registerMainWindow(
            terminalWindow,
            windowId: terminalWindowId,
            tabManager: terminalManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            browserOnlyWindow,
            windowId: browserOnlyWindowId,
            tabManager: browserOnlyManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        let terminalWorkspace = try XCTUnwrap(terminalManager.selectedWorkspace)
        let terminalPanel = try XCTUnwrap(terminalWorkspace.focusedTerminalPanel)
        XCTAssertTrue(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)

        let browserOnlyWorkspace = try XCTUnwrap(browserOnlyManager.selectedWorkspace)
        let browserOnlyTerminal = try XCTUnwrap(browserOnlyWorkspace.focusedTerminalPanel)
        let browserPaneId = try XCTUnwrap(browserOnlyWorkspace.bonsplitController.allPaneIds.first)
        let browserPanel = try XCTUnwrap(
            browserOnlyWorkspace.newBrowserSurface(
                inPane: browserPaneId,
                url: URL(string: "https://example.com/browser-only"),
                focus: true,
                creationPolicy: .restoration
            )
        )
        XCTAssertTrue(browserOnlyWorkspace.closePanel(browserOnlyTerminal.id, force: true))
        XCTAssertNotNil(browserOnlyWorkspace.panels[browserPanel.id])
        XCTAssertFalse(browserOnlyWorkspace.panels.values.contains { $0 is TerminalPanel })

        app.unregisterMainWindowContextForTesting(windowId: browserOnlyWindowId)

        XCTAssertNil(app.tabManagerFor(windowId: browserOnlyWindowId))
        XCTAssertFalse(app.listMainWindowSummaries().contains { $0.windowId == browserOnlyWindowId })
        XCTAssertTrue(app.tabManagerFor(windowId: terminalWindowId) === terminalManager)
    }

    func testWorkspaceCreationContinuesAfterStaleActiveContextDiscard() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let staleManager = TabManager()
        let liveManager = TabManager()
        let staleWindowId = app.registerMainWindowContextForTesting(tabManager: staleManager)
        let liveWindowId = UUID()
        let liveWindow = makeMainWindow(id: liveWindowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: staleWindowId)
            app.unregisterMainWindowContextForTesting(windowId: liveWindowId)
            liveWindow.orderOut(nil)
        }

        app.registerMainWindow(
            liveWindow,
            windowId: liveWindowId,
            tabManager: liveManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        liveWindow.makeKeyAndOrderFront(nil)
        app.tabManager = staleManager
        TerminalController.shared.setActiveTabManager(staleManager)

        let originalLiveWorkspaceCount = liveManager.tabs.count
        let createdWorkspace = app.addWorkspaceInPreferredMainWindow(
            shouldBringToFront: false,
            debugSource: "test.issue2907.staleActiveContext"
        )

        let unwrappedCreatedWorkspaceId = try XCTUnwrap(createdWorkspace).id
        XCTAssertEqual(liveManager.tabs.count, originalLiveWorkspaceCount + 1)
        XCTAssertTrue(liveManager.tabs.contains { $0.id == unwrappedCreatedWorkspaceId })
    }

    func testPaneBreakSuccessIncludesDestinationPaneReference() throws {
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

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePanel = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel)
        let splitPanel = try XCTUnwrap(sourceWorkspace.newTerminalSplit(
            from: sourcePanel.id,
            orientation: .horizontal,
            focus: false
        ))

        let payload = try v2Result(
            method: "pane.break",
            params: [
                "surface_id": splitPanel.id.uuidString,
                "focus": false
            ]
        )

        let destinationWorkspaceIdString = try XCTUnwrap(payload["workspace_id"] as? String)
        let destinationPaneIdString = try XCTUnwrap(payload["pane_id"] as? String)
        let destinationPaneRef = try XCTUnwrap(payload["pane_ref"] as? String)
        let destinationWorkspace = try XCTUnwrap(
            manager.tabs.first { $0.id.uuidString == destinationWorkspaceIdString }
        )

        XCTAssertEqual(payload["window_id"] as? String, windowId.uuidString)
        XCTAssertEqual(payload["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertFalse(destinationPaneIdString.isEmpty)
        XCTAssertTrue(destinationPaneRef.hasPrefix("pane:"))
        XCTAssertEqual(
            destinationWorkspace.paneId(forPanelId: splitPanel.id)?.id.uuidString,
            destinationPaneIdString
        )
    }

    func testSurfaceResumeSetUsesLiveSurfaceWhenWorkspaceIdIsOmittedAfterMove() throws {
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

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePanel = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel)
        let splitPanel = try XCTUnwrap(sourceWorkspace.newTerminalSplit(
            from: sourcePanel.id,
            orientation: .horizontal,
            focus: false
        ))
        let moved = try v2Result(
            method: "pane.break",
            params: [
                "surface_id": splitPanel.id.uuidString,
                "focus": false,
            ]
        )
        let destinationWorkspaceId = try XCTUnwrap(moved["workspace_id"] as? String)
        let destinationWorkspace = try XCTUnwrap(
            manager.tabs.first { $0.id.uuidString == destinationWorkspaceId }
        )

        _ = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "surface_id": splitPanel.id.uuidString,
                "command": "tmux attach -t moved",
                "source": "agent-hook",
            ]
        )

        XCTAssertNil(sourceWorkspace.surfaceResumeBinding(panelId: splitPanel.id))
        XCTAssertEqual(
            destinationWorkspace.surfaceResumeBinding(panelId: splitPanel.id)?.command,
            "tmux attach -t moved"
        )
    }

    func testSurfaceResumeSetRejectsMismatchedWorkspaceScopeAfterMove() throws {
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

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePanel = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel)
        let splitPanel = try XCTUnwrap(sourceWorkspace.newTerminalSplit(
            from: sourcePanel.id,
            orientation: .horizontal,
            focus: false
        ))
        let moved = try v2Result(
            method: "pane.break",
            params: [
                "surface_id": splitPanel.id.uuidString,
                "focus": false,
            ]
        )
        let destinationWorkspaceId = try XCTUnwrap(moved["workspace_id"] as? String)
        let destinationWorkspace = try XCTUnwrap(
            manager.tabs.first { $0.id.uuidString == destinationWorkspaceId }
        )

        let (raw, envelope) = try v2Envelope(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": sourceWorkspace.id.uuidString,
                "surface_id": splitPanel.id.uuidString,
                "command": "tmux attach -t moved",
                "source": "agent-hook",
            ]
        )

        XCTAssertEqual(envelope["ok"] as? Bool, false, raw)
        XCTAssertNil(sourceWorkspace.surfaceResumeBinding(panelId: splitPanel.id))
        XCTAssertNil(destinationWorkspace.surfaceResumeBinding(panelId: splitPanel.id))
    }
}
