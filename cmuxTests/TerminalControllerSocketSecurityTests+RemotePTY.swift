import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Remote PTY worker routing and moved-surface resolution
extension TerminalControllerSocketSecurityTests {
    func testRemotePTYResizeRunsOnSocketWorker() async throws {
        let socketPath = makeSocketPath("pty-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let params: [String: Any] = [
            "workspace_id": UUID().uuidString,
            "session_id": "session",
            "attachment_id": "attachment",
            "attachment_token": "token",
            "cols": 100,
            "rows": 30,
        ]
        let requestLine = try makeV2RequestLine(
            method: "workspace.remote.pty_resize",
            params: params
        )

        let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
        let mainError = try XCTUnwrap(mainEnvelope["error"] as? [String: Any])
        XCTAssertEqual(mainError["code"] as? String, "invalid_dispatch")

        let workerEnvelope = try await sendV2RequestAsync(
            method: "workspace.remote.pty_resize",
            params: params,
            to: socketPath
        )
        let workerError = try XCTUnwrap(workerEnvelope["error"] as? [String: Any])
        XCTAssertNotEqual(workerError["code"] as? String, "invalid_dispatch")
        XCTAssertNotEqual(workerError["code"] as? String, "method_not_found")
        XCTAssertEqual(workerError["code"] as? String, "not_found")
    }

    func testRemotePTYBridgeWaitForReadyRunsOnSocketWorker() async throws {
        let socketPath = makeSocketPath("pty-bridge-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let params: [String: Any] = [
            "workspace_id": UUID().uuidString,
            "session_id": "session",
            "attachment_id": "attachment",
            "wait_for_ready": true,
        ]
        let requestLine = try makeV2RequestLine(
            method: "workspace.remote.pty_bridge",
            params: params
        )

        let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
        let mainError = try XCTUnwrap(mainEnvelope["error"] as? [String: Any])
        XCTAssertEqual(mainError["code"] as? String, "invalid_dispatch")

        let workerEnvelope = try await sendV2RequestAsync(
            method: "workspace.remote.pty_bridge",
            params: params,
            to: socketPath
        )
        let workerError = try XCTUnwrap(workerEnvelope["error"] as? [String: Any])
        XCTAssertNotEqual(workerError["code"] as? String, "invalid_dispatch")
        XCTAssertNotEqual(workerError["code"] as? String, "method_not_found")
        XCTAssertEqual(workerError["code"] as? String, "not_found")
    }

    func testRemotePTYAttachEndRoutesMovedSurfaceToCurrentWorkspace() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let moved = try makeMovedRemotePTYSurface(in: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: makeSocketPath("pty-end"),
            accessMode: .allowAll
        )

