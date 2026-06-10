import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Surface ID validation and surface relay RPC targeting
extension TerminalControllerSocketSecurityTests {
    func testDebugTextBoxEndpointsRejectBlankSurfaceID() throws {
#if DEBUG
        TerminalController.shared.setActiveTabManager(TabManager())
        defer { TerminalController.shared.setActiveTabManager(nil) }

        let requests: [(method: String, params: [String: Any], id: Int)] = [
            ("debug.textbox.inline_fixture", ["surface_id": "   "], 1),
            ("debug.textbox.interact", ["surface_id": "   ", "action": "select"], 2)
        ]

        for request in requests {
            let payload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": request.id,
                "method": request.method,
                "params": request.params
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let line = try XCTUnwrap(String(data: data, encoding: .utf8))
            let responseText = TerminalController.shared.handleSocketLine(line)
            let responseData = try XCTUnwrap(responseText.data(using: .utf8))
            let response = try XCTUnwrap(
                JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                "Unexpected JSON-RPC response: \(responseText)"
            )
            XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
            XCTAssertEqual(error["message"] as? String, "surface_id cannot be empty")
        }
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testSurfaceRelayRPCsReturnResolvedFocusedSurfaceWhenSurfaceIDOmitted() async throws {
        let socketPath = makeSocketPath("relay-fallback")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let reportTTYResponse = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "tty_name": "ttys999"
            ],
            to: socketPath
        )

        XCTAssertEqual(reportTTYResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(reportTTYResponse)")
        let reportTTYResult = try XCTUnwrap(reportTTYResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(reportTTYResponse)")
        XCTAssertEqual(reportTTYResult["surface_id"] as? String, focusedPanelId.uuidString)
        XCTAssertEqual(workspace.surfaceTTYNames[focusedPanelId], "ttys999")

        let portsKickResponse = try await sendV2RequestAsync(
            method: "surface.ports_kick",
            params: ["workspace_id": workspace.id.uuidString],
            to: socketPath
        )

        XCTAssertEqual(portsKickResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(portsKickResponse)")
        let portsKickResult = try XCTUnwrap(portsKickResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(portsKickResponse)")
        XCTAssertEqual(portsKickResult["surface_id"] as? String, focusedPanelId.uuidString)
    }

    func testSurfaceRelayRPCsRejectExplicitUnknownSurfaceID() async throws {
        let socketPath = makeSocketPath("relay-invalid")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let unknownSurfaceId = UUID()

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let reportTTYResponse = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": unknownSurfaceId.uuidString,
                "tty_name": "ttys999"
            ],
            to: socketPath
        )

        XCTAssertEqual(reportTTYResponse["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(reportTTYResponse)")
        let reportTTYError = try XCTUnwrap(reportTTYResponse["error"] as? [String: Any], "Unexpected JSON-RPC response: \(reportTTYResponse)")
        XCTAssertEqual(reportTTYError["code"] as? String, "not_found")
        let reportTTYData = try XCTUnwrap(reportTTYError["data"] as? [String: Any], "Expected error data payload")
        XCTAssertEqual(reportTTYData["surface_id"] as? String, unknownSurfaceId.uuidString)
        XCTAssertTrue(workspace.surfaceTTYNames.isEmpty)

        let portsKickResponse = try await sendV2RequestAsync(
            method: "surface.ports_kick",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": unknownSurfaceId.uuidString
            ],
            to: socketPath
        )

        XCTAssertEqual(portsKickResponse["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(portsKickResponse)")
        let portsKickError = try XCTUnwrap(portsKickResponse["error"] as? [String: Any], "Unexpected JSON-RPC response: \(portsKickResponse)")
        XCTAssertEqual(portsKickError["code"] as? String, "not_found")
        let portsKickData = try XCTUnwrap(portsKickError["data"] as? [String: Any], "Expected error data payload")
        XCTAssertEqual(portsKickData["surface_id"] as? String, unknownSurfaceId.uuidString)
    }

}
