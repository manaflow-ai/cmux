import AppKit
import Bonsplit
import CmuxTerminal
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateSurfaceResumeTerminalIdTests: XCTestCase {
    func testSurfaceResumeUsesTerminalIdAliasForTargetSurface() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

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
        let focusedPanel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let splitPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: focusedPanel.id,
            orientation: .horizontal,
            focus: false
        ))

        let setResult = try v2Result(method: "surface.resume.set", params: [
            "window_id": windowId.uuidString,
            "terminal_id": splitPanel.id.uuidString,
            "command": "codex resume terminal-target",
            "checkpoint_id": "terminal-target",
        ])
        XCTAssertEqual(setResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: focusedPanel.id))
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: splitPanel.id)?.command, "codex resume terminal-target")

        let getResult = try v2Result(method: "surface.resume.get", params: [
            "window_id": windowId.uuidString,
            "terminal_id": splitPanel.id.uuidString,
        ])
        XCTAssertEqual(getResult["surface_id"] as? String, splitPanel.id.uuidString)
        let getBinding = try XCTUnwrap(getResult["resume_binding"] as? [String: Any])
        XCTAssertEqual(getBinding["checkpoint_id"] as? String, "terminal-target")

        let clearResult = try v2Result(method: "surface.resume.clear", params: [
            "window_id": windowId.uuidString,
            "terminal_id": splitPanel.id.uuidString,
            "checkpoint_id": "terminal-target",
        ])
        XCTAssertEqual(clearResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertEqual(clearResult["cleared"] as? Bool, true)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: splitPanel.id))
    }

    func testTerminalContextMenuSetStatusAndClearResumeCommand() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

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
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let surfaceView = panel.hostedView.surfaceView

        XCTAssertEqual(surfaceView.currentSurfaceResumeContextMenuState(), .unbound)

        let unboundMenu = NSMenu()
        surfaceView.appendCurrentSurfaceContextMenuItems(to: unboundMenu)
        let resumeCommandsItem = try XCTUnwrap(unboundMenu.items.first)
        XCTAssertEqual(resumeCommandsItem.title, "Resume Commands")
        XCTAssertEqual(
            try XCTUnwrap(resumeCommandsItem.submenu).items.map(\.title),
            ["Set"]
        )

        let command = "tmux attach -t work"
        guard case .result(let setSnapshot) =
            surfaceView.setCurrentSurfaceResumeBindingFromContextMenu(command: command) else {
            return XCTFail("Expected native resume binding set to succeed")
        }
        XCTAssertEqual(setSnapshot.binding?.command, command)
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panel.id)?.source, "manual")
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panel.id)?.autoResume, false)
        XCTAssertEqual(
            surfaceView.currentSurfaceResumeContextMenuState(),
            .ordinary(command: command)
        )

        let boundMenu = NSMenu()
        surfaceView.appendCurrentSurfaceContextMenuItems(to: boundMenu)
        let restorableItem = try XCTUnwrap(boundMenu.items.first)
        XCTAssertEqual(restorableItem.title, "Resume Commands")
        let submenu = try XCTUnwrap(restorableItem.submenu)
        XCTAssertEqual(
            submenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "tmux attach -t work",
                "Edit",
                "Clear",
            ]
        )
        XCTAssertFalse(submenu.items[0].isEnabled)
        XCTAssertEqual(submenu.items[0].toolTip, command)

        guard case .result(let clearSnapshot) =
            surfaceView.clearCurrentSurfaceResumeBindingFromContextMenu() else {
            return XCTFail("Expected native resume binding clear to succeed")
        }
        XCTAssertTrue(clearSnapshot.cleared)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: panel.id))
        XCTAssertEqual(surfaceView.currentSurfaceResumeContextMenuState(), .unbound)
    }

    func testTerminalContextMenuKeepsAgentResumeManagedSeparately() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

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
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let surfaceView = panel.hostedView.surfaceView
        let command = "codex resume managed-session"

        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    kind: "codex",
                    command: command,
                    checkpointId: "managed-session",
                    source: "agent-hook",
                    autoResume: true
                ),
                panelId: panel.id
            )
        )

        XCTAssertEqual(surfaceView.currentSurfaceResumeContextMenuState(), .agentManaged)
        let menu = NSMenu()
        XCTAssertFalse(surfaceView.appendCurrentSurfaceResumeMenuItems(to: menu))
        XCTAssertTrue(menu.items.isEmpty)

        if case .result =
            surfaceView.setCurrentSurfaceResumeBindingFromContextMenu(command: "echo replacement") {
            XCTFail("Native ordinary-terminal action replaced an agent resume binding")
        }
        if case .result = surfaceView.clearCurrentSurfaceResumeBindingFromContextMenu() {
            XCTFail("Native ordinary-terminal action cleared an agent resume binding")
        }
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panel.id)?.command, command)
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panel.id)?.source, "agent-hook")
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

    private func v2Result(method: String, params: [String: Any]) throws -> [String: Any] {
        let request = ["id": method, "method": method, "params": params] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try XCTUnwrap(String(data: data, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try XCTUnwrap(raw.data(using: .utf8))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(envelope["ok"] as? Bool, true, raw)
        return try XCTUnwrap(envelope["result"] as? [String: Any], raw)
    }
}
