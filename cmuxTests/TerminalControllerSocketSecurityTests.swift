import AppKit
import CmuxCore
import Darwin
import Foundation
import Testing
import CmuxTerminal
import struct CmuxSettings.IntegrationsCatalogSection
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func testComment(_ message: @autoclosure () -> String) -> Comment? {
    let value = message()
    return value.isEmpty ? nil : Comment(rawValue: value)
}

private func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 == value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 != value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression(), testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value = try expression()
        #expect(!value, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression() == nil, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    let value = try expression()
    return try #require(value, testComment(message()), sourceLocation: sourceLocation)
}

private func XCTFail(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
}

@MainActor
@Suite(.serialized)
final class TerminalControllerSocketSecurityTests {
    private var teardownBlocks: [() -> Void] = []

    @Test func browserDownloadQueueDropsCompletionForConsumedPromptedDownload() {
        let controller = TerminalController.shared
        let surfaceId = UUID()
        controller.cleanupSurfaceState(surfaceIds: [surfaceId])
        defer { controller.cleanupSurfaceState(surfaceIds: [surfaceId]) }

        controller.v2RecordBrowserDownloadEvent(
            surfaceId: surfaceId,
            event: [
                "type": "started",
                "download_id": "download-1",
                "filename": "report.csv",
            ]
        )
        controller.v2RecordBrowserDownloadEvent(
            surfaceId: surfaceId,
            event: [
                "type": "ready_to_save",
                "download_id": "download-1",
                "filename": "report.csv",
            ]
        )

        let returned = controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId)
        XCTAssertEqual(returned?["type"] as? String, "ready_to_save")

        controller.v2RecordBrowserDownloadEvent(
            surfaceId: surfaceId,
            event: [
                "type": "saved",
                "download_id": "download-1",
                "filename": "report.csv",
                "path": "/tmp/report.csv",
            ]
        )

