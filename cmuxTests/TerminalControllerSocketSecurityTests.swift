import XCTest
import AppKit
import Darwin
import CMUXVNC
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
@MainActor
final class TerminalControllerSocketSecurityTests: XCTestCase {
    private final class FocusSpyWindow: NSWindow {
        var requestedResponder: NSResponder?
        var currentResponder: NSResponder?

        override var firstResponder: NSResponder? {
            currentResponder
        }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            requestedResponder = responder
            currentResponder = responder
            return true
        }
    }

    private final class FocusableView: NSView {
        weak var spyWindow: NSWindow?

        override var acceptsFirstResponder: Bool { true }

        override var window: NSWindow? {
            spyWindow ?? super.window
        }
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("csec-\(name.prefix(4))-\(shortID).sock")
            .path
    }

    private func makeVNCKeyEvent(
        type: NSEvent.EventType = .keyDown,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String = "",
        charactersIgnoringModifiers: String = "",
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct VNC key event")
        }
        return event
    }

    private func makeVNCMouseEvent(type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 1, y: 1),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("Failed to construct VNC mouse event")
        }
        return event
    }

    private func makeVNCScrollEvent(deltaX: CGFloat = 0, deltaY: CGFloat = 1) -> NSEvent {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ), let event = NSEvent(cgEvent: cgEvent) else {
            fatalError("Failed to construct VNC scroll event")
        }
        return event
    }

    private func makeVNCPreciseScrollEvent(deltaX: Int32 = 0, deltaY: Int32 = 1) -> NSEvent {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ), let event = NSEvent(cgEvent: cgEvent) else {
            fatalError("Failed to construct VNC precise scroll event")
        }
        return event
    }

    private func makeVNCPanel(
        name: String = "docker-vnc-1",
        port: Int = 5900,
        index: Int = 1
    ) -> VNCPanel {
        VNCPanel(
            workspaceId: UUID(),
            session: MacfleetVNCSession(
                name: name,
                hostName: name,
                address: "127.0.0.1",
                port: port,
                username: "cmux",
                index: index
            ),
            credential: VNCResolvedCredential(
                username: "cmux",
                password: "secret",
                source: .sessionPassword
            )
        )
    }

    private func makeVNCDisplayFrame(sequence: UInt64) -> VNCDisplayFrame {
        VNCDisplayFrame(
            header: VNCFrameHeader(
                sequence: sequence,
                x: 0,
                y: 0,
                width: 1,
                height: 1,
                framebufferWidth: 1,
                framebufferHeight: 1,
                stride: 4,
                pixelFormat: .bgra8
            ),
            payload: Data([0, 0, 0, 255])
        )
    }

    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testSocketPermissionsFollowAccessMode() throws {
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

    func testPasswordModeRejectsUnauthenticatedCommands() throws {
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

    func testSocketCommandPolicyDistinguishesFocusIntent() throws {
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
        throw XCTSkip("Socket command policy snapshot helper is debug-only.")
#endif
    }

    func testRemoteStatusPayloadOmitsSensitiveSSHConfiguration() {
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

    func testRightSidebarV1CommandsDriveExistingState() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let tabManager = TabManager()
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let fileExplorerState = FileExplorerState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")

        appDelegate.fileExplorerState = fileExplorerState
        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }

        fileExplorerState.setVisible(false)
        fileExplorerState.mode = .files

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar show"), "OK")
        XCTAssertTrue(fileExplorerState.isVisible)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar set find"), "OK")
        XCTAssertEqual(fileExplorerState.mode, .find)
        XCTAssertTrue(fileExplorerState.isVisible)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar set vault --no-focus"), "OK")
        XCTAssertEqual(fileExplorerState.mode, .sessions)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar set sessions --no-focus"), "OK")
        XCTAssertEqual(fileExplorerState.mode, .sessions)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar hide"), "OK")
        XCTAssertFalse(fileExplorerState.isVisible)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar toggle"), "OK")
        XCTAssertTrue(fileExplorerState.isVisible)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar focus"), "OK")
        XCTAssertTrue(fileExplorerState.isVisible)

        let modeResponse = TerminalController.shared.handleSocketLine("right_sidebar mode")
        let modeData = try XCTUnwrap(modeResponse.data(using: .utf8))
        let modePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: modeData) as? [String: Any])
        XCTAssertEqual(modePayload["visible"] as? Bool, true)
        XCTAssertEqual(modePayload["mode"] as? String, "sessions")

        XCTAssertTrue(TerminalController.shared.handleSocketLine("right_sidebar set unknown").hasPrefix("ERROR:"))
    }

    func testRightSidebarV1ParserProducesRemoteCommands() throws {
#if DEBUG
        let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let cases: [(String, RightSidebarRemoteRequest)] = [
            (
                "right_sidebar toggle",
                RightSidebarRemoteRequest(command: .toggle, target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar show --window=\(windowId.uuidString)",
                RightSidebarRemoteRequest(command: .show, target: RightSidebarRemoteTarget(windowId: windowId, workspaceId: nil))
            ),
            (
                "right_sidebar hide --tab=\(workspaceId.uuidString)",
                RightSidebarRemoteRequest(command: .hide, target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceId))
            ),
            (
                "right_sidebar focus",
                RightSidebarRemoteRequest(command: .focus, target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar set find",
                RightSidebarRemoteRequest(command: .setMode(.find, focus: true), target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar set vault --no-focus",
                RightSidebarRemoteRequest(command: .setMode(.sessions, focus: false), target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar sessions",
                RightSidebarRemoteRequest(command: .setMode(.sessions, focus: true), target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar mode",
                RightSidebarRemoteRequest(command: .getState, target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar state --workspace \(workspaceId.uuidString) --window \(windowId.uuidString)",
                RightSidebarRemoteRequest(command: .getState, target: RightSidebarRemoteTarget(windowId: windowId, workspaceId: workspaceId))
            ),
        ]

        for (line, expected) in cases {
            let result = TerminalController.shared.parseRightSidebarRemoteRequestForTesting(line)
            XCTAssertEqual(try result.get(), expected, line)
        }

        let invalidCases: [(String, String)] = [
            ("right_sidebar", "Usage: right_sidebar"),
            ("right_sidebar set", "Usage: right_sidebar set"),
            ("right_sidebar set unknown", "Unknown right sidebar mode"),
            ("right_sidebar show --no-focus", "Usage: right_sidebar show"),
            ("right_sidebar files --no-focus", "--no-focus is only valid"),
            ("right_sidebar --bad", "Unknown right sidebar option"),
            ("right_sidebar show --tab not-a-uuid", "Invalid right sidebar --tab id"),
            ("right_sidebar show --window", "--window requires an id"),
        ]

        for (line, expectedMessage) in invalidCases {
            switch TerminalController.shared.parseRightSidebarRemoteRequestForTesting(line) {
            case .success(let request):
                XCTFail("Expected parser failure for \(line), got \(request)")
            case .failure(let error):
                XCTAssertTrue(
                    error.message.contains(expectedMessage),
                    "Expected \(line) to contain \(expectedMessage), got \(error.message)"
                )
            }
        }
#else
        throw XCTSkip("Right sidebar parser helper is debug-only.")
#endif
    }

    func testRightSidebarV1FocusPolicyIsCommandSpecific() throws {
#if DEBUG
        let cases: [(String, Bool)] = [
            ("right_sidebar toggle", true),
            ("right_sidebar show", true),
            ("right_sidebar focus", true),
            ("right_sidebar set find", true),
            ("right_sidebar sessions", true),
            ("right_sidebar set vault --no-focus", false),
            ("right_sidebar hide", false),
            ("right_sidebar mode", false),
            ("right_sidebar state", false),
            ("right_sidebar set unknown", false),
        ]

        for (line, expected) in cases {
            XCTAssertEqual(
                TerminalController.shared.rightSidebarCommandAllowsInAppFocusMutationsForTesting(line),
                expected,
                line
            )
        }
#else
        throw XCTSkip("Right sidebar focus policy helper is debug-only.")
#endif
    }

    func testRightSidebarRemoteCommandsCanTargetRegisteredWindowOrWorkspaceWithoutFocus() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }
        let windowAId = UUID()
        let windowBId = UUID()
        let managerA = TabManager()
        let managerB = TabManager()
        let managerC = TabManager()
        _ = managerA.addWorkspace(select: false, eagerLoadTerminal: false)
        let workspaceB = managerB.addWorkspace(select: false, eagerLoadTerminal: false)
        let workspaceC = managerC.addWorkspace(select: false, eagerLoadTerminal: false)
        let stateA = FileExplorerState()
        let stateB = FileExplorerState()
        let fallbackState = FileExplorerState()

        stateA.setVisible(false)
        stateA.mode = .files
        stateB.setVisible(false)
        stateB.mode = .files
        fallbackState.setVisible(true)
        fallbackState.mode = .dock
        appDelegate.fileExplorerState = fallbackState

        appDelegate.registerMainWindowContextForTesting(
            windowId: windowAId,
            tabManager: managerA,
            fileExplorerState: stateA
        )
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowBId,
            tabManager: managerB,
            fileExplorerState: stateB
        )
        let windowCId = appDelegate.registerMainWindowContextForTesting(
            tabManager: managerC
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowAId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowBId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowCId)
        }

        XCTAssertEqual(
            appDelegate.applyRightSidebarRemoteCommand(
                .setMode(.find, focus: false),
                target: RightSidebarRemoteTarget(windowId: windowAId, workspaceId: nil)
            ),
            .ok
        )
        XCTAssertTrue(stateA.isVisible)
        XCTAssertEqual(stateA.mode, .find)
        XCTAssertFalse(stateB.isVisible)
        XCTAssertEqual(stateB.mode, .files)

        XCTAssertEqual(
            appDelegate.applyRightSidebarRemoteCommand(
                .setMode(.sessions, focus: false),
                target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
            ),
            .ok
        )
        XCTAssertTrue(stateB.isVisible)
        XCTAssertEqual(stateB.mode, .sessions)
        XCTAssertEqual(stateA.mode, .find)

        XCTAssertEqual(
            appDelegate.applyRightSidebarRemoteCommand(
                .hide,
                target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
            ),
            .ok
        )
        XCTAssertFalse(stateB.isVisible)
        XCTAssertTrue(stateA.isVisible)

        switch appDelegate.applyRightSidebarRemoteCommand(
            .toggle,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) {
        case .failure(let message):
            XCTAssertTrue(message.contains("target not found"), message)
        case .ok, .state:
            XCTFail("Expected targeted toggle without a window to fail")
        }
        XCTAssertFalse(stateB.isVisible)

        XCTAssertEqual(
            appDelegate.applyRightSidebarRemoteCommand(
                .getState,
                target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
            ),
            .state(.init(visible: false, mode: .sessions))
        )

        switch appDelegate.applyRightSidebarRemoteCommand(
            .getState,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceC.id)
        ) {
        case .failure(let message):
            XCTAssertTrue(message.contains("state not available"), message)
        case .ok, .state:
            XCTFail("Expected explicit target without right-sidebar state to fail")
        }

        switch appDelegate.applyRightSidebarRemoteCommand(
            .hide,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: UUID())
        ) {
        case .failure(let message):
            XCTAssertTrue(message.contains("target not found"), message)
        case .ok, .state:
            XCTFail("Expected missing workspace target to fail")
        }
    }

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

    func testGenericSurfaceCreationRejectsVNCType() async throws {
        let socketPath = makeSocketPath("vnc-type")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)
        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let initialPanelCount = workspace.panels.count

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let cases: [(method: String, params: [String: Any])] = [
            (
                method: "surface.create",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "type": "vnc"
                ]
            ),
            (
                method: "surface.split",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": focusedPanelId.uuidString,
                    "direction": "right",
                    "type": "vnc"
                ]
            ),
            (
                method: "pane.create",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": focusedPanelId.uuidString,
                    "direction": "right",
                    "type": "vnc"
                ]
            )
        ]

        for testCase in cases {
            let response = try await sendV2RequestAsync(
                method: testCase.method,
                params: testCase.params,
                to: socketPath
            )

            XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
            let error = try XCTUnwrap(response["error"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
            XCTAssertEqual(error["code"] as? String, "invalid_params")
            XCTAssertTrue((error["message"] as? String)?.contains("VNC") == true)
            let data = try XCTUnwrap(error["data"] as? [String: Any], "Expected error data payload")
            XCTAssertEqual(data["type"] as? String, PanelType.vnc.rawValue)
        }

        XCTAssertEqual(
            workspace.panels.count,
            initialPanelCount,
            "Generic socket creation methods must not create terminal fallbacks for unsupported VNC requests."
        )
    }

    func testVNCPendingFocusAppliesWhenCanvasGetsWindow() throws {
        let panel = VNCPanel(
            workspaceId: UUID(),
            session: MacfleetVNCSession(
                name: "docker-vnc-1",
                hostName: "docker-vnc-1",
                address: "127.0.0.1",
                port: 5900,
                username: "cmux",
                index: 1
            ),
            credential: VNCResolvedCredential(
                username: "cmux",
                password: "secret",
                source: .sessionPassword
            )
        )
        let view = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = FocusSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        defer {
            panel.close()
        }

        panel.focus()
        panel.attachFocusView(view)
        XCTAssertNil(window.requestedResponder)

        view.spyWindow = window
        panel.focusViewWindowDidChange(view)

        XCTAssertTrue(window.requestedResponder === view)
    }

    func testVNCUnfocusClearsPendingFocusBeforeCanvasGetsWindow() throws {
        let panel = VNCPanel(
            workspaceId: UUID(),
            session: MacfleetVNCSession(
                name: "docker-vnc-1",
                hostName: "docker-vnc-1",
                address: "127.0.0.1",
                port: 5900,
                username: "cmux",
                index: 1
            ),
            credential: VNCResolvedCredential(
                username: "cmux",
                password: "secret",
                source: .sessionPassword
            )
        )
        let view = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = FocusSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        defer {
            panel.close()
        }

        panel.focus()
        panel.attachFocusView(view)
        panel.unfocus()
        view.spyWindow = window
        panel.focusViewWindowDidChange(view)

        XCTAssertNil(window.requestedResponder)
    }

    func testVNCUnfocusResignsOwnedFirstResponder() throws {
        let panel = VNCPanel(
            workspaceId: UUID(),
            session: MacfleetVNCSession(
                name: "docker-vnc-1",
                hostName: "docker-vnc-1",
                address: "127.0.0.1",
                port: 5900,
                username: "cmux",
                index: 1
            ),
            credential: VNCResolvedCredential(
                username: "cmux",
                password: "secret",
                source: .sessionPassword
            )
        )
        let view = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = FocusSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        defer {
            panel.close()
        }

        panel.attachFocusView(view)
        view.spyWindow = window
        window.currentResponder = view

        panel.unfocus()

        XCTAssertNil(window.requestedResponder)
        XCTAssertNil(window.currentResponder)
    }

    func testVNCCanvasResignFirstResponderReleasesModifiers() throws {
        let view = VNCMetalCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var keyEvents: [String] = []
        view.onKey = { keyCode, isDown, _ in
            keyEvents.append("\(keyCode):\(isDown)")
        }
        defer {
            view.close()
        }

        view.flagsChanged(with: makeVNCKeyEvent(type: .flagsChanged, modifierFlags: .command, keyCode: 55))
        XCTAssertEqual(keyEvents, ["55:true"])

        XCTAssertTrue(view.resignFirstResponder())

        XCTAssertEqual(keyEvents, ["55:true", "55:false"])
    }

    func testVNCCanvasCoordinatorTransfersFocusOwnershipWhenViewIsReused() throws {
        let firstPanel = VNCPanel(
            workspaceId: UUID(),
            session: MacfleetVNCSession(
                name: "docker-vnc-1",
                hostName: "docker-vnc-1",
                address: "127.0.0.1",
                port: 5900,
                username: "cmux",
                index: 1
            ),
            credential: VNCResolvedCredential(
                username: "cmux",
                password: "secret",
                source: .sessionPassword
            )
        )
        let secondPanel = VNCPanel(
            workspaceId: UUID(),
            session: MacfleetVNCSession(
                name: "docker-vnc-2",
                hostName: "docker-vnc-2",
                address: "127.0.0.1",
                port: 5901,
                username: "cmux",
                index: 2
            ),
            credential: VNCResolvedCredential(
                username: "cmux",
                password: "secret",
                source: .sessionPassword
            )
        )
        let view = VNCMetalCanvasView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let coordinator = VNCMetalCanvasRepresentable.Coordinator()
        defer {
            coordinator.detach()
            firstPanel.close()
            secondPanel.close()
        }

        coordinator.attach(panel: firstPanel, view: view)
        view.apply(makeVNCDisplayFrame(sequence: 100))
        XCTAssertNotNil(firstPanel.ownedFocusIntent(for: view, in: window))
        XCTAssertNil(secondPanel.ownedFocusIntent(for: view, in: window))
        XCTAssertEqual(view.appliedFrameSequenceForTesting, 100)

        coordinator.attach(panel: secondPanel, view: view)
        XCTAssertNil(firstPanel.ownedFocusIntent(for: view, in: window))
        XCTAssertNotNil(secondPanel.ownedFocusIntent(for: view, in: window))
        XCTAssertNil(view.appliedFrameSequenceForTesting)

        view.apply(makeVNCDisplayFrame(sequence: 1))
        XCTAssertEqual(view.appliedFrameSequenceForTesting, 1)

        coordinator.detach()
        XCTAssertNil(secondPanel.ownedFocusIntent(for: view, in: window))
    }

    func testVNCCanvasCoordinatorResetsInputStateWhenViewIsReused() throws {
        let firstPanel = makeVNCPanel(name: "docker-vnc-1", port: 5900, index: 1)
        let secondPanel = makeVNCPanel(name: "docker-vnc-2", port: 5901, index: 2)
        let view = VNCMetalCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let coordinator = VNCMetalCanvasRepresentable.Coordinator()
        var firstKeyEvents: [String] = []
        var secondKeyEvents: [String] = []
        var scrollEvents: [String] = []
        defer {
            coordinator.detach()
            view.close()
            firstPanel.close()
            secondPanel.close()
        }

        view.onKey = { keyCode, isDown, _ in
            firstKeyEvents.append("\(keyCode):\(isDown)")
        }
        view.onScroll = { _, _, wheel, steps in
            scrollEvents.append("\(wheel):\(steps)")
        }
        coordinator.attach(panel: firstPanel, view: view)
        view.apply(makeVNCDisplayFrame(sequence: 1))
        view.flagsChanged(with: makeVNCKeyEvent(type: .flagsChanged, modifierFlags: .command, keyCode: 55))
        view.scrollWheel(with: makeVNCPreciseScrollEvent(deltaY: 6))

        XCTAssertEqual(firstKeyEvents, ["55:true"])
        XCTAssertEqual(scrollEvents, [])

        coordinator.attach(panel: secondPanel, view: view)
        view.onKey = { keyCode, isDown, _ in
            secondKeyEvents.append("\(keyCode):\(isDown)")
        }
        view.onScroll = { _, _, wheel, steps in
            scrollEvents.append("\(wheel):\(steps)")
        }
        view.apply(makeVNCDisplayFrame(sequence: 1))
        view.scrollWheel(with: makeVNCPreciseScrollEvent(deltaY: 6))

        XCTAssertEqual(firstKeyEvents, ["55:true", "55:false"])
        XCTAssertEqual(secondKeyEvents, [])
        XCTAssertEqual(scrollEvents, [])
    }

    func testVNCOldCoordinatorDetachDoesNotClearReplacementCanvasFocus() throws {
        let panel = makeVNCPanel()
        let oldView = VNCMetalCanvasView()
        let newView = VNCMetalCanvasView()
        let oldCoordinator = VNCMetalCanvasRepresentable.Coordinator()
        let newCoordinator = VNCMetalCanvasRepresentable.Coordinator()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        defer {
            oldCoordinator.detach()
            newCoordinator.detach()
            oldView.close()
            newView.close()
            panel.close()
        }

        oldCoordinator.attach(panel: panel, view: oldView)
        newCoordinator.attach(panel: panel, view: newView)
        XCTAssertNil(panel.ownedFocusIntent(for: oldView, in: window))
        XCTAssertNotNil(panel.ownedFocusIntent(for: newView, in: window))

        oldCoordinator.detach()

        XCTAssertNil(panel.ownedFocusIntent(for: oldView, in: window))
        XCTAssertNotNil(panel.ownedFocusIntent(for: newView, in: window))

        newCoordinator.detach()
        XCTAssertNil(panel.ownedFocusIntent(for: newView, in: window))
    }

    func testVNCCanvasMouseDownRequestsPanelFocus() throws {
        let view = VNCMetalCanvasView()
        var focusRequestCount = 0
        view.onRequestFocus = {
            focusRequestCount += 1
        }

        view.mouseDown(with: makeVNCMouseEvent())
        XCTAssertEqual(focusRequestCount, 1)

        view.rightMouseDown(with: makeVNCMouseEvent(type: .rightMouseDown))
        XCTAssertEqual(focusRequestCount, 2)
    }

    func testVNCCanvasScrollWheelForwardsRemoteWheelInput() throws {
        let view = VNCMetalCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var events: [String] = []
        view.onScroll = { x, y, wheel, steps in
            events.append("\(x):\(y):\(wheel):\(steps)")
        }
        defer {
            view.onScroll = nil
            view.close()
        }

        view.apply(makeVNCDisplayFrame(sequence: 1))
        view.scrollWheel(with: makeVNCScrollEvent(deltaY: 1))

        XCTAssertEqual(events, ["0:0:2:1"])
    }

    func testVNCCanvasImpreciseScrollPreservesStepMagnitude() throws {
        let view = VNCMetalCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var events: [String] = []
        view.onScroll = { x, y, wheel, steps in
            events.append("\(x):\(y):\(wheel):\(steps)")
        }
        defer {
            view.onScroll = nil
            view.close()
        }

        view.apply(makeVNCDisplayFrame(sequence: 1))
        view.scrollWheel(with: makeVNCScrollEvent(deltaY: 3))

        XCTAssertEqual(events, ["0:0:2:3"])
    }

    func testVNCWorkspaceIdentityMatchSurvivesRename() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let session = MacfleetVNCSession(
            name: "docker-vnc-1",
            hostName: "docker-vnc-1",
            address: "127.0.0.1",
            port: 5900,
            username: "cmux",
            tag: "mac-mini-cluster",
            index: 1
        )
        let otherSession = MacfleetVNCSession(
            name: "docker-vnc-2",
            hostName: "docker-vnc-2",
            address: "127.0.0.1",
            port: 5901,
            username: "cmux",
            tag: "mac-mini-cluster",
            index: 2
        )
        let credential = VNCResolvedCredential(
            username: "cmux",
            password: "secret",
            source: .sessionPassword
        )
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        XCTAssertNotNil(workspace.newVNCSurface(inPane: paneId, session: session, credential: credential, focus: false))
        workspace.title = "Renamed workspace"

        XCTAssertTrue(workspace.containsVNCSessionConnectionIdentity(session))
        XCTAssertFalse(workspace.containsVNCSessionConnectionIdentity(otherSession))
    }

    func testMacfleetVNCCredentialSummaryReportsSkippedCredentialsWhenReusingWorkspace() {
        var summary = MacfleetVNCLaunchCredentialSummary(skippedCredentialCount: 1)
        summary.reusedCount = 1

        XCTAssertEqual(
            summary.alert,
            .partial(openedCount: 0, reusedCount: 1, missingCount: 1)
        )
    }

    func testMacfleetVNCCredentialSummaryReportsNoCredentialsWhenNothingAvailable() {
        let summary = MacfleetVNCLaunchCredentialSummary(skippedCredentialCount: 2)

        XCTAssertEqual(summary.alert, .noCredentials)
    }

    func testVNCKeychainInternetLookupsRequireExplicitSessionPort() {
        let session = MacfleetVNCSession(
            name: "mac3-1",
            hostName: "mac3",
            address: "mac3-1.local",
            port: 5901,
            username: "cmuxvnc",
            tag: "tag:mac-mini-cluster",
            index: 1
        )

        let lookups = VNCKeychainCredentialProvider.internetPasswordLookups(for: session)

        XCTAssertFalse(lookups.isEmpty)
        XCTAssertTrue(lookups.allSatisfy { $0.port == 5901 })
        XCTAssertTrue(lookups.contains { $0.server == "mac3-1.local" })
        XCTAssertFalse(lookups.contains { $0.server == "mac3-1.local:5901" })
    }

    func testVNCPanelConnectionPreservesPartialFrameForPublish() throws {
        let header = VNCFrameHeader(
            sequence: 2,
            x: 1,
            y: 0,
            width: 1,
            height: 1,
            framebufferWidth: 2,
            framebufferHeight: 1,
            stride: 4,
            pixelFormat: .bgra8
        )
        let payload = Data([1, 2, 3, 4])

        let frame = try XCTUnwrap(VNCPanelConnection.validatedFrameForPublish(header: header, payload: payload))

        XCTAssertEqual(frame.header, header)
        XCTAssertEqual(frame.payload, payload)
    }

    func testVNCPanelConnectionComposesPartialFramesBeforePublish() async {
        let session = MacfleetVNCSession(
            name: "mac3-1",
            hostName: "mac3",
            address: "mac3-1.local",
            port: 5901,
            username: "cmuxvnc",
            tag: "tag:mac-mini-cluster",
            index: 1
        )
        let credential = VNCResolvedCredential(
            username: "cmuxvnc",
            password: "password",
            source: .defaultPassword
        )
        let deliveredFrames = expectation(description: "VNC frame delivered")
        var deliveredSequences: [UInt64] = []
        var deliveredHeaders: [VNCFrameHeader] = []
        var deliveredPayloads: [Data] = []
        let connection = VNCPanelConnection(
            session: session,
            credential: credential,
            onControl: { _ in },
            onFrame: { header, payload in
                deliveredSequences.append(header.sequence)
                deliveredHeaders.append(header)
                deliveredPayloads.append(payload)
                deliveredFrames.fulfill()
            },
            onExit: { _ in }
        )
        defer { connection.close() }

        let fullHeader = VNCFrameHeader(
            sequence: 1,
            x: 0,
            y: 0,
            width: 2,
            height: 1,
            framebufferWidth: 2,
            framebufferHeight: 1,
            stride: 8,
            pixelFormat: .bgra8
        )
        let partialHeader = VNCFrameHeader(
            sequence: 2,
            x: 1,
            y: 0,
            width: 1,
            height: 1,
            framebufferWidth: 2,
            framebufferHeight: 1,
            stride: 4,
            pixelFormat: .bgra8
        )
        let fullPayload = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let partialPayload = Data([9, 10, 11, 12])

        connection.publishForTesting(.frame(fullHeader, fullPayload))
        connection.publishForTesting(.frame(partialHeader, partialPayload))

        await fulfillment(of: [deliveredFrames], timeout: 1.0)
        XCTAssertEqual(deliveredSequences, [2])
        XCTAssertEqual(
            deliveredHeaders,
            [
                VNCFrameHeader(
                    sequence: 2,
                    x: 0,
                    y: 0,
                    width: 2,
                    height: 1,
                    framebufferWidth: 2,
                    framebufferHeight: 1,
                    stride: 8,
                    pixelFormat: .bgra8
                )
            ]
        )
        XCTAssertEqual(deliveredPayloads, [Data([1, 2, 3, 4, 9, 10, 11, 12])])
    }

    func testVNCPanelConnectionCoalescesComposedFramesWhenMainActorIsBehind() async {
        let session = MacfleetVNCSession(
            name: "mac3-1",
            hostName: "mac3",
            address: "mac3-1.local",
            port: 5901,
            username: "cmuxvnc",
            tag: "tag:mac-mini-cluster",
            index: 1
        )
        let credential = VNCResolvedCredential(
            username: "cmuxvnc",
            password: "password",
            source: .defaultPassword
        )
        let lastFrameDelivered = expectation(description: "latest VNC frame delivered")
        let frameCount = VNCPanelConnection.maxPendingFramesForTesting + 5
        var deliveredSequences: [UInt64] = []
        var deliveredPayloads: [Data] = []
        let connection = VNCPanelConnection(
            session: session,
            credential: credential,
            onControl: { _ in },
            onFrame: { header, payload in
                deliveredSequences.append(header.sequence)
                deliveredPayloads.append(payload)
                if header.sequence == UInt64(frameCount) {
                    lastFrameDelivered.fulfill()
                }
            },
            onExit: { _ in }
        )
        defer { connection.close() }

        let initialHeader = VNCFrameHeader(
            sequence: 1,
            x: 0,
            y: 0,
            width: 2,
            height: 1,
            framebufferWidth: 2,
            framebufferHeight: 1,
            stride: 8,
            pixelFormat: .bgra8
        )
        connection.publishForTesting(.frame(initialHeader, Data([0, 0, 0, 255, 0, 0, 0, 255])))

        for sequence in 2...frameCount {
            let x = sequence % 2 == 0 ? 0 : 1
            let header = VNCFrameHeader(
                sequence: UInt64(sequence),
                x: x,
                y: 0,
                width: 1,
                height: 1,
                framebufferWidth: 2,
                framebufferHeight: 1,
                stride: 4,
                pixelFormat: .bgra8
            )
            connection.publishForTesting(.frame(header, Data([UInt8(sequence), 0, 0, 255])))
        }

        await fulfillment(of: [lastFrameDelivered], timeout: 1.0)
        let latestEvenSequence = stride(from: frameCount, through: 2, by: -1).first { $0 % 2 == 0 } ?? 0
        let latestOddSequence = stride(from: frameCount, through: 3, by: -1).first { $0 % 2 != 0 } ?? 0
        XCTAssertEqual(deliveredSequences, [UInt64(frameCount)])
        XCTAssertEqual(
            deliveredPayloads,
            [Data([UInt8(latestEvenSequence), 0, 0, 255, UInt8(latestOddSequence), 0, 0, 255])]
        )
    }

    func testVNCNamedKeyParserPreservesSocketModifiers() throws {
        XCTAssertEqual(
            VNCPanel.namedKeyStroke(for: "ctrl-c"),
            VNCNamedKeyStroke(modifierKeyCodes: [59], keyCode: 8)
        )
        XCTAssertEqual(
            VNCPanel.namedKeyStroke(for: "ctrl+c"),
            VNCNamedKeyStroke(modifierKeyCodes: [59], keyCode: 8)
        )
        XCTAssertEqual(
            VNCPanel.namedKeyStroke(for: "sigint"),
            VNCNamedKeyStroke(modifierKeyCodes: [59], keyCode: 8)
        )
        XCTAssertEqual(
            VNCPanel.namedKeyStroke(for: "shift+tab"),
            VNCNamedKeyStroke(modifierKeyCodes: [56], keyCode: 48)
        )
        XCTAssertEqual(
            VNCPanel.namedKeyStroke(for: "cmd+return"),
            VNCNamedKeyStroke(modifierKeyCodes: [55], keyCode: 36)
        )
        XCTAssertEqual(
            VNCPanel.namedKeyStroke(for: "ctrl+page_up"),
            VNCNamedKeyStroke(modifierKeyCodes: [59], keyCode: 116)
        )
        XCTAssertNil(VNCPanel.namedKeyStroke(for: "ctrl+definitely-not-a-key"))
    }

    func testVNCKeyEquivalentForwardsRemoteCommandShortcut() throws {
        let view = VNCMetalCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var events: [String] = []
        view.onKey = { keyCode, isDown, text in
            events.append("\(keyCode):\(isDown ? "down" : "up"):\(text ?? "")")
        }
        defer {
            view.onKey = nil
            view.close()
        }

        let event = makeVNCKeyEvent(
            modifierFlags: [.command],
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8
        )

        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(events, ["55:down:", "8:down:c", "8:up:c", "55:up:"])
    }

    func testVNCKeyEquivalentDoesNotDuplicateAlreadyPressedModifier() throws {
        let view = VNCMetalCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var events: [String] = []
        view.onKey = { keyCode, isDown, text in
            events.append("\(keyCode):\(isDown ? "down" : "up"):\(text ?? "")")
        }
        defer {
            view.onKey = nil
            view.close()
        }

        view.flagsChanged(with: makeVNCKeyEvent(type: .flagsChanged, modifierFlags: [.command], keyCode: 55))
        events.removeAll()
        let event = makeVNCKeyEvent(
            modifierFlags: [.command],
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8
        )

        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(events, ["8:down:c", "8:up:c"])
    }

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

    private func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: path)
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return
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

    private nonisolated func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
