import XCTest
import AppKit
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalControllerSocketSecurityTests: XCTestCase {
    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("csec-\(name.prefix(4))-\(shortID).sock")
            .path
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

        let moveWorkspace = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.move_to_window",
            isV2: true
        )
        XCTAssertTrue(moveWorkspace.insideSuppressed)
        XCTAssertFalse(moveWorkspace.insideAllowsFocus)

        let triggerFlash = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "surface.trigger_flash",
            isV2: true
        )
        XCTAssertTrue(triggerFlash.insideSuppressed)
        XCTAssertFalse(triggerFlash.insideAllowsFocus)
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