        XCTAssertNil(controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId))
    }

    @Test func browserDownloadQueuePrefersPromptedCompletionWhenAlreadyClosed() {
        let controller = TerminalController.shared
        let surfaceId = UUID()
        controller.cleanupSurfaceState(surfaceIds: [surfaceId])
        defer { controller.cleanupSurfaceState(surfaceIds: [surfaceId]) }

        controller.v2RecordBrowserDownloadEvent(
            surfaceId: surfaceId,
            event: [
                "type": "started",
                "download_id": "download-closed",
                "filename": "report.csv",
            ]
        )
        controller.v2RecordBrowserDownloadEvent(
            surfaceId: surfaceId,
            event: [
                "type": "ready_to_save",
                "download_id": "download-closed",
                "filename": "report.csv",
            ]
        )
        controller.v2RecordBrowserDownloadEvent(
            surfaceId: surfaceId,
            event: [
                "type": "saved",
                "download_id": "download-closed",
                "filename": "report.csv",
                "path": "/tmp/report.csv",
            ]
        )

        let returned = controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId)
        XCTAssertEqual(returned?["type"] as? String, "saved")
        XCTAssertEqual(returned?["path"] as? String, "/tmp/report.csv")
        XCTAssertNil(controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId))
    }

    @Test func browserDownloadConsumedIDRegistryIsBounded() {
        let controller = TerminalController.shared
        let surfaceId = UUID()
        controller.cleanupSurfaceState(surfaceIds: [surfaceId])
        defer { controller.cleanupSurfaceState(surfaceIds: [surfaceId]) }

        let oldestID = "download-0"
        let newestID = "download-140"
        for index in 0...140 {
            controller.v2MarkBrowserDownloadEventConsumed(
                [
                    "type": "ready_to_save",
                    "download_id": "download-\(index)",
                ],
                surfaceId: surfaceId
            )
        }

        controller.v2RecordBrowserDownloadEvent(
            surfaceId: surfaceId,
            event: [
                "type": "saved",
                "download_id": oldestID,
            ]
        )

        let returned = controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId)
        XCTAssertEqual(returned?["download_id"] as? String, oldestID)

        controller.v2RecordBrowserDownloadEvent(
            surfaceId: surfaceId,
            event: [
                "type": "saved",
                "download_id": newestID,
            ]
        )

        XCTAssertNil(controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId))
    }

    init() {
        TerminalController.shared.stop()
    }

    deinit {
        teardownBlocks.forEach { $0() }
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("csec-\(name.prefix(4))-\(shortID).sock")
            .path
    }

    private func addTeardownBlock(_ block: @escaping () -> Void) {
        teardownBlocks.append(block)
    }

    @Test func testSocketPermissionsFollowAccessMode() throws {
        let tabManager = TabManager()

        let allowAllPath = makeSocketPath("allow-all")
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: allowAllPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: allowAllPath)
        XCTAssertEqual(try socketMode(at: allowAllPath), 0o666)

        TerminalController.shared.stop()

        let restrictedPath = makeSocketPath("cmux-only")
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: restrictedPath,
            accessMode: .cmuxOnly
        )
        try waitForSocket(at: restrictedPath)
        XCTAssertEqual(try socketMode(at: restrictedPath), 0o600)
    }

    @Test func testPasswordModeRejectsUnauthenticatedCommands() throws {
        let socketPath = makeSocketPath("password-mode")
        let tabManager = TabManager()

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .password
        )
        try waitForSocket(at: socketPath)

        let pingOnly = try sendCommands(["ping"], to: socketPath)
        XCTAssertEqual(pingOnly.count, 1)
        XCTAssertTrue(pingOnly[0].hasPrefix("ERROR:"))
        XCTAssertFalse(pingOnly[0].localizedCaseInsensitiveContains("PONG"))

        let wrongAuthThenPing = try sendCommands(
            ["auth not-the-password", "ping"],
            to: socketPath
        )
        XCTAssertEqual(wrongAuthThenPing.count, 2)
        XCTAssertTrue(wrongAuthThenPing[0].hasPrefix("ERROR:"))
        XCTAssertTrue(wrongAuthThenPing[1].hasPrefix("ERROR:"))
    }

    @Test func testSocketCommandPolicyDistinguishesFocusIntent() throws {
#if DEBUG
        let nonFocus = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "ping",
            isV2: false
        )
        XCTAssertTrue(nonFocus.insideSuppressed)
        XCTAssertFalse(nonFocus.insideAllowsFocus)
        XCTAssertFalse(nonFocus.outsideSuppressed)
        XCTAssertFalse(nonFocus.outsideAllowsFocus)

        let focusV1 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "focus_window",
            isV2: false
        )
        XCTAssertTrue(focusV1.insideSuppressed)
        XCTAssertTrue(focusV1.insideAllowsFocus)
        XCTAssertFalse(focusV1.outsideSuppressed)

        let focusV2 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.select",
            isV2: true
        )
        XCTAssertTrue(focusV2.insideSuppressed)
        XCTAssertTrue(focusV2.insideAllowsFocus)
        XCTAssertFalse(focusV2.outsideSuppressed)

        let triggerFlash = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "surface.trigger_flash",
            isV2: true
        )
        XCTAssertTrue(triggerFlash.insideSuppressed)
        XCTAssertFalse(triggerFlash.insideAllowsFocus)

        let simulateShortcut = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "simulate_shortcut",
            isV2: false
        )
        XCTAssertTrue(simulateShortcut.insideSuppressed)
        XCTAssertFalse(simulateShortcut.insideAllowsFocus)

        let settingsOpen = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "settings.open",
            isV2: true
        )
        XCTAssertTrue(settingsOpen.insideSuppressed)
        XCTAssertFalse(settingsOpen.insideAllowsFocus)

        let feedbackOpen = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "feedback.open",
            isV2: true
        )
        XCTAssertTrue(feedbackOpen.insideSuppressed)
        XCTAssertFalse(feedbackOpen.insideAllowsFocus)

        let debugType = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "debug.type",
            isV2: true
        )
        XCTAssertTrue(debugType.insideSuppressed)
        XCTAssertFalse(debugType.insideAllowsFocus)
#else
        return