        let requestLine = try makeV2RequestLine(
            method: "workspace.remote.pty_attach_end",
            params: [
                "workspace_id": moved.source.id.uuidString,
                "surface_id": moved.panel.id.uuidString,
                "session_id": moved.sessionID,
            ]
        )
        let envelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))

        XCTAssertEqual(envelope["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(envelope)")
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["window_id"] as? String, windowId.uuidString)
        XCTAssertEqual(result["workspace_id"] as? String, moved.destination.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, moved.panel.id.uuidString)
        XCTAssertEqual(result["cleared_remote_pty_session"] as? Bool, true)
        XCTAssertEqual(result["untracked_remote_terminal"] as? Bool, true)
        XCTAssertFalse(moved.destination.isRemoteTerminalSurface(moved.panel.id))
        XCTAssertEqual(moved.destination.activeRemoteTerminalSessionCount, 0)
    }

    func testRemotePTYRejectsWorkspaceSurfaceMismatchWithoutMovedSurfaceOptIn() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let socketPath = makeSocketPath("pty-mismatch")
        let manager = TabManager()
        let moved = try makeMovedRemotePTYSurface(in: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "workspace.remote.pty_resize",
            params: [
                "workspace_id": moved.source.id.uuidString,
                "surface_id": moved.panel.id.uuidString,
                "session_id": moved.sessionID,
                "attachment_id": moved.panel.id.uuidString,
                "attachment_token": "token",
                "cols": 100,
                "rows": 30,
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        XCTAssertEqual(error["message"] as? String, "surface_id does not belong to workspace_id")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["workspace_id"] as? String, moved.source.id.uuidString)
        XCTAssertEqual(data["surface_id"] as? String, moved.panel.id.uuidString)
        XCTAssertEqual(data["resolved_workspace_id"] as? String, moved.destination.id.uuidString)
    }

    func testRemotePTYResizeRoutesMovedSurfaceToCurrentWorkspace() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let socketPath = makeSocketPath("pty-move")
        let manager = TabManager()
        let moved = try makeMovedRemotePTYSurface(in: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "workspace.remote.pty_resize",
            params: [
                "workspace_id": moved.source.id.uuidString,
                "surface_id": moved.panel.id.uuidString,
                "session_id": moved.sessionID,
                "attachment_id": moved.panel.id.uuidString,
                "attachment_token": "token",
                "cols": 100,
                "rows": 30,
                "allow_moved_surface": true,
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "remote_pty_error")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        let locatedWorkspaceId = appDelegate.workspaceContainingPanel(
            panelId: moved.panel.id,
            preferredWorkspaceId: moved.source.id
        )?.workspace.id.uuidString
        XCTAssertEqual(
            data["workspace_id"] as? String,
            moved.destination.id.uuidString,
            "source=\(moved.source.id.uuidString) destination=\(moved.destination.id.uuidString) " +
            "located=\(locatedWorkspaceId ?? "nil") " +
            "sourceActive=\(moved.source.surfaceIdFromPanelId(moved.panel.id) != nil) " +
            "destinationActive=\(moved.destination.surfaceIdFromPanelId(moved.panel.id) != nil)"
        )
        XCTAssertEqual(data["session_id"] as? String, moved.sessionID)
        XCTAssertEqual(data["attachment_id"] as? String, moved.panel.id.uuidString)
    }

    func testRemotePTYBridgeRoutesMovedSurfaceToCurrentWorkspace() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let socketPath = makeSocketPath("pty-bridge-move")
        let manager = TabManager()
        let moved = try makeMovedRemotePTYSurface(in: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "workspace.remote.pty_bridge",
            params: [
                "workspace_id": moved.source.id.uuidString,
                "surface_id": moved.panel.id.uuidString,
                "session_id": moved.sessionID,
                "attachment_id": moved.panel.id.uuidString,
                "command": "",
                "require_existing": true,
                "allow_moved_surface": true,
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "remote_pty_error")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["workspace_id"] as? String, moved.destination.id.uuidString)
        XCTAssertEqual(data["session_id"] as? String, moved.sessionID)
        XCTAssertEqual(data["attachment_id"] as? String, moved.panel.id.uuidString)
    }

    func testRemotePTYAllWorkspacesTreatsMissingPTYListAsUnsupported() {
        let unsupported = NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 14,
            userInfo: [
                NSLocalizedDescriptionKey: "pty.list failed (method_not_found): Unknown method",
            ]
        )
        XCTAssertTrue(remotePTYSessionListErrorIsUnsupportedDaemon(unsupported))

        let notReady = NSError(
            domain: "cmux.remote.pty",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "remote daemon is not ready",
            ]
        )
        XCTAssertFalse(remotePTYSessionListErrorIsUnsupportedDaemon(notReady))

        let differentRPCMethod = NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 14,
            userInfo: [
                NSLocalizedDescriptionKey: "pty.close failed (method_not_found): Unknown method",
            ]
        )
        XCTAssertFalse(remotePTYSessionListErrorIsUnsupportedDaemon(differentRPCMethod))
    }

    private func makeMovedRemotePTYSurface(
        in manager: TabManager
    ) throws -> (source: Workspace, destination: Workspace, panel: TerminalPanel, sessionID: String) {
        let source = manager.addWorkspace(select: true)
        let destination = manager.addWorkspace(select: false)
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64011,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        source.configureRemoteConnection(config, autoConnect: false)
        destination.configureRemoteConnection(config, autoConnect: false)

        let sourcePanelID = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let destinationPaneID = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let sessionID = "moved-surface-session"
        let panel = try XCTUnwrap(
            source.newTerminalSplit(
                from: sourcePanelID,
                orientation: .horizontal,
                initialCommand: nil,
                remotePTYSessionID: sessionID
            )
        )
        let detached = try XCTUnwrap(source.detachSurface(panelId: panel.id))
        XCTAssertEqual(detached.remotePTYSessionID, sessionID)
        XCTAssertEqual(
            destination.attachDetachedSurface(detached, inPane: destinationPaneID, focus: false),
            panel.id
        )
        XCTAssertTrue(destination.isRemoteTerminalSurface(panel.id))

        return (source, destination, panel, sessionID)
    }

}
