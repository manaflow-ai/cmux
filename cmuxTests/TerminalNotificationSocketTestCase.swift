import AppKit
import Darwin
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
class TerminalNotificationSocketTestCase {
    init() {
        TerminalController.shared.stop()
    }

    struct SocketFixture {
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

    func makeSocketFixture(name: String, includeWindow: Bool = false) throws -> SocketFixture {
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
        let surfaceId = try #require(workspace.focusedPanelId)

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

    func makeNotification(
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

    func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("socket-\(name.prefix(12))-\(shortID).sock")
            .path
    }

    func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let message = "Socket did not appear at \(path) within \(timeout)s"
        Issue.record(message)
        throw NSError(
            domain: "TerminalNotificationSocketActionTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func sendV2RequestAsync(
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

    nonisolated static func makeV2RequestData(
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

    nonisolated static func sendV2Request(
        data: Data,
        to socketPath: String
    ) throws -> [String: Any] {
        let line = String(data: data, encoding: .utf8) ?? "{}"
        return try sendCommands([line], to: socketPath).compactMap { response in
            guard let data = response.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        }.first ?? [:]
    }

    nonisolated static func sendCommands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        var responses: [String] = []
        for command in commands {
            try writeLine(command, fd: fd)
            responses.append(try readLine(fd: fd))
        }
        return responses
    }

    nonisolated static func connect(to socketPath: String) throws -> Int32 {
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

    nonisolated static func writeLine(_ line: String, fd: Int32) throws {
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

    nonisolated static func readLine(fd: Int32) throws -> String {
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

    nonisolated static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