#endif
    }

    @Test func testDebugTextBoxEndpointsRejectBlankSurfaceID() throws {
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
        return
#endif
    }

    @Test func testRemoteStatusPayloadOmitsSensitiveSSHConfiguration() {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: false, eagerLoadTerminal: false)

        workspace.configureRemoteConnection(
            .init(
                destination: "example.com",
                port: 2222,
                identityFile: "/Users/test/.ssh/id_ed25519",
                sshOptions: ["ControlMaster=auto", "ControlPersist=600"],
                localProxyPort: 1080,
                relayPort: 4444,
                relayID: "relay-id",
                relayToken: "relay-token",
                localSocketPath: "/tmp/cmux-test.sock",
                terminalStartupCommand: "ssh example.com"
            ),
            autoConnect: false
        )

        let payload = workspace.remoteStatusPayload()
        XCTAssertNil(payload["identity_file"])
        XCTAssertNil(payload["ssh_options"])
        XCTAssertEqual(payload["has_identity_file"] as? Bool, true)
        XCTAssertEqual(payload["has_ssh_options"] as? Bool, true)
    }

    @Test func testRemoteConfigureRejectsInvalidPersistentDaemonSlot() throws {
        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": UUID().uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "persistent_daemon_slot": "../bad",
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        XCTAssertEqual(
            error["message"] as? String,
            "persistent_daemon_slot must contain only letters, numbers, '.', '_' or '-'"
        )
    }

    @Test func testRemoteConfigureDefaultsPersistentDaemonSlotForBootstrapSSH() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "preserve_after_terminal_exit": true,
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(workspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        XCTAssertEqual(
            workspace.remoteConfiguration?.persistentDaemonSlot,
            "ssh-\(workspace.id.uuidString.lowercased())"
        )
    }

    @Test func testRemoteConfigureDerivesAgentSocketPathFromForwardAgentOption() throws {
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        let agentSocketPath = try makeExistingAgentSocketPath()
        setenv("SSH_AUTH_SOCK", agentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "ssh_options": ["ForwardAgent=yes"],
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(workspace.remoteConfiguration?.agentSocketPath, agentSocketPath)
        XCTAssertEqual(workspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(workspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
    }

    @Test func testRemoteConfigureExplicitEmptyAgentSocketSuppressesForwardAgentFallback() throws {
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        let agentSocketPath = try makeExistingAgentSocketPath()
        setenv("SSH_AUTH_SOCK", agentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "ssh_options": ["ForwardAgent=yes"],
                "ssh_auth_sock": "",
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertNil(workspace.remoteConfiguration?.agentSocketPath)
        XCTAssertNil(workspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"])
        XCTAssertNil(workspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"])
    }

    @Test func testRemoteConfigureUsesLastForwardAgentOption() throws {
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        let agentSocketPath = try makeExistingAgentSocketPath()
        setenv("SSH_AUTH_SOCK", agentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "ssh_options": ["ForwardAgent=yes", "ForwardAgent=no"],
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertNil(workspace.remoteConfiguration?.agentSocketPath)
        XCTAssertNil(workspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"])
        XCTAssertNil(workspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"])
    }

    @Test func testRemoteConfigureRejectsPersistentDaemonSlotWithoutPreserve() throws {
        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": UUID().uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "persistent_daemon_slot": "ssh-test-slot",
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        XCTAssertEqual(
            error["message"] as? String,
            "preserve_after_terminal_exit is required when persistent_daemon_slot is set"
        )
    }

    @Test func testRemotePTYResizeRunsOnSocketWorker() async throws {
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

    @Test func testWorkspaceWorkerMethodRejectsWindowAliasInsteadOfDefaultWindowFallback() async throws {
        let socketPath = makeSocketPath("alias-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let params: [String: Any] = ["window": "window:2"]
        let requestLine = try makeV2RequestLine(
            method: "workspace.remote.pty_sessions",
            params: params
        )

        let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
        let mainError = try XCTUnwrap(mainEnvelope["error"] as? [String: Any])
        XCTAssertEqual(mainError["code"] as? String, "invalid_dispatch")

        let workerEnvelope = try await sendV2RequestAsync(
            method: "workspace.remote.pty_sessions",
            params: params,
            to: socketPath
        )
        try assertUnsupportedWorkspaceWindowAlias(workerEnvelope)
    }

    @Test func testHeartbeatMethodsSupportInProcessAndSocketDispatch() async throws {
        let socketPath = makeSocketPath("heartbeat-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        for method in ["system.ping", "system.capabilities"] {
            let requestLine = try makeV2RequestLine(method: method, params: [:])
            let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
            XCTAssertEqual(mainEnvelope["ok"] as? Bool, true, method)
            try assertHeartbeatResult(method: method, envelope: mainEnvelope)

            let workerEnvelope = try await sendV2RequestAsync(method: method, params: [:], to: socketPath)
            XCTAssertEqual(workerEnvelope["ok"] as? Bool, true, method)
            try assertHeartbeatResult(method: method, envelope: workerEnvelope)
        }
    }

    private func assertHeartbeatResult(method: String, envelope: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try XCTUnwrap(envelope["result"] as? [String: Any], method, file: file, line: line)
        switch method {
        case "system.ping":
            XCTAssertEqual(result["pong"] as? Bool, true, file: file, line: line)
        case "system.capabilities":
            let methods = try XCTUnwrap(result["methods"] as? [String], method, file: file, line: line)
            let advertisedMethods = Set(methods)
            let expectedMethods: Set<String> = [
                "system.ping",
                "system.capabilities",
                "mobile.host.status",
                "mobile.attach_ticket.create",
                "mobile.workspace.list",
                "workspace.list",
                "workspace.create",
                "mobile.terminal.create",
                "terminal.create",
                "mobile.terminal.input",
                "terminal.input",
                "mobile.terminal.replay",
                "terminal.replay",
                "mobile.terminal.viewport",
                "terminal.viewport",
                "mobile.events.subscribe",
                "mobile.events.unsubscribe",
            ]
            XCTAssertTrue(
                expectedMethods.isSubset(of: advertisedMethods),
                "Missing capabilities: \(expectedMethods.subtracting(advertisedMethods).sorted())",
                file: file,
                line: line
            )
        default:
            XCTFail("Unexpected heartbeat method \(method)", file: file, line: line)
        }
    }

    @Test func testRemotePTYBridgeWaitForReadyRunsOnSocketWorker() async throws {
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

    @Test func testRemotePTYAttachEndRoutesMovedSurfaceToCurrentWorkspace() throws {
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

    @Test func testRemotePTYRejectsWorkspaceSurfaceMismatchWithoutMovedSurfaceOptIn() async throws {
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

    @Test func testRemotePTYResizeRoutesMovedSurfaceToCurrentWorkspace() async throws {
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

    @Test func testRemotePTYBridgeRoutesMovedSurfaceToCurrentWorkspace() async throws {
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

    @Test func testRemotePTYAllWorkspacesTreatsMissingPTYListAsUnsupported() {
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

    @Test func testNotificationCreateUsesExplicitSurfaceIDWhenProvided() async throws {
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

    @Test func testPaneCreateStartupEnvironmentMarksManagedSubagentForRawNotificationSuppression() async throws {
        let socketPath = makeSocketPath("pane-env")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)
        let defaults = UserDefaults.standard
        let previousSuppressionDefault = defaults.object(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)

        defaults.set(true, forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            if let previousSuppressionDefault {
                defaults.set(previousSuppressionDefault, forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
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

    @Test func testSurfaceRelayRPCsReturnResolvedFocusedSurfaceWhenSurfaceIDOmitted() async throws {
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

    @Test func testSurfaceRelayRPCsRejectExplicitUnknownSurfaceID() async throws {
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

    @Test func testWorkspaceCloseRejectsPinnedWorkspace() async throws {
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

    @Test func testV2SurfaceCloseCommandsRecordRecentlyClosedHistory() throws {
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

    @Test func testBrowserOpenSplitDoesNotExternallyOpenDiffViewerWhenBrowserDisabled() throws {
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

    @Test func testLegacyCloseSurfaceCommandRecordsRecentlyClosedHistory() throws {
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

    private func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        XCTFail("Timed out waiting for socket at \(path)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    private func socketMode(at path: String) throws -> UInt16 {
        var fileInfo = stat()
        guard lstat(path, &fileInfo) == 0 else {
            throw posixError("lstat(\(path))")
        }
        return UInt16(fileInfo.st_mode & 0o777)
    }

    private func sendCommands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            throw posixError("connect(\(socketPath))")
        }

        var responses: [String] = []
        for command in commands {
            try writeLine(command, to: fd)
            responses.append(try readLine(from: fd))
        }
        return responses
    }

    private func makeV2RequestLine(method: String, params: [String: Any]) throws -> String {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
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

    private func decodeV2Envelope(_ raw: String) throws -> [String: Any] {
        let data = try XCTUnwrap(raw.data(using: .utf8))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Expected JSON-RPC response object"
        )
    }

    private func handleV2Request(
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let requestLine = try makeV2RequestLine(method: method, params: params)
        return try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
    }

    private func assertUnsupportedWorkspaceWindowAlias(
        _ envelope: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(envelope["ok"] as? Bool, false, file: file, line: line)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(error["code"] as? String, "invalid_params", file: file, line: line)
        let data = try XCTUnwrap(error["data"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(data["unsupported_param"] as? String, "window", file: file, line: line)
        XCTAssertEqual(data["supported_param"] as? String, "window_id", file: file, line: line)
    }

    private nonisolated func sendV2Request(
        method: String,
        params: [String: Any],
        to socketPath: String
    ) throws -> [String: Any] {
        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode JSON-RPC request"
            ])
        }
        try writeLine(line, to: fd)

        let responseLine = try readLine(from: fd)
        let responseData = Data(responseLine.utf8)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            "Expected JSON-RPC response object"
        )
    }

    private func sendV2RequestAsync(
        method: String,
        params: [String: Any],
        to socketPath: String
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: method,
                        params: params,
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated func connect(to socketPath: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            let error = posixError("connect(\(socketPath))")
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private nonisolated func writeLine(_ command: String, to fd: Int32) throws {
        let payload = Array((command + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let wrote = payload.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard wrote >= 0 else {
                throw posixError("write(\(command))")
            }
            offset += wrote
        }
    }

    private nonisolated func readLine(from fd: Int32) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 1)
        var data = Data()

        while true {
            let count = Darwin.read(fd, &buffer, 1)
            guard count >= 0 else {
                throw posixError("read")
            }
            if count == 0 { break }
            if buffer[0] == 0x0A { break }
            data.append(buffer[0])
        }

        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Invalid UTF-8 response from socket"
            ])
        }
        return line
    }

    private func makeExistingAgentSocketPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("agent.sock")
        XCTAssertTrue(
            FileManager.default.createFile(atPath: url.path, contents: Data()),
            "Expected to create \(url.path)"
        )
        return url.path
    }

    private nonisolated func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
