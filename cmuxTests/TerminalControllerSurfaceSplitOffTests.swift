import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalControllerSurfaceSplitOffTests: XCTestCase {
    func testSurfaceSplitOffRejectsOnlyTabSourcePane() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
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
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let sourcePane = try XCTUnwrap(workspace.paneId(forPanelId: terminalPanel.id))
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: sourcePane).count, 1)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 1)

        let envelope = try v2Envelope(
            method: "surface.split_off",
            params: [
                "surface_id": terminalPanel.id.uuidString,
                "direction": "right",
                "focus": false
            ]
        )

        XCTAssertEqual(envelope["ok"] as? Bool, false)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_state")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["surface_id"] as? String, terminalPanel.id.uuidString)
        XCTAssertEqual(data["pane_id"] as? String, sourcePane.id.uuidString)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: sourcePane).count, 1)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 1)
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

    private func v2Envelope(
        method: String,
        params: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try XCTUnwrap(String(data: requestData, encoding: .utf8), file: file, line: line)
        let response = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try XCTUnwrap(response.data(using: .utf8), file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any], file: file, line: line)
    }
}
