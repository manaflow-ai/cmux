import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationQueueTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testNotifyTargetAsyncQueuesNotificationForResolvedSurface() async throws {
        let socketPath = makeSocketPath("notify-async")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        let notificationQueued = expectation(description: "notification queued")
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

        let payload = "Async|Queued|Body"
        let command = "notify_target_async \(workspace.id.uuidString) \(focusedPanelId.uuidString) \(payload)"
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
        await fulfillment(of: [notificationQueued], timeout: 1.0)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testNotifyTargetAsyncRequiresPayload() {
        let args = "\(UUID().uuidString) \(UUID().uuidString)"
        let response = TerminalController.debugNotifyTargetQueuedResponseForTesting(args)

        XCTAssertEqual(
            response,
            "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        )
    }

    func testClearNotificationsDropsQueuedNotifyBeforeDrain() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredTitles: [String] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredTitles.append(notification.title)
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
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Async",
            subtitle: "Queued",
            body: "Body"
        )
        store.clearNotifications(forTabId: workspace.id)
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertFalse(store.notifications.contains { $0.tabId == workspace.id })
        XCTAssertEqual(deliveredTitles, [])
    }

    func testClearNotificationsIsBoundaryForFreshNotify() async throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
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
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Stale",
            subtitle: "Before clear",
            body: "Body"
        )
        TerminalMutationBus.shared.enqueueClearNotifications(forTabId: workspace.id)
        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Fresh",
            subtitle: "After clear",
            body: "Body"
        )

        TerminalMutationBus.shared.drainForTesting()

        let workspaceNotifications = store.notifications.filter { $0.tabId == workspace.id }
        XCTAssertEqual(workspaceNotifications.map(\.title), ["Fresh"])
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testQueuedClearAllDropsOnlyOlderQueuedNotify() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredTitles: [String] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredTitles.append(notification.title)
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
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Stale",
            subtitle: "Before clear",
            body: "Body"
        )
        TerminalMutationBus.shared.enqueueClearAllNotifications()
        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Fresh",
            subtitle: "After clear",
            body: "Body"
        )
        TerminalMutationBus.shared.drainForTesting()

        let workspaceNotifications = store.notifications.filter { $0.tabId == workspace.id }
        XCTAssertEqual(workspaceNotifications.map(\.title), ["Fresh"])
        XCTAssertEqual(deliveredTitles, ["Fresh"])
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testQueuedNotificationCoalescesRepeatedEventsForSameSurface() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredTitles: [String] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredTitles.append(notification.title)
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
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalMutationBus.shared.setDrainsSuspendedForTesting(true)
        defer { TerminalMutationBus.shared.setDrainsSuspendedForTesting(false) }
        for title in ["First", "Second"] {
            TerminalMutationBus.shared.enqueueNotification(
                tabId: workspace.id,
                surfaceId: focusedPanelId,
                title: title,
                subtitle: "Same target",
                body: "Body"
            )
            if title == "First" { TerminalMutationBus.shared.enqueueMainActorMutation {} }
        }
        TerminalMutationBus.shared.drainForTesting()
        let workspaceNotifications = store.notifications.filter { $0.tabId == workspace.id }
        XCTAssertEqual(workspaceNotifications.map(\.title), ["Second"])
        XCTAssertEqual(deliveredTitles, ["Second"])
    }

    func testScopedDiscardDoesNotSplitUnrelatedNotificationCoalescing() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredTitles: [String] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredTitles.append(notification.title)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let clearedWorkspace = manager.addWorkspace(select: true)
        let unrelatedWorkspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == clearedWorkspace.id }) {
                manager.closeWorkspace(clearedWorkspace)
            }
            if manager.tabs.contains(where: { $0.id == unrelatedWorkspace.id }) {
                manager.closeWorkspace(unrelatedWorkspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let clearedPanelId = clearedWorkspace.focusedPanelId,
              let unrelatedPanelId = unrelatedWorkspace.focusedPanelId else {
            XCTFail("Expected workspaces with focused panels")
            return
        }

        TerminalMutationBus.shared.setDrainsSuspendedForTesting(true)
        defer { TerminalMutationBus.shared.setDrainsSuspendedForTesting(false) }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: unrelatedWorkspace.id,
            surfaceId: unrelatedPanelId,
            title: "Stale unrelated",
            subtitle: "Before scoped discard",
            body: "Body"
        )
        TerminalMutationBus.shared.discardPendingNotifications(
            forTabId: clearedWorkspace.id,
            surfaceId: clearedPanelId
        )
        TerminalMutationBus.shared.enqueueNotification(
            tabId: unrelatedWorkspace.id,
            surfaceId: unrelatedPanelId,
            title: "Fresh unrelated",
            subtitle: "After scoped discard",
            body: "Body"
        )

        TerminalMutationBus.shared.drainForTesting()

        let unrelatedNotifications = store.notifications.filter { $0.tabId == unrelatedWorkspace.id }
        XCTAssertEqual(unrelatedNotifications.map(\.title), ["Fresh unrelated"])
        XCTAssertEqual(deliveredTitles, ["Fresh unrelated"])
    }

    func testQueuedNotificationResolvesWorkspaceInRegisteredWindowContext() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let activeManager = TabManager()
        let targetManager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = activeManager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: targetManager)
        let workspace = targetManager.addWorkspace(select: true)
        defer {
            if targetManager.tabs.contains(where: { $0.id == workspace.id }) {
                targetManager.closeWorkspace(workspace)
            }
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Async",
            subtitle: "Queued",
            body: "Body"
        )
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testUnregisterMainWindowContextForTestingRepointsActiveContext() {
        let appDelegate = AppDelegate()

        let managerA = TabManager()
        let managerB = TabManager()
        let windowAId = appDelegate.registerMainWindowContextForTesting(tabManager: managerA)
        let windowBId = appDelegate.registerMainWindowContextForTesting(tabManager: managerB)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowAId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowBId)
            appDelegate.tabManager = nil
            appDelegate.sidebarState = nil
            appDelegate.sidebarSelectionState = nil
            appDelegate.fileExplorerState = nil
            TerminalController.shared.setActiveTabManager(nil)
        }

        appDelegate.tabManager = managerA
        TerminalController.shared.setActiveTabManager(managerA)

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowAId)

        XCTAssertTrue(appDelegate.tabManager === managerB)
        XCTAssertNotNil(appDelegate.sidebarState)
        XCTAssertNotNil(appDelegate.sidebarSelectionState)

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowBId)

        XCTAssertNil(appDelegate.tabManager)
        XCTAssertNil(appDelegate.sidebarState)
        XCTAssertNil(appDelegate.sidebarSelectionState)
        XCTAssertNil(appDelegate.fileExplorerState)
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnq-\(name.prefix(4))-\(shortID).sock")
            .path
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

    private nonisolated func sendCommands(_ commands: [String], to socketPath: String) throws -> [String] {
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
