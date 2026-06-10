import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Workspace/surface close, recently-closed history, and browser open split
extension TerminalControllerSocketSecurityTests {
    func testWorkspaceCloseRejectsPinnedWorkspace() async throws {
        let socketPath = makeSocketPath("close-pinned")
        let manager = TabManager()
        let pinnedWorkspace = manager.addWorkspace(select: false)
        manager.setPinned(pinnedWorkspace, pinned: true)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: "workspace.close",
                        params: ["workspace_id": pinnedWorkspace.id.uuidString],
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(error["code"] as? String, "protected")

        let data = try XCTUnwrap(error["data"] as? [String: Any], "Expected error data payload")
        XCTAssertEqual(data["workspace_id"] as? String, pinnedWorkspace.id.uuidString)
        XCTAssertEqual(data["pinned"] as? Bool, true)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }))
    }

    func testV2SurfaceCloseCommandsRecordRecentlyClosedHistory() throws {
        ClosedItemHistoryStore.shared.removeAll()
        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        BrowserAvailabilitySettings.setDisabled(true)
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            if let previousBrowserDisabled {
                defaults.set(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            }
            TerminalController.shared.setActiveTabManager(nil)
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let terminalPanel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true))
        workspace.setPanelCustomTitle(panelId: terminalPanel.id, title: "Socket Terminal")
        let browserPanel = try XCTUnwrap(workspace.newBrowserSurface(
            inPane: pane,
            focus: true,
            creationPolicy: .restoration
        ))
        workspace.setPanelCustomTitle(panelId: browserPanel.id, title: "Socket Browser")
        TerminalController.shared.setActiveTabManager(manager)

        let terminalClose = try handleV2Request(
            method: "surface.close",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": terminalPanel.id.uuidString
            ]
        )
        XCTAssertEqual(terminalClose["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(terminalClose)")
        XCTAssertNil(workspace.panels[terminalPanel.id])

        let browserClose = try handleV2Request(
            method: "browser.tab.close",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": browserPanel.id.uuidString
            ]
        )
        XCTAssertEqual(browserClose["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(browserClose)")
        XCTAssertNil(workspace.panels[browserPanel.id])

        XCTAssertEqual(
            ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title),
            ["Socket Browser", "Socket Terminal"]
        )
    }

    func testBrowserOpenSplitDoesNotExternallyOpenDiffViewerWhenBrowserDisabled() throws {
        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        BrowserAvailabilitySettings.setDisabled(true)
        defer {
            if let previousBrowserDisabled {
                defaults.set(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            }
            TerminalController.shared.setActiveTabManager(nil)
        }

        TerminalController.shared.setActiveTabManager(TabManager())
        let token = UUID().uuidString.lowercased()
        let response = try handleV2Request(
            method: "browser.open_split",
            params: [
                "url": "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/diff.html",
                "diff_viewer_token": token
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(error["code"] as? String, "browser_disabled")
    }

    func testLegacyCloseSurfaceCommandRecordsRecentlyClosedHistory() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            TerminalController.shared.setActiveTabManager(nil)
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true))
        workspace.setPanelCustomTitle(panelId: panel.id, title: "Legacy Socket Terminal")
        TerminalController.shared.setActiveTabManager(manager)

        let response = TerminalController.shared.handleSocketLine("close_surface \(panel.id.uuidString)")

        XCTAssertEqual(response, "OK")
        XCTAssertNil(workspace.panels[panel.id])
        XCTAssertEqual(
            ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title),
            ["Legacy Socket Terminal"]
        )
    }

}
