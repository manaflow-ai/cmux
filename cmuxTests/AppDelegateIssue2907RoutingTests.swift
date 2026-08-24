import CmuxTerminal
import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AppDelegateIssue2907RoutingTests {
    private let assertions = SwiftTestingAssertions()

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
        let data = try assertions.require(response.data(using: .utf8), file: file, line: line)
        return try assertions.require(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
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
        let requestLine = try assertions.require(String(data: requestData, encoding: .utf8), file: file, line: line)
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
        assertions.equal(envelope["ok"] as? Bool, true, raw, file: file, line: line)
        return try assertions.require(envelope["result"] as? [String: Any], raw, file: file, line: line)
    }

    private func v2Error(
        method: String,
        params: [String: Any] = [:],
        id: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let (raw, envelope) = try v2Envelope(method: method, params: params, id: id, file: file, line: line)
        assertions.equal(envelope["ok"] as? Bool, false, raw, file: file, line: line)
        return try assertions.require(envelope["error"] as? [String: Any], raw, file: file, line: line)
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
        let workspaces = try assertions.require(payload["workspaces"] as? [[String: Any]], file: file, line: line)
        assertions.isTrue(
            workspaces.contains { ($0["id"] as? String) == workspaceId.uuidString },
            "workspace.list should include \(workspaceId.uuidString)",
            file: file,
            line: line
        )
    }

    @Test func testReportPwdPathOptionKeepsDisplayLabelSeparateFromFilesystemDirectory() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
        let filesystemDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-report-pwd-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: filesystemDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: filesystemDirectory) }

        let displayLabel = "MyPackage  mainline"
        let response = TerminalController.shared.handleSocketLine(
            "report_pwd \"\(displayLabel)\" --path=\(filesystemDirectory.path) --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        assertions.equal(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        assertions.equal(workspace.currentDirectory, filesystemDirectory.path)
        assertions.equal(workspace.panelDirectories[panelId], filesystemDirectory.path)
        assertions.equal(workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: [panelId]), [displayLabel])
        assertions.equal(workspace.sidebarFinderDirectory(), filesystemDirectory.path)
    }

    @Test func testWorkspaceReorderManyRoutesByWorkspaceOwnerWhenWindowIsOmitted() throws {
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
        let firstB = try assertions.require(managerB.tabs.first)
        let secondB = managerB.addWorkspace(select: false, eagerLoadTerminal: false)
        let thirdB = managerB.addWorkspace(select: false, eagerLoadTerminal: false)

        let result = try v2Result(
            method: "workspace.reorder_many",
            params: [
                "workspace_ids": [thirdB.id.uuidString, firstB.id.uuidString]
            ]
        )

        assertions.equal(result["window_id"] as? String, windowBId.uuidString)
        assertions.equal(managerA.tabs.map(\.id), originalAOrder)
        assertions.equal(managerB.tabs.map(\.id), [thirdB.id, firstB.id, secondB.id])
    }

    @Test func testWorkspaceReorderManyRejectsEmptyOrderItems() throws {
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
        let first = try assertions.require(manager.tabs.first)
        let second = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let originalOrder = manager.tabs.map(\.id)

        let orderError = try v2Error(
            method: "workspace.reorder_many",
            params: [
                "order": "\(first.id.uuidString),,\(second.id.uuidString)"
            ]
        )
        assertions.equal(orderError["code"] as? String, "invalid_params")
        assertions.equal(manager.tabs.map(\.id), originalOrder)

        let arrayError = try v2Error(
            method: "workspace.reorder_many",
            params: [
                "workspace_ids": [first.id.uuidString, " ", second.id.uuidString]
            ]
        )
        assertions.equal(arrayError["code"] as? String, "invalid_params")
        assertions.equal(manager.tabs.map(\.id), originalOrder)
    }

    @Test func testSystemTreeWindowSelectorErrorsUseWindowContext() throws {
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
        assertions.equal(conflict["code"] as? String, "invalid_params")
        assertions.isTrue((conflict["message"] as? String)?.contains("Choose either --window") == true)
        let conflictData = try assertions.require(conflict["data"] as? [String: Any])
        assertions.equal(conflictData["window_id"] as? String, windowId.uuidString)
        assertions.isNil(conflictData["window_ref"])

        let missing = try v2Error(
            method: "system.tree",
            params: [
                "window_id": missingWindowId.uuidString,
                "workspace_id": UUID().uuidString,
            ]
        )
        assertions.equal(missing["code"] as? String, "not_found")
        assertions.isTrue((missing["message"] as? String)?.contains("cmux list-windows") == true)
        let missingData = try assertions.require(missing["data"] as? [String: Any])
        assertions.equal(missingData["window_id"] as? String, missingWindowId.uuidString)
        assertions.isNil(missingData["window_ref"])
    }

    @Test func testPaneFocusWindowSelectorRejectsPaneFromOtherWindow() throws {
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

        let workspace1 = try assertions.require(manager1.selectedWorkspace)
        let workspace2 = try assertions.require(manager2.selectedWorkspace)
        let surface2 = try assertions.require(workspace2.focusedPanelId)
        let pane2 = try assertions.require(workspace2.paneId(forPanelId: surface2)?.id)

        let error = try v2Error(
            method: "pane.focus",
            params: [
                "window_id": windowId1.uuidString,
                "pane_id": pane2.uuidString,
            ]
        )
        assertions.equal(error["code"] as? String, "not_found")
        assertions.equal(manager1.selectedTabId, workspace1.id)
        assertions.equal(manager2.selectedTabId, workspace2.id)
    }

    @Test func testUnresolvedWindowRefDoesNotFallBackToActiveWindow() throws {
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
        assertions.equal(error["code"] as? String, "unavailable")
    }

    @Test func testWorkspaceListRejectsWindowAliasInsteadOfDefaultWindowFallback() throws {
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

        let firstWorkspace = try assertions.require(firstManager.selectedWorkspace)
        let secondWorkspace = try assertions.require(secondManager.selectedWorkspace)

        let windowList = try v2Result(method: "window.list")
        let windows = try assertions.require(windowList["windows"] as? [[String: Any]])
        let secondWindowRef = try assertions.require(
            windows.first { ($0["id"] as? String) == secondWindowId.uuidString }?["ref"] as? String
        )

        let routedList = try v2Result(
            method: "workspace.list",
            params: ["window_id": secondWindowRef]
        )
        assertions.equal(routedList["window_id"] as? String, secondWindowId.uuidString)
        try assertWorkspaceListContains(routedList, workspaceId: secondWorkspace.id)
        let routedWorkspaces = try assertions.require(routedList["workspaces"] as? [[String: Any]])
        assertions.isFalse(routedWorkspaces.contains { ($0["id"] as? String) == firstWorkspace.id.uuidString })

        let error = try v2Error(
            method: "workspace.list",
            params: ["window": secondWindowRef]
        )
        assertions.equal(error["code"] as? String, "invalid_params")
        let data = try assertions.require(error["data"] as? [String: Any])
        assertions.equal(data["unsupported_param"] as? String, "window")
        assertions.equal(data["supported_param"] as? String, "window_id")
    }

    @Test func testWorkspaceCreateRejectsWindowAliasInsteadOfDefaultWindowFallback() throws {
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
        let windows = try assertions.require(windowList["windows"] as? [[String: Any]])
        let secondWindowRef = try assertions.require(
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

        assertions.equal(error["code"] as? String, "invalid_params")
        let data = try assertions.require(error["data"] as? [String: Any])
        assertions.equal(data["unsupported_param"] as? String, "window")
        assertions.equal(data["supported_param"] as? String, "window_id")
        assertions.equal(firstManager.tabs.count, firstCount)
        assertions.equal(secondManager.tabs.count, secondCount)
    }

    @Test func testWorkspaceListResolvesLiveSurfaceAfterMainWindowContextAssociationIsLost() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let terminalPanel = try assertions.require(workspace.focusedTerminalPanel)
        let surfaceId = terminalPanel.id
        assertions.isTrue(GhosttyApp.terminalSurfaceRegistry.surface(id: surfaceId) === terminalPanel.surface)
        assertions.equal(terminalPanel.surface.debugLastKnownWorkspaceId(), workspace.id)

        try assertWorkspaceListContains(try workspaceListPayload(surfaceId: surfaceId), workspaceId: workspace.id)

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        TerminalController.shared.setActiveTabManager(nil)

        try assertWorkspaceListContains(try workspaceListPayload(surfaceId: surfaceId), workspaceId: workspace.id)
    }

    @Test func testSurfaceResumeSetRejectsSurfaceOutsideExplicitWindow() throws {
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

        let secondWorkspace = try assertions.require(secondManager.selectedWorkspace)
        let secondPanelId = try assertions.require(secondWorkspace.focusedPanelId)
        let (raw, envelope) = try v2Envelope(
            method: "surface.resume.set",
            params: [
                "window_id": firstWindowId.uuidString,
                "surface_id": secondPanelId.uuidString,
                "command": "echo wrong-window"
            ]
        )

        assertions.equal(envelope["ok"] as? Bool, false, raw)
        assertions.isNil(secondWorkspace.surfaceResumeBinding(panelId: secondPanelId))
    }

    @Test func testSurfaceResumeRejectsMalformedSurfaceOrTabIdWithoutFocusedFallback() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
        assertions.isTrue(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(command: "echo keep", source: "test"),
            panelId: panelId
        ))

        for key in ["surface_id", "terminal_id", "tab_id"] {
            for method in ["surface.resume.set", "surface.resume.get", "surface.resume.clear"] {
                var params: [String: Any] = [
                    "window_id": windowId.uuidString,
                    key: "not-a-surface"
                ]
                if method == "surface.resume.set" {
                    params["command"] = "echo bad"
                }

                let (raw, envelope) = try v2Envelope(method: method, params: params)

                assertions.equal(envelope["ok"] as? Bool, false, raw)
                let error = try assertions.require(envelope["error"] as? [String: Any], raw)
                assertions.equal(error["code"] as? String, "invalid_params", raw)
                assertions.equal(workspace.surfaceResumeBinding(panelId: panelId)?.command, "echo keep")
            }
        }
    }

    @Test func testSurfaceResumeUsesTabIdAliasForTargetSurface() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let focusedPanelId = try assertions.require(workspace.focusedPanelId)
        let focusedPanel = try assertions.require(workspace.terminalPanel(for: focusedPanelId))
        let splitPanel = try assertions.require(workspace.newTerminalSplit(
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
        assertions.equal(setResult["surface_id"] as? String, splitPanel.id.uuidString)
        assertions.isNil(workspace.surfaceResumeBinding(panelId: focusedPanel.id))
        assertions.equal(
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
        assertions.equal(getResult["surface_id"] as? String, splitPanel.id.uuidString)
        let getBinding = try assertions.require(getResult["resume_binding"] as? [String: Any])
        assertions.equal(getBinding["checkpoint_id"] as? String, "alias-target")

        let clearResult = try v2Result(
            method: "surface.resume.clear",
            params: [
                "window_id": windowId.uuidString,
                "tab_id": splitPanel.id.uuidString,
                "checkpoint_id": "alias-target",
            ]
        )
        assertions.equal(clearResult["surface_id"] as? String, splitPanel.id.uuidString)
        assertions.equal(clearResult["cleared"] as? Bool, true)
        assertions.isNil(workspace.surfaceResumeBinding(panelId: splitPanel.id))
    }

    @Test func testSurfaceResumePayloadIncludesEnvironment() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
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
        let setBinding = try assertions.require(setResult["resume_binding"] as? [String: Any])
        let setEnvironment = try assertions.require(setBinding["environment"] as? [String: Any])
        assertions.equal(setEnvironment["EMPTY"] as? String, "")
        assertions.equal(setEnvironment["SPACED"] as? String, "  keep exact  ")
        assertions.isNil(setEnvironment["ANTHROPIC_API_KEY"])
        assertions.equal(setBinding["auto_resume"] as? Bool, false)
        workspace.restoredAgentLifecycle.setSnapshot(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: UUID().uuidString.lowercased(),
                workingDirectory: "/tmp/stale-agent",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "codex",
                    executablePath: "/opt/stale/codex",
                    arguments: ["/opt/stale/codex"],
                    workingDirectory: "/tmp/stale-agent"
                )
            ),
            panelId: panelId
        )

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let getBinding = try assertions.require(getResult["resume_binding"] as? [String: Any])
        let getEnvironment = try assertions.require(getBinding["environment"] as? [String: Any])
        assertions.equal(getEnvironment["EMPTY"] as? String, "")
        assertions.equal(getEnvironment["SPACED"] as? String, "  keep exact  ")
        assertions.isNil(getEnvironment["ANTHROPIC_API_KEY"])
        assertions.equal(getBinding["auto_resume"] as? Bool, false)
        let restoreRecord = try assertions.require(getResult["restore_record"] as? [String: Any])
        assertions.equal(restoreRecord["mode"] as? String, "direct")
        assertions.equal(restoreRecord["kind"] as? String, "command")
        assertions.isNil(restoreRecord["launch_command"] as? [String: Any])
        let legacyCommand = try assertions.require(restoreRecord["legacy_command"] as? String)
        assertions.isTrue(legacyCommand.contains("tmux attach -t dogfood"), legacyCommand)
        assertions.isTrue(legacyCommand.contains("SPACED=  keep exact  "), legacyCommand)
    }

    @Test func testManualAgentRestoreRecordSurvivesShellPreexecInvalidation() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
        let checkpointID = UUID().uuidString.lowercased()
        let workingDirectory = "/tmp/grok-manual-restore"
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "grok",
            executablePath: "/usr/local/bin/grok",
            arguments: ["/usr/local/bin/grok", "--no-alt-screen"],
            workingDirectory: workingDirectory
        )
        assertions.isTrue(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Grok",
                kind: "grok",
                command: "grok -r \(checkpointID) --no-alt-screen",
                cwd: workingDirectory,
                checkpointId: checkpointID,
                source: "agent-hook",
                launchCommand: launchCommand,
                autoResume: true
            ),
            panelId: panelId
        ))
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.restoredAgentLifecycle.setSnapshot(
            SessionRestorableAgentSnapshot(
                kind: .grok,
                sessionId: checkpointID,
                workingDirectory: workingDirectory,
                launchCommand: launchCommand
            ),
            panelId: panelId
        )
        workspace.restoredAgentLifecycle.setResumeState(.manualResumeAvailable, panelId: panelId)

        // Shell integration reports commandRunning before `cmux restore` starts.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        assertions.isNil(workspace.restoredAgentSnapshotsByPanelId[panelId])
        let retainedBinding = try assertions.require(workspace.surfaceResumeBinding(panelId: panelId))
        assertions.equal(retainedBinding.checkpointId, checkpointID)
        assertions.equal(retainedBinding.autoResume, false)

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let restoreRecord = try assertions.require(getResult["restore_record"] as? [String: Any])
        assertions.equal(restoreRecord["kind"] as? String, "grok")
        assertions.equal(restoreRecord["checkpoint_id"] as? String, checkpointID)
        let resumeBinding = try assertions.require(getResult["resume_binding"] as? [String: Any])
        assertions.equal(resumeBinding["auto_resume"] as? Bool, false)
    }

    @Test func testSurfaceRestoreRecordBootstrapsCommandOnlyLocalHermesBinding() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
        let checkpointID = UUID().uuidString.lowercased()
        assertions.isTrue(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "hermes-agent",
                command: "hermes --provider openai-codex --resume \(checkpointID)",
                cwd: "/tmp/hermes-legacy",
                checkpointId: checkpointID,
                source: "agent-hook",
                environment: ["CUSTOM_BASE_URL": "https://codex.example.test/v1"],
                autoResume: true
            ),
            panelId: panelId
        ))

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let restoreRecord = try assertions.require(getResult["restore_record"] as? [String: Any])
        assertions.equal(restoreRecord["kind"] as? String, "hermes-agent")
        assertions.equal(restoreRecord["checkpoint_id"] as? String, checkpointID)
        assertions.isNil(restoreRecord["launch_command"] as? [String: Any])
        // A binding-only record keeps the compatibility-shell path. Typed argv
        // is rebuilt only when a newer binding supersedes a stale snapshot.
        assertions.isNil(restoreRecord["prepared_arguments"] as? [String])
        let legacyCommand = try assertions.require(restoreRecord["legacy_command"] as? String)
        assertions.isTrue(
            legacyCommand.contains("config set model.provider"),
            legacyCommand
        )
        assertions.isTrue(
            legacyCommand.contains("config set model.base_url")
                && legacyCommand.contains("https://codex.example.test/v1"),
            legacyCommand
        )
        assertions.isTrue(
            legacyCommand.contains("config set model.api_mode"),
            legacyCommand
        )
        assertions.isTrue(
            legacyCommand.contains("--provider")
                && legacyCommand.contains("custom")
                && legacyCommand.contains(checkpointID),
            legacyCommand
        )
    }

    @Test func testSurfaceRestoreRecordPrefersNewerBindingOverStaleRestoredAgent() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
        let currentSessionID = UUID().uuidString.lowercased()
        let currentLaunch = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "/opt/current/codex",
            arguments: ["/opt/current/codex", "--model", "gpt-current"],
            workingDirectory: "/tmp/current",
            environment: [
                "CODEX_HOME": "/tmp/current-codex-home",
                "OPENAI_API_KEY": "must-not-cross-socket",
            ]
        )
        assertions.isTrue(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "codex resume \(currentSessionID)",
                cwd: "/tmp/current",
                checkpointId: currentSessionID,
                source: "agent-hook",
                launchCommand: currentLaunch,
                autoResume: true
            ),
            panelId: panelId
        ))

        let staleSessionID = UUID().uuidString.lowercased()
        workspace.restoredAgentLifecycle.setSnapshot(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: staleSessionID,
                workingDirectory: "/tmp/stale",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "codex",
                    executablePath: "/opt/stale/codex",
                    arguments: ["/opt/stale/codex", "--model", "gpt-stale"],
                    workingDirectory: "/tmp/stale",
                    environment: [
                        "CODEX_HOME": "/tmp/stale-codex-home",
                        "OPENAI_API_KEY": "must-not-cross-socket",
                    ]
                )
            ),
            panelId: panelId
        )

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let restoreRecord = try assertions.require(getResult["restore_record"] as? [String: Any])
        assertions.equal(restoreRecord["kind"] as? String, "codex")
        assertions.equal(restoreRecord["checkpoint_id"] as? String, currentSessionID)
        assertions.equal(restoreRecord["source"] as? String, "agent-hook")
        assertions.equal(restoreRecord["working_directory"] as? String, "/tmp/current")
        assertions.equal(
            restoreRecord["prepared_arguments_working_directory"] as? String,
            "/tmp/current"
        )
        let preparedArguments = try assertions.require(
            restoreRecord["prepared_arguments"] as? [String]
        )
        assertions.isTrue(
            preparedArguments.contains(currentSessionID),
            "\(preparedArguments)"
        )
        assertions.isFalse(
            preparedArguments.contains(staleSessionID),
            "\(preparedArguments)"
        )
        let launch = try assertions.require(restoreRecord["launch_command"] as? [String: Any])
        assertions.equal(launch["arguments"] as? [String], currentLaunch.arguments)
        let launchEnvironment = try assertions.require(launch["environment"] as? [String: Any])
        assertions.equal(
            launchEnvironment["CODEX_HOME"] as? String,
            "/tmp/current-codex-home"
        )
        assertions.isNil(launchEnvironment["OPENAI_API_KEY"])
        let resumeBinding = try assertions.require(getResult["resume_binding"] as? [String: Any])
        let resumeLaunch = try assertions.require(resumeBinding["launch_command"] as? [String: Any])
        let resumeLaunchEnvironment = try assertions.require(
            resumeLaunch["environment"] as? [String: Any]
        )
        assertions.equal(
            resumeLaunchEnvironment["CODEX_HOME"] as? String,
            "/tmp/current-codex-home"
        )
        assertions.isNil(resumeLaunchEnvironment["OPENAI_API_KEY"])
        let legacyCommand = try assertions.require(restoreRecord["legacy_command"] as? String)
        assertions.isTrue(legacyCommand.contains("codex resume \(currentSessionID)"))
        assertions.isFalse(legacyCommand.contains(staleSessionID), legacyCommand)

        let ompSessionID = UUID().uuidString.lowercased()
        assertions.isTrue(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "OMP",
                command: "omp --session \(ompSessionID)",
                checkpointId: ompSessionID,
                source: "agent-hook",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "omp",
                    executablePath: "/opt/current/omp",
                    arguments: ["/opt/current/omp", "--session", ompSessionID],
                    environment: [
                        "PATH": "/opt/omp/bin:/usr/bin:/bin",
                        "OPENAI_API_KEY": "must-not-cross-socket",
                    ]
                ),
                autoResume: true
            ),
            panelId: panelId
        ))
        let ompResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let ompRecord = try assertions.require(ompResult["restore_record"] as? [String: Any])
        let ompLaunch = try assertions.require(ompRecord["launch_command"] as? [String: Any])
        let ompEnvironment = try assertions.require(ompLaunch["environment"] as? [String: Any])
        assertions.equal(ompEnvironment["PATH"] as? String, "/opt/omp/bin:/usr/bin:/bin")
        assertions.isNil(ompEnvironment["OPENAI_API_KEY"])

        assertions.isTrue(workspace.clearSurfaceResumeBinding(panelId: panelId))
        let snapshotResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let snapshotRecord = try assertions.require(
            snapshotResult["restore_record"] as? [String: Any]
        )
        let snapshotLaunch = try assertions.require(
            snapshotRecord["launch_command"] as? [String: Any]
        )
        let snapshotEnvironment = try assertions.require(
            snapshotLaunch["environment"] as? [String: Any]
        )
        assertions.equal(
            snapshotEnvironment["CODEX_HOME"] as? String,
            "/tmp/stale-codex-home"
        )
        assertions.isNil(snapshotEnvironment["OPENAI_API_KEY"])
    }

    @Test func testSurfaceRestoreRecordAppliesBindingEnvironmentAndRestoreTimeCwd() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
        let sessionID = "cwd-session"
        let savedDirectory = "/tmp/saved-project"
        let restoredDirectory = "/tmp/restored-project"
        let launch = AgentLaunchCommandSnapshot(
            launcher: "cwd-agent",
            executablePath: "/opt/cwd-agent",
            arguments: ["/opt/cwd-agent"],
            workingDirectory: savedDirectory,
            environment: ["RESTORE_OVERRIDE": "captured"]
        )
        assertions.isTrue(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "cwd-agent",
                command: "/opt/cwd-agent --cwd \(savedDirectory) --session \(sessionID)",
                cwd: savedDirectory,
                checkpointId: sessionID,
                source: "agent-hook",
                environment: ["RESTORE_OVERRIDE": "binding"],
                launchCommand: launch,
                autoResume: true
            ),
            panelId: panelId
        ))
        workspace.restoredAgentLifecycle.setSnapshot(
            SessionRestorableAgentSnapshot(
                kind: .custom("cwd-agent"),
                sessionId: sessionID,
                workingDirectory: savedDirectory,
                launchCommand: launch,
                registration: CmuxVaultAgentRegistration(
                    id: "cwd-agent",
                    name: "CWD Agent",
                    detect: CmuxVaultAgentDetectRule(processName: "cwd-agent"),
                    sessionIdSource: .argvOption("--session"),
                    resumeCommand: "{{executable}} --cwd {{cwd}} --session {{sessionId}}",
                    cwd: .preserve
                )
            ),
            panelId: panelId
        )
        workspace.restoredResumeSessionWorkingDirectoriesByPanelId[panelId] =
            restoredDirectory

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let restoreRecord = try assertions.require(getResult["restore_record"] as? [String: Any])
        assertions.equal(restoreRecord["working_directory"] as? String, restoredDirectory)
        let environment = try assertions.require(restoreRecord["environment"] as? [String: Any])
        assertions.equal(environment["RESTORE_OVERRIDE"] as? String, "binding")
        let preparedArguments = try assertions.require(
            restoreRecord["prepared_arguments"] as? [String]
        )
        assertions.isTrue(preparedArguments.contains(restoredDirectory), "\(preparedArguments)")
        assertions.isFalse(preparedArguments.contains(savedDirectory), "\(preparedArguments)")

        let replacementSessionID = "replacement-current-session"
        let replacementDirectory = "/tmp/replacement-project"
        let replacementLaunch = AgentLaunchCommandSnapshot(
            launcher: "cwd-agent",
            executablePath: "/opt/cwd-agent",
            arguments: ["/opt/cwd-agent"],
            workingDirectory: replacementDirectory
        )
        assertions.isTrue(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "cwd-agent",
                command: "/opt/cwd-agent --cwd \(replacementDirectory) --session \(replacementSessionID)",
                cwd: replacementDirectory,
                checkpointId: replacementSessionID,
                source: "agent-hook",
                launchCommand: replacementLaunch,
                autoResume: true
            ),
            panelId: panelId
        ))

        let replacementResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let replacementRecord = try assertions.require(
            replacementResult["restore_record"] as? [String: Any]
        )
        assertions.equal(
            replacementRecord["working_directory"] as? String,
            replacementDirectory
        )
        assertions.notEqual(
            replacementRecord["working_directory"] as? String,
            restoredDirectory
        )
        assertions.isNil(replacementRecord["prepared_arguments"] as? [String])
        let replacementLegacyCommand = try assertions.require(
            replacementRecord["legacy_command"] as? String
        )
        assertions.isTrue(
            replacementLegacyCommand.contains(replacementSessionID),
            replacementLegacyCommand
        )
        assertions.isFalse(
            replacementLegacyCommand.contains(sessionID),
            replacementLegacyCommand
        )
    }

    @Test func testSurfaceResumeSetCannotEnableAutoResumeFromSocket() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
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

        let binding = try assertions.require(result["resume_binding"] as? [String: Any])
        assertions.equal(binding["auto_resume"] as? Bool, false)
        assertions.equal(binding["source"] as? String, "manual")
        assertions.equal(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume, false)
        assertions.equal(workspace.surfaceResumeBinding(panelId: panelId)?.source, "manual")
    }

    @Test func testSurfaceResumeSetAllowsAgentHookAutoResume() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
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

        let binding = try assertions.require(result["resume_binding"] as? [String: Any])
        assertions.equal(binding["auto_resume"] as? Bool, true)
        assertions.equal(binding["source"] as? String, "agent-hook")
        assertions.equal(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume, true)
        assertions.equal(workspace.surfaceResumeBinding(panelId: panelId)?.source, "agent-hook")
    }

    @Test func testSurfaceResumeClearCheckpointGuardKeepsDifferentBinding() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let panelId = try assertions.require(workspace.focusedPanelId)
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

        assertions.equal(clearResult["cleared"] as? Bool, false)
        assertions.equal(workspace.surfaceResumeBinding(panelId: panelId)?.checkpointId, "new-session")
    }

    @Test func testIssue2907TabManagerDependentSocketCommandsRecoverLiveSurfaceContext() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let terminalPanel = try assertions.require(workspace.focusedTerminalPanel)
        let surfaceId = terminalPanel.id
        assertions.isTrue(GhosttyApp.terminalSurfaceRegistry.surface(id: surfaceId) === terminalPanel.surface)
        assertions.equal(terminalPanel.surface.debugLastKnownWorkspaceId(), workspace.id)

        try assertWorkspaceListContains(try v2Result(method: "workspace.list"), workspaceId: workspace.id)
        let baselineTree = try v2Result(method: "system.tree")
        let baselineWindows = try assertions.require(baselineTree["windows"] as? [[String: Any]])
        assertions.isTrue(baselineWindows.contains { ($0["id"] as? String) == windowId.uuidString })

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        TerminalController.shared.setActiveTabManager(nil)

        let ping = try v2Result(method: "system.ping")
        assertions.equal(ping["pong"] as? Bool, true)
        _ = try v2Result(method: "system.capabilities")

        let tree = try v2Result(method: "system.tree")
        let debugTerminals = try v2Result(method: "debug.terminals")
        let terminals = try assertions.require(debugTerminals["terminals"] as? [[String: Any]])
        let originalTerminal = try assertions.require(
            terminals.first { ($0["surface_id"] as? String) == surfaceId.uuidString }
        )
        assertions.equal(originalTerminal["mapped"] as? Bool, true)
        assertions.equal(originalTerminal["workspace_id"] as? String, workspace.id.uuidString)
        assertions.equal(originalTerminal["last_known_workspace_id"] as? String, workspace.id.uuidString)

        let recoveredTreeWindows = try assertions.require(tree["windows"] as? [[String: Any]])
        assertions.isTrue(
            recoveredTreeWindows.contains { ($0["id"] as? String) == windowId.uuidString },
            "system.tree should not report an empty world while a live terminal surface is still associated with its workspace"
        )

        let currentWindow = try v2Result(method: "window.current")
        assertions.equal(currentWindow["window_id"] as? String, windowId.uuidString)

        let currentWorkspace = try v2Result(method: "workspace.current")
        assertions.equal(currentWorkspace["workspace_id"] as? String, workspace.id.uuidString)

        let workspaceList = try v2Result(method: "workspace.list")
        try assertWorkspaceListContains(workspaceList, workspaceId: workspace.id)

        let workspaceListBySurface = try v2Result(method: "workspace.list", params: ["surface_id": surfaceId.uuidString])
        try assertWorkspaceListContains(workspaceListBySurface, workspaceId: workspace.id)

        let surfaces = try v2Result(method: "surface.list", params: ["surface_id": surfaceId.uuidString])
        assertions.equal(surfaces["workspace_id"] as? String, workspace.id.uuidString)

        let currentSurface = try v2Result(method: "surface.current", params: ["surface_id": surfaceId.uuidString])
        assertions.equal(currentSurface["workspace_id"] as? String, workspace.id.uuidString)

        let panes = try v2Result(method: "pane.list", params: ["surface_id": surfaceId.uuidString])
        assertions.equal(panes["workspace_id"] as? String, workspace.id.uuidString)

        let health = try v2Result(method: "surface.health", params: ["surface_id": surfaceId.uuidString])
        assertions.equal(health["workspace_id"] as? String, workspace.id.uuidString)

        let split = try v2Result(
            method: "surface.split",
            params: [
                "surface_id": surfaceId.uuidString,
                "direction": "right",
                "focus": false
            ]
        )
        assertions.isNotNil(split["surface_id"] as? String)
    }

    @Test func testIssue2907NoTargetCommandsPreferKeyRecoveredWindowOverRegisteredWindow() throws {
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

        let recoveredWorkspace = try assertions.require(recoveredManager.selectedWorkspace)
        let recoveredTerminal = try assertions.require(recoveredWorkspace.focusedTerminalPanel)
        assertions.isTrue(GhosttyApp.terminalSurfaceRegistry.surface(id: recoveredTerminal.id) === recoveredTerminal.surface)

        app.unregisterMainWindowContextForTesting(windowId: recoveredWindowId)
        TerminalController.shared.setActiveTabManager(nil)

        let currentWindow = try v2Result(method: "window.current")
        assertions.equal(currentWindow["window_id"] as? String, recoveredWindowId.uuidString)

        let currentWorkspace = try v2Result(method: "workspace.current")
        assertions.equal(currentWorkspace["workspace_id"] as? String, recoveredWorkspace.id.uuidString)
    }

    @Test func testIssue2907BonsplitTabLookupUsesRecoveredRoute() throws {
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

        let workspace = try assertions.require(manager.selectedWorkspace)
        let terminalPanel = try assertions.require(workspace.focusedTerminalPanel)
        let bonsplitTabId = try assertions.require(workspace.surfaceIdFromPanelId(terminalPanel.id)?.uuid)

        app.unregisterMainWindowContextForTesting(windowId: windowId)
        TerminalController.shared.setActiveTabManager(nil)

        let located = try assertions.require(app.locateBonsplitSurface(tabId: bonsplitTabId))
        assertions.equal(located.windowId, windowId)
        assertions.equal(located.workspaceId, workspace.id)
        assertions.equal(located.panelId, terminalPanel.id)
        assertions.isTrue(located.tabManager === manager)
    }

    @Test func testRecoveredRouteUsesRegisteredOwnerWithoutTerminalHeuristics() throws {
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

        let terminalWorkspace = try assertions.require(terminalManager.selectedWorkspace)
        let terminalPanel = try assertions.require(terminalWorkspace.focusedTerminalPanel)
        assertions.isTrue(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)

        let browserOnlyWorkspace = try assertions.require(browserOnlyManager.selectedWorkspace)
        let browserOnlyTerminal = try assertions.require(browserOnlyWorkspace.focusedTerminalPanel)
        let browserPaneId = try assertions.require(browserOnlyWorkspace.bonsplitController.allPaneIds.first)
        let browserPanel = try assertions.require(
            browserOnlyWorkspace.newBrowserSurface(
                inPane: browserPaneId,
                url: URL(string: "https://example.com/browser-only"),
                focus: true,
                creationPolicy: .restoration
            )
        )
        assertions.isTrue(browserOnlyWorkspace.closePanel(browserOnlyTerminal.id, force: true))
        assertions.isNotNil(browserOnlyWorkspace.panels[browserPanel.id])
        assertions.isFalse(browserOnlyWorkspace.panels.values.contains { $0 is TerminalPanel })

        app.unregisterMainWindowContextForTesting(windowId: browserOnlyWindowId)

        assertions.isTrue(app.tabManagerFor(windowId: browserOnlyWindowId) === browserOnlyManager)
        assertions.isTrue(app.listMainWindowSummaries().contains { $0.windowId == browserOnlyWindowId })
        assertions.isTrue(app.tabManagerFor(windowId: terminalWindowId) === terminalManager)
    }

    @Test func testWorkspaceCreationContinuesAfterStaleActiveContextDiscard() throws {
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

        let unwrappedCreatedWorkspaceId = try assertions.require(createdWorkspace).id
        assertions.equal(liveManager.tabs.count, originalLiveWorkspaceCount + 1)
        assertions.isTrue(liveManager.tabs.contains { $0.id == unwrappedCreatedWorkspaceId })
    }

    @Test func testPaneBreakSuccessIncludesDestinationPaneReference() throws {
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

        let sourceWorkspace = try assertions.require(manager.selectedWorkspace)
        let sourcePanel = try assertions.require(sourceWorkspace.focusedTerminalPanel)
        let splitPanel = try assertions.require(sourceWorkspace.newTerminalSplit(
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

        let destinationWorkspaceIdString = try assertions.require(payload["workspace_id"] as? String)
        let destinationPaneIdString = try assertions.require(payload["pane_id"] as? String)
        let destinationPaneRef = try assertions.require(payload["pane_ref"] as? String)
        let destinationWorkspace = try assertions.require(
            manager.tabs.first { $0.id.uuidString == destinationWorkspaceIdString }
        )

        assertions.equal(payload["window_id"] as? String, windowId.uuidString)
        assertions.equal(payload["surface_id"] as? String, splitPanel.id.uuidString)
        assertions.isFalse(destinationPaneIdString.isEmpty)
        assertions.isTrue(destinationPaneRef.hasPrefix("pane:"))
        assertions.equal(
            destinationWorkspace.paneId(forPanelId: splitPanel.id)?.id.uuidString,
            destinationPaneIdString
        )
    }

    @Test func testSurfaceResumeSetUsesLiveSurfaceWhenWorkspaceIdIsOmittedAfterMove() throws {
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

        let sourceWorkspace = try assertions.require(manager.selectedWorkspace)
        let sourcePanel = try assertions.require(sourceWorkspace.focusedTerminalPanel)
        let splitPanel = try assertions.require(sourceWorkspace.newTerminalSplit(
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
        let destinationWorkspaceId = try assertions.require(moved["workspace_id"] as? String)
        let destinationWorkspace = try assertions.require(
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

        assertions.isNil(sourceWorkspace.surfaceResumeBinding(panelId: splitPanel.id))
        assertions.equal(
            destinationWorkspace.surfaceResumeBinding(panelId: splitPanel.id)?.command,
            "tmux attach -t moved"
        )
    }

    @Test func testSurfaceResumeSetRejectsMismatchedWorkspaceScopeAfterMove() throws {
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

        let sourceWorkspace = try assertions.require(manager.selectedWorkspace)
        let sourcePanel = try assertions.require(sourceWorkspace.focusedTerminalPanel)
        let splitPanel = try assertions.require(sourceWorkspace.newTerminalSplit(
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
        let destinationWorkspaceId = try assertions.require(moved["workspace_id"] as? String)
        let destinationWorkspace = try assertions.require(
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

        assertions.equal(envelope["ok"] as? Bool, false, raw)
        assertions.isNil(sourceWorkspace.surfaceResumeBinding(panelId: splitPanel.id))
        assertions.isNil(destinationWorkspace.surfaceResumeBinding(panelId: splitPanel.id))
    }
}
