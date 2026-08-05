import AppKit
import CmuxControlSocket
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceCreateHandleMintingTests {
    @Test
    func workspaceCreateMintsOnlyReturnedHandlesInsteadOfRefreshingAllWindows() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousHandles = TerminalController.shared.controlCommandCoordinator.handles
        let app = AppDelegate()
        AppDelegate.shared = app
        TerminalController.shared.controlCommandCoordinator.handles = ControlHandleRegistry()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            TerminalController.shared.controlCommandCoordinator.handles = previousHandles
            AppDelegate.shared = previousAppDelegate
        }

        let targetWindowID = UUID()
        let unrelatedWindowID = UUID()
        let targetWindow = makeMainWindow(id: targetWindowID)
        let unrelatedWindow = makeMainWindow(id: unrelatedWindowID)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: targetWindowID)
            app.unregisterMainWindowContextForTesting(windowId: unrelatedWindowID)
            targetWindow.orderOut(nil)
            unrelatedWindow.orderOut(nil)
        }

        let targetManager = TabManager(autoWelcomeIfNeeded: false)
        let unrelatedManager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            targetWindow,
            windowId: targetWindowID,
            tabManager: targetManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            unrelatedWindow,
            windowId: unrelatedWindowID,
            tabManager: unrelatedManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(targetManager)

        let result = try v2Result(
            method: "workspace.create",
            params: [
                "window_id": targetWindowID.uuidString,
                "focus": false,
            ]
        )

        #expect(result["window_ref"] as? String == "window:1")
        #expect(result["workspace_ref"] as? String == "workspace:1")
        #expect(result["surface_ref"] as? String == "surface:1")
    }

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

    private func v2Result(
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let requestData = try JSONSerialization.data(withJSONObject: [
            "id": method,
            "method": method,
            "params": params,
        ])
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(raw.data(using: .utf8))
        let envelope = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        #expect(envelope["ok"] as? Bool == true, Comment(rawValue: raw))
        return try #require(envelope["result"] as? [String: Any])
    }
}
