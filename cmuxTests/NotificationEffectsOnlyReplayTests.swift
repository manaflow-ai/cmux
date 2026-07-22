import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class NotificationEffectsOnlyReplayTests: XCTestCase {
    func testRecordedIdReplayCannotReachEffectsOnlyDelivery() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fileManager = FileManager.default
            let temporaryDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("cmux-notification-replay-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: temporaryDirectory) }

            let markerURL = temporaryDirectory.appendingPathComponent("hook-finished")
            let configURL = temporaryDirectory.appendingPathComponent("cmux.json")
            let hookCommand = "sed 's/\"record\":true/\"record\":false/' ; touch '\(markerURL.path)'"
            let config: [String: Any] = [
                "notifications": [
                    "hooks": [["id": "effects-only-replay", "command": hookCommand]],
                ],
            ]
            try JSONSerialization.data(withJSONObject: config).write(to: configURL)

            let markerObserved = expectation(description: "effects-only hook completed")
            let directoryDescriptor = open(temporaryDirectory.path, O_EVTONLY)
            XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
            let markerSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: directoryDescriptor,
                eventMask: .write,
                queue: .global(qos: .userInitiated)
            )
            markerSource.setEventHandler {
                guard fileManager.fileExists(atPath: markerURL.path) else { return }
                markerObserved.fulfill()
                markerSource.cancel()
            }
            markerSource.setCancelHandler { close(directoryDescriptor) }
            markerSource.resume()
            defer { markerSource.cancel() }

            let appDelegate = AppDelegate.shared ?? AppDelegate()
            let manager = TabManager()
            let workspace = manager.addWorkspace(select: true)
            let configStore = CmuxConfigStore(
                globalConfigPath: configURL.path,
                startFileWatchers: false
            )
            configStore.loadAll()
            let windowId = appDelegate.registerMainWindowContextForTesting(
                tabManager: manager,
                cmuxConfigStore: configStore
            )
            let store = TerminalNotificationStore.shared
            let originalNotificationStore = appDelegate.notificationStore
            let originalAppFocusOverride = AppFocusState.overrideIsFocused
            let replayId = UUID()
            let original = TerminalNotification(
                id: replayId,
                tabId: workspace.id,
                surfaceId: nil,
                title: "Original",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: 1),
                isRead: false
            )
            defer {
                store.replaceNotificationsForTesting([])
                store.resetNotificationDeliveryHandlerForTesting()
                store.resetSuppressedNotificationFeedbackHandlerForTesting()
                appDelegate.notificationStore = originalNotificationStore
                AppFocusState.overrideIsFocused = originalAppFocusOverride
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }

            appDelegate.notificationStore = store
            AppFocusState.overrideIsFocused = false
            store.replaceNotificationsForTesting([original])
            let replayDelivered = expectation(description: "duplicate id must not deliver effects again")
            replayDelivered.isInverted = true
            store.configureNotificationDeliveryHandlerForTesting { _, notification in
                guard notification.id == replayId else { return }
                replayDelivered.fulfill()
            }
            store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }

            store.addNotification(
                id: replayId,
                acceptedAt: Date(timeIntervalSince1970: 2),
                tabId: workspace.id,
                surfaceId: nil,
                title: "Replay",
                subtitle: "",
                body: ""
            )

            await fulfillment(of: [markerObserved, replayDelivered], timeout: 3)
            XCTAssertEqual(store.notifications, [original])
        }
    }
}
