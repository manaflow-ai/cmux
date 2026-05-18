import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationCallerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testNotificationCreateForCallerResolvesStaleEnvToCallerTTY() async throws {
        let socketPath = makeSocketPath("notify-caller")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        let notificationQueued = expectation(description: "caller notification queued")
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in
            notificationQueued.fulfill()
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in
            notificationQueued.fulfill()
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.surfaceTTYNames[focusedPanelId] = "/dev/ttys777"

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "notification.create_for_caller",
            params: [
                "preferred_workspace_id": UUID().uuidString,
                "preferred_surface_id": UUID().uuidString,
                "caller_tty": "/dev/ttys777",
                "prefer_tty": false,
                "title": "Caller",
                "subtitle": "TTY",
                "body": "Body"
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["workspace_id"] as? String, workspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, focusedPanelId.uuidString)

        await fulfillment(of: [notificationQueued], timeout: 1.0)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testNotificationCreateForCallerResolvesPreferredRefs() async throws {
        let socketPath = makeSocketPath("notify-ref")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        let notificationQueued = expectation(description: "ref notification queued")
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in
            notificationQueued.fulfill()
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in
            notificationQueued.fulfill()
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let fallbackWorkspace = manager.addWorkspace(select: true)
        let targetWorkspace = manager.addWorkspace(select: false)
        defer {
            for workspace in [fallbackWorkspace, targetWorkspace] where manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)
        let targetPaneId = targetWorkspace.paneId(forPanelId: targetSurfaceId)?.id
        let refs = TerminalController.shared.v2WorkspacePaneAndSurfaceRefs(
            workspaceId: targetWorkspace.id,
            paneId: targetPaneId,
            surfaceId: targetSurfaceId
        )

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "notification.create_for_caller",
            params: [
                "preferred_workspace_id": refs.workspaceRef,
                "preferred_surface_id": refs.surfaceRef,
                "title": "Ref",
                "subtitle": "Preferred",
                "body": "Body"
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, targetSurfaceId.uuidString)

        await fulfillment(of: [notificationQueued], timeout: 1.0)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: targetWorkspace.id, surfaceId: targetSurfaceId))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: fallbackWorkspace.id, surfaceId: fallbackWorkspace.focusedPanelId))
    }

    func testNotificationCreateForCallerResolvesPreferredSurfaceWhenWorkspaceIsStale() async throws {
        let socketPath = makeSocketPath("notify-surface-ref")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        let notificationQueued = expectation(description: "surface notification queued")
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in
            notificationQueued.fulfill()
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in
            notificationQueued.fulfill()
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let fallbackWorkspace = manager.addWorkspace(select: true)
        let targetWorkspace = manager.addWorkspace(select: false)
        defer {
            for workspace in [fallbackWorkspace, targetWorkspace] where manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "notification.create_for_caller",
            params: [
                "preferred_workspace_id": UUID().uuidString,
                "preferred_surface_id": targetSurfaceId.uuidString,
                "title": "Surface",
                "subtitle": "Preferred",
                "body": "Body"
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, targetSurfaceId.uuidString)

        await fulfillment(of: [notificationQueued], timeout: 1.0)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: targetWorkspace.id, surfaceId: targetSurfaceId))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: fallbackWorkspace.id, surfaceId: fallbackWorkspace.focusedPanelId))
    }

    func testNotifyTargetUpdatesStoreBeforeResponseWhenAsyncDrainsAreSuspended() async throws {
        let socketPath = makeSocketPath("notify-sync")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false
        TerminalMutationBus.shared.setDrainsSuspendedForTesting(true)

        let workspace = manager.addWorkspace(select: true)
        defer {
            TerminalMutationBus.shared.setDrainsSuspendedForTesting(false)
            TerminalMutationBus.shared.drainForTesting()
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let command = "notify_target \(workspace.id.uuidString) \(focusedPanelId.uuidString) Sync|Read after write|Body"
        let responses = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.sendCommands([command], to: socketPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(responses, ["OK"])
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertEqual(store.notifications.first?.title, "Sync")

        store.replaceNotificationsForTesting([])
        let callerResponse = try await sendV2RequestAsync(
            method: "notification.create_for_caller",
            params: [
                "preferred_workspace_id": workspace.id.uuidString,
                "preferred_surface_id": focusedPanelId.uuidString,
                "title": "CallerSync",
                "subtitle": "Read after write",
                "body": "Body"
            ],
            to: socketPath
        )
        XCTAssertEqual(callerResponse["ok"] as? Bool, true, "\(callerResponse)")
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertEqual(store.notifications.first?.title, "CallerSync")
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnc-\(name.prefix(4))-\(shortID).sock")
            .path
    }

    private func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: path) },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed { return }
        XCTFail("Timed out waiting for socket at \(path)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    private nonisolated func sendV2Request(
        method: String,
        params: [String: Any],
        to socketPath: String
    ) throws -> [String: Any] {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        let responseLine = try sendCommands([line], to: socketPath).first
        let responseData = Data(try XCTUnwrap(responseLine).utf8)
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
                    continuation.resume(returning: try self.sendV2Request(method: method, params: params, to: socketPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated func sendCommands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket(AF_UNIX)") }
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
            for (index, byte) in bytes.enumerated() { cPath[index] = CChar(bitPattern: byte) }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addrLen) }
        }
        guard connectResult == 0 else { throw posixError("connect(\(socketPath))") }

        var responses: [String] = []
        for command in commands {
            try writeLine(command, to: fd)
            responses.append(try readLine(from: fd))
        }
        return responses
    }

    private nonisolated func writeLine(_ command: String, to fd: Int32) throws {
        let payload = Array((command + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let wrote = payload.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard wrote >= 0 else { throw posixError("write(\(command))") }
            offset += wrote
        }
    }

    private nonisolated func readLine(from fd: Int32) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 1)
        var data = Data()
        while true {
            let count = Darwin.read(fd, &buffer, 1)
            guard count >= 0 else { throw posixError("read") }
            if count == 0 || buffer[0] == 0x0A { break }
            data.append(buffer[0])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private nonisolated func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
