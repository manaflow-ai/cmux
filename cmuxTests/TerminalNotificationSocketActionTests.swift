import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationSocketActionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testNotificationDismissRemovesSingleNotification() async throws {
        let fixture = try makeSocketFixture(name: "notif-dismiss")
        defer { fixture.cleanup() }

        let target = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Dismiss")
        let sibling = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Keep")
        fixture.store.replaceNotificationsForTesting([target, sibling])

        let response = try await sendV2RequestAsync(
            method: "notification.dismiss",
            params: ["id": target.id.uuidString],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["dismissed"] as? Int, 1)
        XCTAssertFalse(fixture.store.notifications.contains(where: { $0.id == target.id }))
        XCTAssertTrue(fixture.store.notifications.contains(where: { $0.id == sibling.id }))
    }

    func testNotificationDismissAllReadRemovesOnlyReadNotifications() async throws {
        let fixture = try makeSocketFixture(name: "notif-dismiss-read")
        defer { fixture.cleanup() }

        let firstRead = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Read 1", isRead: true)
        let secondRead = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Read 2", isRead: true)
        let unread = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Unread")
        fixture.store.replaceNotificationsForTesting([firstRead, secondRead, unread])

        let response = try await sendV2RequestAsync(
            method: "notification.dismiss",
            params: ["all_read": true],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["dismissed"] as? Int, 2)
        XCTAssertEqual(result["all_read"] as? Bool, true)
        XCTAssertFalse(fixture.store.notifications.contains(where: { $0.id == firstRead.id }))
        XCTAssertFalse(fixture.store.notifications.contains(where: { $0.id == secondRead.id }))
        XCTAssertTrue(fixture.store.notifications.contains(where: { $0.id == unread.id }))
    }

    func testNotificationMarkReadSupportsIdTabSurfaceAndAllSelectors() async throws {
        let fixture = try makeSocketFixture(name: "notif-read")
        defer { fixture.cleanup() }

        let idTarget = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "By ID")
        let surfaceTarget = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "By Surface")
        let otherSurface = UUID()
        let surfaceSibling = makeNotification(tabId: fixture.workspace.id, surfaceId: otherSurface, title: "Other Surface")
        let allTarget = makeNotification(tabId: UUID(), surfaceId: nil, title: "All")
        fixture.store.replaceNotificationsForTesting([idTarget, surfaceTarget, surfaceSibling, allTarget])

        var response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: ["id": idTarget.id.uuidString],
            to: fixture.socketPath
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertEqual(fixture.notification(idTarget.id)?.isRead, true)
        XCTAssertEqual(fixture.notification(surfaceTarget.id)?.isRead, false)

        response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: [
                "tab_id": fixture.workspace.id.uuidString,
                "surface_id": fixture.surfaceId.uuidString,
            ],
            to: fixture.socketPath
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertEqual(fixture.notification(surfaceTarget.id)?.isRead, true)
        XCTAssertEqual(fixture.notification(surfaceSibling.id)?.isRead, false)

        response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: ["all": true],
            to: fixture.socketPath
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertTrue(fixture.store.notifications.allSatisfy(\.isRead))

        response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: [
                "id": idTarget.id.uuidString,
                "surface_id": fixture.surfaceId.uuidString,
            ],
            to: fixture.socketPath
        )
        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
    }

    func testNotificationMarkReadRejectsUnknownId() async throws {
        let fixture = try makeSocketFixture(name: "notif-read-missing")
        defer { fixture.cleanup() }

        let missingId = UUID()
        let response = try await sendV2RequestAsync(
            method: "notification.mark_read",
            params: ["id": missingId.uuidString],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "not_found")
        XCTAssertEqual(error["message"] as? String, "Notification not found")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["id"] as? String, missingId.uuidString)
    }

    func testNotificationOpenFocusesDestinationAndMarksRead() async throws {
        let fixture = try makeSocketFixture(name: "notif-open", includeWindow: true)
        defer { fixture.cleanup() }

        let targetWorkspace = fixture.manager.addWorkspace(title: "Open Target", select: false)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)
        let notification = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Open")
        fixture.store.replaceNotificationsForTesting([notification])
        fixture.manager.selectTab(fixture.workspace)

        let response = try await sendV2RequestAsync(
            method: "notification.open",
            params: ["id": notification.id.uuidString],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["opened"] as? Bool, true)
        XCTAssertEqual(result["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, targetSurfaceId.uuidString)
        XCTAssertEqual(result["is_read"] as? Bool, true)
        XCTAssertEqual(fixture.manager.selectedTabId, targetWorkspace.id)
        XCTAssertEqual(fixture.manager.focusedSurfaceId(for: targetWorkspace.id), targetSurfaceId)
        XCTAssertEqual(fixture.notification(notification.id)?.isRead, true)
    }

    func testNotificationJumpToUnreadOpensLatestUnreadAndNoOpsWhenNoneRemain() async throws {
        let fixture = try makeSocketFixture(name: "notif-jump", includeWindow: true)
        defer { fixture.cleanup() }

        let targetWorkspace = fixture.manager.addWorkspace(title: "Unread Target", select: false)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)
        let older = makeNotification(tabId: fixture.workspace.id, surfaceId: fixture.surfaceId, title: "Older")
        let latest = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Latest")
        fixture.store.replaceNotificationsForTesting([latest, older])
        fixture.manager.selectTab(fixture.workspace)

        var response = try await sendV2RequestAsync(
            method: "notification.jump_to_unread",
            params: [:],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        var result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["opened"] as? Bool, true)
        XCTAssertEqual(result["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, targetSurfaceId.uuidString)
        XCTAssertEqual(result["is_read"] as? Bool, true)
        XCTAssertEqual(fixture.manager.selectedTabId, targetWorkspace.id)
        XCTAssertEqual(fixture.manager.focusedSurfaceId(for: targetWorkspace.id), targetSurfaceId)
        XCTAssertEqual(fixture.notification(latest.id)?.isRead, true)

        fixture.store.markAllRead()
        let selectedBeforeNoop = fixture.manager.selectedTabId
        let focusedBeforeNoop = fixture.manager.focusedSurfaceId(for: targetWorkspace.id)

        response = try await sendV2RequestAsync(
            method: "notification.jump_to_unread",
            params: [:],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["opened"] as? Bool, false)
        XCTAssertEqual(fixture.manager.selectedTabId, selectedBeforeNoop)
        XCTAssertEqual(fixture.manager.focusedSurfaceId(for: targetWorkspace.id), focusedBeforeNoop)
    }

    func testNotificationJumpToUnreadPayloadMatchesOpenedFallbackNotification() async throws {
        let fixture = try makeSocketFixture(name: "notif-jump-skip", includeWindow: true)
        defer { fixture.cleanup() }

        let targetWorkspace = fixture.manager.addWorkspace(title: "Unread Fallback", select: false)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)
        let unopenable = makeNotification(tabId: UUID(), surfaceId: nil, title: "Closed Workspace")
        let openable = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Openable")
        fixture.store.replaceNotificationsForTesting([unopenable, openable])
        fixture.manager.selectTab(fixture.workspace)

        let response = try await sendV2RequestAsync(
            method: "notification.jump_to_unread",
            params: [:],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["opened"] as? Bool, true)
        XCTAssertEqual(result["id"] as? String, openable.id.uuidString)
        XCTAssertEqual(result["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, targetSurfaceId.uuidString)
        XCTAssertEqual(fixture.manager.selectedTabId, targetWorkspace.id)
        XCTAssertEqual(fixture.notification(openable.id)?.isRead, true)
    }

    private struct SocketFixture {
        let socketPath: String
        let store: TerminalNotificationStore
        let appDelegate: AppDelegate
        let previousShared: AppDelegate?
        let manager: TabManager
        let workspace: Workspace
        let surfaceId: UUID
        let windowId: UUID?
        let window: NSWindow?
        let originalTabManager: TabManager?
        let originalNotificationStore: TerminalNotificationStore?
        let originalAppFocusOverride: Bool?

        @MainActor
        func notification(_ id: UUID) -> TerminalNotification? {
            store.notifications.first(where: { $0.id == id })
        }

        @MainActor
        func cleanup() {
            TerminalController.shared.stop()
            if let windowId {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }
            window?.close()
            for workspace in manager.tabs {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            AppDelegate.shared = previousShared
            unlink(socketPath)
        }
    }

    private func makeSocketFixture(name: String, includeWindow: Bool = false) throws -> SocketFixture {
        let socketPath = makeSocketPath(name)
        let store = TerminalNotificationStore.shared
        let previousShared = AppDelegate.shared
        let appDelegate = previousShared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        AppDelegate.shared = appDelegate
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(title: "Socket Notifications", select: true)
        let surfaceId = try XCTUnwrap(workspace.focusedPanelId)

        let windowId: UUID?
        let window: NSWindow?
        if includeWindow {
            let registeredWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            let testWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            testWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(registeredWindowId.uuidString)")
            testWindow.makeKeyAndOrderFront(nil)
            windowId = registeredWindowId
            window = testWindow
        } else {
            windowId = nil
            window = nil
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        return SocketFixture(
            socketPath: socketPath,
            store: store,
            appDelegate: appDelegate,
            previousShared: previousShared,
            manager: manager,
            workspace: workspace,
            surfaceId: surfaceId,
            windowId: windowId,
            window: window,
            originalTabManager: originalTabManager,
            originalNotificationStore: originalNotificationStore,
            originalAppFocusOverride: originalAppFocusOverride
        )
    }

    private func makeNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        isRead: Bool = false
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: "socket-test",
            body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_888_888),
            isRead: isRead
        )
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("socket-\(name.prefix(12))-\(shortID).sock")
            .path
    }

    private func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let message = "Socket did not appear at \(path) within \(timeout)s"
        XCTFail(message)
        throw NSError(
            domain: "TerminalNotificationSocketActionTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func sendV2RequestAsync(
        method: String,
        params: [String: Any] = [:],
        to socketPath: String
    ) async throws -> [String: Any] {
        let requestData = try Self.makeV2RequestData(method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.sendV2Request(data: requestData, to: socketPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func makeV2RequestData(
        method: String,
        params: [String: Any]
    ) throws -> Data {
        let payload: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private nonisolated static func sendV2Request(
        data: Data,
        to socketPath: String
    ) throws -> [String: Any] {
        let line = String(data: data, encoding: .utf8) ?? "{}"
        return try sendCommands([line], to: socketPath).compactMap { response in
            guard let data = response.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        }.first ?? [:]
    }

    private nonisolated static func sendCommands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        var responses: [String] = []
        for command in commands {
            try writeLine(command, fd: fd)
            responses.append(try readLine(fd: fd))
        }
        return responses
    }

    private nonisolated static func connect(to socketPath: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(socketPath.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            throw posixError(err)
        }
        return fd
    }

    private nonisolated static func writeLine(_ line: String, fd: Int32) throws {
        var data = Data(line.utf8)
        data.append(0x0A)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                offset += written
            }
        }
    }

    private nonisolated static func readLine(fd: Int32) throws -> String {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(errno)
            }
            if count == 0 { break }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private nonisolated static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
