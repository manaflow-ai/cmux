import XCTest
import AppKit

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
        XCTAssertTrue(TerminalSurfaceRegistry.shared.surface(id: surfaceId) === terminalPanel.surface)
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
        XCTAssertTrue(TerminalSurfaceRegistry.shared.surface(id: recoveredTerminal.id) === recoveredTerminal.surface)

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
        XCTAssertTrue(TerminalSurfaceRegistry.shared.surface(id: terminalPanel.id) === terminalPanel.surface)

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
        let createdWorkspaceId = app.addWorkspaceInPreferredMainWindow(
            shouldBringToFront: false,
            debugSource: "test.issue2907.staleActiveContext"
        )

        let unwrappedCreatedWorkspaceId = try XCTUnwrap(createdWorkspaceId)
        XCTAssertEqual(liveManager.tabs.count, originalLiveWorkspaceCount + 1)
        XCTAssertTrue(liveManager.tabs.contains { $0.id == unwrappedCreatedWorkspaceId })
    }
}
