import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Notification create and pane startup notification suppression
extension TerminalControllerSocketSecurityTests {
    func testNotificationCreateUsesExplicitSurfaceIDWhenProvided() async throws {
        let socketPath = makeSocketPath("notify-surface")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }
        guard let targetPanel = workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.focusPanel(focusedPanelId)

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
                        method: "notification.create",
                        params: [
                            "workspace_id": workspace.id.uuidString,
                            "surface_id": targetPanel.id.uuidString,
                            "title": "Targeted"
                        ],
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(result["surface_id"] as? String, targetPanel.id.uuidString)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: targetPanel.id))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testPaneCreateStartupEnvironmentMarksManagedSubagentForRawNotificationSuppression() async throws {
        let socketPath = makeSocketPath("pane-env")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)
        let defaults = UserDefaults.standard
        let previousSuppressionDefault = defaults.object(forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)

        defaults.set(true, forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            if let previousSuppressionDefault {
                defaults.set(previousSuppressionDefault, forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
            } else {
                defaults.removeObject(forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
            }
        }

        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertFalse(workspace.suppressesRawTerminalNotification(panelId: sourcePanelId))

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "pane.create",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": sourcePanelId.uuidString,
                "direction": "right",
                "startup_environment": [
                    "CMUX_AGENT_MANAGED_SUBAGENT": "1"
                ]
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        let newSurfaceIDString = try XCTUnwrap(result["surface_id"] as? String)
        let newSurfaceID = try XCTUnwrap(UUID(uuidString: newSurfaceIDString))
        let newPanel = try XCTUnwrap(workspace.panels[newSurfaceID] as? TerminalPanel)

        XCTAssertEqual(newPanel.surface.startupEnvironmentValue("CMUX_AGENT_MANAGED_SUBAGENT"), "1")
        XCTAssertTrue(workspace.suppressesRawTerminalNotification(panelId: newSurfaceID))
        XCTAssertFalse(workspace.suppressesRawTerminalNotification(panelId: sourcePanelId))
    }

}
