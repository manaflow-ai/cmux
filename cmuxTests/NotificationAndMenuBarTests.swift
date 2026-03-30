import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppIconSettingsTests: XCTestCase {
    func testApplyDarkSetsRuntimeIconAndNotifiesDockTilePlugin() {
        let expectedIcon = NSImage(size: NSSize(width: 16, height: 16))
        var receivedRuntimeIcon: NSImage?
        var dockTileNotificationCount = 0
        var startObservationCallCount = 0
        var stopObservationCallCount = 0

        let environment = AppIconSettings.Environment(
            imageForMode: { mode in
                XCTAssertEqual(mode, .dark)
                return expectedIcon
            },
            setApplicationIconImage: { icon in
                receivedRuntimeIcon = icon
            },
            startAppearanceObservation: {
                startObservationCallCount += 1
            },
            stopAppearanceObservation: {
                stopObservationCallCount += 1
            },
            notifyDockTilePlugin: {
                dockTileNotificationCount += 1
            }
        )

        AppIconSettings.applyIcon(.dark, environment: environment)

        XCTAssertTrue(receivedRuntimeIcon === expectedIcon)
        XCTAssertEqual(dockTileNotificationCount, 1)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 1)
    }

    func testApplyAutomaticStartsObservationAndNotifiesDockTilePlugin() {
        var dockTileNotificationCount = 0
        var startObservationCallCount = 0
        var stopObservationCallCount = 0

        let environment = AppIconSettings.Environment(
            imageForMode: { mode in
                XCTFail("Automatic mode should not request a manual icon image: \(mode.rawValue)")
                return nil
            },
            setApplicationIconImage: { _ in
                XCTFail("Automatic mode should delegate live updates to the appearance observer")
            },
            startAppearanceObservation: {
                startObservationCallCount += 1
            },
            stopAppearanceObservation: {
                stopObservationCallCount += 1
            },
            notifyDockTilePlugin: {
                dockTileNotificationCount += 1
            }
        )

        AppIconSettings.applyIcon(.automatic, environment: environment)

        XCTAssertEqual(dockTileNotificationCount, 1)
        XCTAssertEqual(startObservationCallCount, 1)
        XCTAssertEqual(stopObservationCallCount, 0)
    }
}

@MainActor
final class NotificationDockBadgeTests: XCTestCase {
    private final class NotificationSettingsAlertSpy: NSAlert {
        private(set) var beginSheetModalCallCount = 0
        private(set) var runModalCallCount = 0
        var nextResponse: NSApplication.ModalResponse = .alertFirstButtonReturn

        override func beginSheetModal(
            for sheetWindow: NSWindow,
            completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
        ) {
            beginSheetModalCallCount += 1
            handler?(nextResponse)
        }

        override func runModal() -> NSApplication.ModalResponse {
            runModalCallCount += 1
            return nextResponse
        }
    }

    override func tearDown() {
        TerminalNotificationStore.shared.resetNotificationSettingsPromptHooksForTesting()
        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
        TerminalNotificationStore.shared.resetNotificationDeliveryHandlerForTesting()
        TerminalNotificationStore.shared.resetSuppressedNotificationFeedbackHandlerForTesting()
        super.tearDown()
    }

    func testDockBadgeLabelEnabledAndCounted() {
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 1, isEnabled: true), "1")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 42, isEnabled: true), "42")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 100, isEnabled: true), "99+")
    }

    func testDockBadgeLabelHiddenWhenDisabledOrZero() {
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true))
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 5, isEnabled: false))
    }

    func testDockBadgeLabelShowsRunTagEvenWithoutUnread() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true, runTag: "verify-tag"),
            "verify-tag"
        )
    }

    func testDockBadgeLabelCombinesRunTagAndUnreadCount() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 7, isEnabled: true, runTag: "verify"),
            "verify:7"
        )
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 120, isEnabled: true, runTag: "verify"),
            "verify:99+"
        )
    }

    func testNotificationBadgePreferenceDefaultsToEnabled() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(false, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertFalse(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(true, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))
    }

    func testNotificationPaneFlashPreferenceDefaultsToEnabled() {
        let suiteName = "NotificationPaneFlashSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationPaneFlashSettings.isEnabled(defaults: defaults))

        defaults.set(false, forKey: NotificationPaneFlashSettings.enabledKey)
        XCTAssertFalse(NotificationPaneFlashSettings.isEnabled(defaults: defaults))

        defaults.set(true, forKey: NotificationPaneFlashSettings.enabledKey)
        XCTAssertTrue(NotificationPaneFlashSettings.isEnabled(defaults: defaults))
    }

    func testMenuBarExtraPreferenceDefaultsToVisible() {
        let suiteName = "MenuBarExtraVisibilityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(MenuBarExtraSettings.showsMenuBarExtra(defaults: defaults))

        defaults.set(false, forKey: MenuBarExtraSettings.showInMenuBarKey)
        XCTAssertFalse(MenuBarExtraSettings.showsMenuBarExtra(defaults: defaults))

        defaults.set(true, forKey: MenuBarExtraSettings.showInMenuBarKey)
        XCTAssertTrue(MenuBarExtraSettings.showsMenuBarExtra(defaults: defaults))
    }

    func testNotificationSoundUsesSystemSoundForDefaultAndNamedSounds() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationSoundSettings.usesSystemSound(defaults: defaults))

        defaults.set("Ping", forKey: NotificationSoundSettings.key)
        XCTAssertTrue(NotificationSoundSettings.usesSystemSound(defaults: defaults))
        XCTAssertNotNil(NotificationSoundSettings.sound(defaults: defaults))
    }

    func testNotificationSoundDisablesSystemSoundForNoneAndCustomFile() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("none", forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.usesSystemSound(defaults: defaults))
        XCTAssertNil(NotificationSoundSettings.sound(defaults: defaults))

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.usesSystemSound(defaults: defaults))
        XCTAssertNil(NotificationSoundSettings.sound(defaults: defaults))
    }

    func testNotificationCustomFileURLExpandsTildePath() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let rawPath = "~/Library/Sounds/my-custom.wav"
        defaults.set(rawPath, forKey: NotificationSoundSettings.customFilePathKey)
        let expectedPath = (rawPath as NSString).expandingTildeInPath
        XCTAssertEqual(NotificationSoundSettings.customFileURL(defaults: defaults)?.path, expectedPath)
    }

    func testNotificationCustomFileSelectionMustBeExplicit() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("~/Library/Sounds/my-custom.wav", forKey: NotificationSoundSettings.customFilePathKey)

        defaults.set("none", forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.isCustomFileSelected(defaults: defaults))

        defaults.set("Ping", forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.isCustomFileSelected(defaults: defaults))

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        XCTAssertTrue(NotificationSoundSettings.isCustomFileSelected(defaults: defaults))
    }

    func testNotificationCustomStagingPreservesSourceFileWithCmuxPrefix() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let soundsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        do {
            try fileManager.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create sounds directory: \(error)")
            return
        }

        let sourceURL = soundsDirectory.appendingPathComponent(
            "cmux-custom-notification-sound.source-\(UUID().uuidString).wav",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: sourceURL)
        }

        do {
            try Data("test".utf8).write(to: sourceURL, options: .atomic)
        } catch {
            XCTFail("Failed to write source custom sound file: \(error)")
            return
        }

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(sourceURL.path, forKey: NotificationSoundSettings.customFilePathKey)

        _ = NotificationSoundSettings.sound(defaults: defaults)

        guard let stagedName = NotificationSoundSettings.stagedCustomSoundName(defaults: defaults) else {
            XCTFail("Expected staged custom sound name")
            return
        }
        let stagedURL = soundsDirectory.appendingPathComponent(stagedName, isDirectory: false)
        defer {
            try? fileManager.removeItem(at: stagedURL)
        }

        XCTAssertTrue(fileManager.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(stagedName.hasPrefix("cmux-custom-notification-sound-"))
        XCTAssertTrue(stagedName.hasSuffix(".wav"))
    }

    func testNotificationCustomUnsupportedExtensionsStageAsCaf() {
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "mp3"),
            "caf"
        )
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "M4A"),
            "caf"
        )
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "wav"),
            "wav"
        )
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "AIFF"),
            "aiff"
        )

        let sourceA = URL(fileURLWithPath: "/tmp/custom-a.mp3")
        let sourceB = URL(fileURLWithPath: "/tmp/custom-b.mp3")
        let stagedA = NotificationSoundSettings.stagedCustomSoundFileName(
            forSourceURL: sourceA,
            destinationExtension: "caf"
        )
        let stagedB = NotificationSoundSettings.stagedCustomSoundFileName(
            forSourceURL: sourceB,
            destinationExtension: "caf"
        )
        XCTAssertNotEqual(stagedA, stagedB)
        XCTAssertTrue(stagedA.hasPrefix("cmux-custom-notification-sound-"))
        XCTAssertTrue(stagedA.hasSuffix(".caf"))
    }

    func testNotificationCustomPreparationKeepsActiveSourceMetadataSidecar() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let soundsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        do {
            try fileManager.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create sounds directory: \(error)")
            return
        }

        let sourceURL = soundsDirectory.appendingPathComponent(
            "cmux-custom-notification-sound.metadata-\(UUID().uuidString).wav",
            isDirectory: false
        )
        do {
            try Data("test".utf8).write(to: sourceURL, options: .atomic)
        } catch {
            XCTFail("Failed to write source custom sound file: \(error)")
            return
        }
        defer {
            try? fileManager.removeItem(at: sourceURL)
        }

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(sourceURL.path, forKey: NotificationSoundSettings.customFilePathKey)

        let prepareResult = NotificationSoundSettings.prepareCustomFileForNotifications(path: sourceURL.path)
        let stagedName: String
        switch prepareResult {
        case .success(let name):
            stagedName = name
        case .failure(let issue):
            XCTFail("Expected custom sound preparation success, got \(issue)")
            return
        }

        let stagedURL = soundsDirectory.appendingPathComponent(stagedName, isDirectory: false)
        let metadataURL = stagedURL.appendingPathExtension("source-metadata")
        defer {
            try? fileManager.removeItem(at: stagedURL)
            try? fileManager.removeItem(at: metadataURL)
        }

        XCTAssertTrue(fileManager.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: metadataURL.path))
    }

    func testNotificationCustomSoundReturnsNilWhenPreparationFails() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let invalidSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-invalid-sound-\(UUID().uuidString).mp3", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: invalidSourceURL)
            let stagedURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Sounds", isDirectory: true)
                .appendingPathComponent("cmux-custom-notification-sound.caf", isDirectory: false)
            try? FileManager.default.removeItem(at: stagedURL)
        }

        do {
            try Data("not-audio".utf8).write(to: invalidSourceURL, options: .atomic)
        } catch {
            XCTFail("Failed to write invalid custom sound source: \(error)")
            return
        }

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(invalidSourceURL.path, forKey: NotificationSoundSettings.customFilePathKey)

        XCTAssertNil(NotificationSoundSettings.sound(defaults: defaults))
    }

    func testNotificationCustomPreparationReportsMissingFile() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-missing-\(UUID().uuidString).wav", isDirectory: false)
            .path

        let result = NotificationSoundSettings.prepareCustomFileForNotifications(path: missingPath)
        switch result {
        case .success:
            XCTFail("Expected missing file failure")
        case .failure(let issue):
            guard case .missingFile = issue else {
                XCTFail("Expected missingFile issue, got \(issue)")
                return
            }
        }
    }

    func testFocusedTerminalNotificationStillRunsLocalSoundFeedbackWhenExternalDeliveryIsSuppressed() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("AppDelegate.shared must be set for this test")
            return
        }
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredNotificationIDs: [UUID] = []
        var localFeedbackNotificationIDs: [UUID] = []

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotificationIDs.append(notification.id)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, notification in
            localFeedbackNotificationIDs.append(notification.id)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected selected workspace with a focused terminal panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )

        let createdNotificationID = try XCTUnwrap(store.notifications.first?.id)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        XCTAssertTrue(deliveredNotificationIDs.isEmpty)
        XCTAssertEqual(localFeedbackNotificationIDs.count, 1)
        XCTAssertEqual(localFeedbackNotificationIDs, [createdNotificationID])
    }

    func testFocusedTerminalSuppressedNotificationRunsCustomCommand() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("AppDelegate.shared must be set for this test")
            return
        }
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard
        let commandOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-notification-command-\(UUID().uuidString).txt", isDirectory: false)

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let hadSoundValue = defaults.object(forKey: NotificationSoundSettings.key) != nil
        let originalSoundValue = defaults.object(forKey: NotificationSoundSettings.key)
        let hadCommandValue = defaults.object(forKey: NotificationSoundSettings.customCommandKey) != nil
        let originalCommandValue = defaults.object(forKey: NotificationSoundSettings.customCommandKey)

        var deliveredNotificationIDs: [UUID] = []

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotificationIDs.append(notification.id)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set("none", forKey: NotificationSoundSettings.key)
        defaults.set(
            "printf '%s\\n%s\\n%s' \"$CMUX_NOTIFICATION_TITLE\" \"$CMUX_NOTIFICATION_SUBTITLE\" \"$CMUX_NOTIFICATION_BODY\" > '\(commandOutputURL.path)'",
            forKey: NotificationSoundSettings.customCommandKey
        )

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if hadSoundValue {
                defaults.set(originalSoundValue, forKey: NotificationSoundSettings.key)
            } else {
                defaults.removeObject(forKey: NotificationSoundSettings.key)
            }
            if hadCommandValue {
                defaults.set(originalCommandValue, forKey: NotificationSoundSettings.customCommandKey)
            } else {
                defaults.removeObject(forKey: NotificationSoundSettings.customCommandKey)
            }
            try? FileManager.default.removeItem(at: commandOutputURL)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected selected workspace with a focused terminal panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "",
            subtitle: "Focused subtitle",
            body: "Focused body"
        )

        let commandFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: commandOutputURL.path)
            },
            object: NSObject()
        )
        XCTAssertEqual(XCTWaiter().wait(for: [commandFinished], timeout: 2.0), .completed)
        XCTAssertTrue(deliveredNotificationIDs.isEmpty)

        let output = try String(contentsOf: commandOutputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedTitle = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
        XCTAssertEqual(output.components(separatedBy: "\n"), [expectedTitle, "Focused subtitle", "Focused body"])
    }

    func testNotificationAuthorizationStateMappingCoversKnownUNAuthorizationStatuses() {
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .notDetermined), .notDetermined)
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .denied), .denied)
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .authorized), .authorized)
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .provisional), .provisional)
    }

    func testNotificationAuthorizationStateDeliveryCapability() {
        XCTAssertFalse(NotificationAuthorizationState.unknown.allowsDelivery)
        XCTAssertFalse(NotificationAuthorizationState.notDetermined.allowsDelivery)
        XCTAssertFalse(NotificationAuthorizationState.denied.allowsDelivery)
        XCTAssertTrue(NotificationAuthorizationState.authorized.allowsDelivery)
        XCTAssertTrue(NotificationAuthorizationState.provisional.allowsDelivery)
        XCTAssertTrue(NotificationAuthorizationState.ephemeral.allowsDelivery)
    }

    func testNotificationAuthorizationDefersFirstPromptWhileAppIsInactive() {
        XCTAssertTrue(
            TerminalNotificationStore.shouldDeferAutomaticAuthorizationRequest(
                status: .notDetermined,
                isAppActive: false
            )
        )
        XCTAssertFalse(
            TerminalNotificationStore.shouldDeferAutomaticAuthorizationRequest(
                status: .notDetermined,
                isAppActive: true
            )
        )
        XCTAssertFalse(
            TerminalNotificationStore.shouldDeferAutomaticAuthorizationRequest(
                status: .authorized,
                isAppActive: false
            )
        )
    }

    func testNotificationAuthorizationRequestGatingAllowsSettingsRetry() {
        XCTAssertTrue(
            TerminalNotificationStore.shouldRequestAuthorization(
                isAutomaticRequest: false,
                hasRequestedAutomaticAuthorization: true
            )
        )
        XCTAssertTrue(
            TerminalNotificationStore.shouldRequestAuthorization(
                isAutomaticRequest: true,
                hasRequestedAutomaticAuthorization: false
            )
        )
        XCTAssertFalse(
            TerminalNotificationStore.shouldRequestAuthorization(
                isAutomaticRequest: true,
                hasRequestedAutomaticAuthorization: true
            )
        )
    }

    func testNotificationSettingsPromptUsesSheetAndNeverRunsModal() {
        let store = TerminalNotificationStore.shared
        let alertSpy = NotificationSettingsAlertSpy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        var openedURL: URL?
        store.configureNotificationSettingsPromptHooksForTesting(
            windowProvider: { window },
            alertFactory: { alertSpy },
            scheduler: { _, block in block() },
            urlOpener: { openedURL = $0 }
        )

        store.promptToEnableNotificationsForTesting()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
        XCTAssertEqual(
            openedURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.notifications"
        )
    }

    func testNotificationSettingsPromptRetriesUntilWindowExists() {
        let store = TerminalNotificationStore.shared
        let alertSpy = NotificationSettingsAlertSpy()
        alertSpy.nextResponse = .alertSecondButtonReturn

        var queuedRetryBlocks: [() -> Void] = []
        var promptWindow: NSWindow?
        store.configureNotificationSettingsPromptHooksForTesting(
            windowProvider: { promptWindow },
            alertFactory: { alertSpy },
            scheduler: { _, block in queuedRetryBlocks.append(block) },
            urlOpener: { _ in XCTFail("Should not open settings for Not Now response") }
        )

        store.promptToEnableNotificationsForTesting()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 0)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
        XCTAssertEqual(queuedRetryBlocks.count, 1)

        promptWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        queuedRetryBlocks.removeFirst()()

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
    }

    func testNotificationIndexesTrackUnreadCountsByTabAndSurface() {
        let tabA = UUID()
        let tabB = UUID()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let notificationAUnread = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: surfaceA,
            title: "A unread",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        let notificationARead = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: surfaceB,
            title: "A read",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )
        let notificationBUnread = TerminalNotification(
            id: UUID(),
            tabId: tabB,
            surfaceId: nil,
            title: "B unread",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([
            notificationAUnread,
            notificationARead,
            notificationBUnread
        ])

        XCTAssertEqual(store.unreadCount, 2)
        XCTAssertEqual(store.unreadCount(forTabId: tabA), 1)
        XCTAssertEqual(store.unreadCount(forTabId: tabB), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: tabA, surfaceId: surfaceA))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: tabA, surfaceId: surfaceB))
        XCTAssertTrue(store.hasUnreadNotification(forTabId: tabB, surfaceId: nil))
        XCTAssertEqual(store.latestNotification(forTabId: tabA)?.id, notificationAUnread.id)
        XCTAssertEqual(store.latestNotification(forTabId: tabB)?.id, notificationBUnread.id)
    }

    func testNotificationIndexesUpdateAfterReadAndClearMutations() {
        let tab = UUID()
        let surfaceUnread = UUID()
        let surfaceRead = UUID()
        let unreadNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: surfaceUnread,
            title: "Unread",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        let readNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: surfaceRead,
            title: "Read",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([unreadNotification, readNotification])
        XCTAssertEqual(store.unreadCount(forTabId: tab), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: tab, surfaceId: surfaceUnread))

        store.markRead(forTabId: tab, surfaceId: surfaceUnread)
        XCTAssertEqual(store.unreadCount(forTabId: tab), 0)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: tab, surfaceId: surfaceUnread))
        XCTAssertNil(store.latestNotification(forTabId: tab))

        store.clearNotifications(forTabId: tab)
        XCTAssertEqual(store.unreadCount(forTabId: tab), 0)
        XCTAssertNil(store.latestNotification(forTabId: tab))
    }
}


final class MenuBarBadgeLabelFormatterTests: XCTestCase {
    func testBadgeLabelFormatting() {
        XCTAssertNil(MenuBarBadgeLabelFormatter.badgeText(for: 0))
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 1), "1")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 9), "9")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 10), "9+")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 47), "9+")
    }
}

@MainActor
final class FocusedNotificationIndicatorTests: XCTestCase {
    func testFocusedNotificationIndicatorRemainsVisibleAfterFocusedNotificationIsRead() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Focused",
            subtitle: "",
            body: ""
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        store.markRead(forTabId: workspace.id, surfaceId: panelId)

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        store.clearFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
    }

    func testNewNotificationOnDifferentSurfaceClearsPreviousFocusedReadIndicator() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split workspace setup")
            return
        }

        workspace.focusPanel(rightPanel.id)

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: rightPanel.id)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: rightPanel.id))

        store.addNotification(
            tabId: workspace.id,
            surfaceId: leftPanelId,
            title: "Left",
            subtitle: "",
            body: ""
        )

        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: rightPanel.id))
    }
}


final class NotificationMenuSnapshotBuilderTests: XCTestCase {
    func testSnapshotCountsUnreadAndLimitsRecentItems() {
        let notifications = (0..<8).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: nil,
                title: "N\(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: index.isMultiple(of: 2)
            )
        }

        let snapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notifications,
            maxInlineNotificationItems: 3
        )

        XCTAssertEqual(snapshot.unreadCount, 4)
        XCTAssertTrue(snapshot.hasNotifications)
        XCTAssertTrue(snapshot.hasUnreadNotifications)
        XCTAssertEqual(snapshot.recentNotifications.count, 3)
        XCTAssertEqual(snapshot.recentNotifications.map(\.id), Array(notifications.prefix(3)).map(\.id))
    }

    func testStateHintTitleHandlesSingularPluralAndZero() {
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 0), "No unread notifications")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 1), "1 unread notification")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 2), "2 unread notifications")
    }
}


final class MenuBarBuildHintFormatterTests: XCTestCase {
    func testReleaseBuildShowsNoHint() {
        XCTAssertNil(MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV menubar-extra", isDebugBuild: false))
    }

    func testDebugBuildWithTagShowsTag() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV menubar-extra", isDebugBuild: true),
            "Build Tag: menubar-extra"
        )
    }

    func testDebugBuildWithoutTagShowsUntagged() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV", isDebugBuild: true),
            "Build: DEV (untagged)"
        )
    }
}


final class MenuBarNotificationLineFormatterTests: XCTestCase {
    func testPlainTitleContainsUnreadDotBodyAndTab() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: "workspace-1")
        XCTAssertTrue(line.hasPrefix("● Build finished"))
        XCTAssertTrue(line.contains("All checks passed"))
        XCTAssertTrue(line.contains("workspace-1"))
    }

    func testPlainTitleFallsBackToSubtitleWhenBodyEmpty() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Deploy",
            subtitle: "staging",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: true
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: nil)
        XCTAssertTrue(line.hasPrefix("  Deploy"))
        XCTAssertTrue(line.contains("staging"))
    }

    func testMenuTitleWrapsAndTruncatesToThreeLines() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Extremely long notification title for wrapping behavior validation",
            subtitle: "",
            body: Array(repeating: "this body should wrap and eventually truncate", count: 8).joined(separator: " "),
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "workspace-with-a-very-long-name",
            maxWidth: 120,
            maxLines: 3
        )

        XCTAssertLessThanOrEqual(title.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testMenuTitlePreservesShortTextWithoutEllipsis() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Done",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "w1",
            maxWidth: 320,
            maxLines: 3
        )

        XCTAssertFalse(title.hasSuffix("…"))
    }
}


final class MenuBarIconDebugSettingsTests: XCTestCase {
    func testDisplayedUnreadCountUsesPreviewOverrideWhenEnabled() {
        let suiteName = "MenuBarIconDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MenuBarIconDebugSettings.previewEnabledKey)
        defaults.set(7, forKey: MenuBarIconDebugSettings.previewCountKey)

        XCTAssertEqual(MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: 2, defaults: defaults), 7)
    }

    func testBadgeRenderConfigClampsInvalidValues() {
        let suiteName = "MenuBarIconDebugSettingsTests.Clamp.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-100, forKey: MenuBarIconDebugSettings.badgeRectXKey)
        defaults.set(200, forKey: MenuBarIconDebugSettings.badgeRectYKey)
        defaults.set(-100, forKey: MenuBarIconDebugSettings.singleDigitFontSizeKey)
        defaults.set(100, forKey: MenuBarIconDebugSettings.multiDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.badgeRect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(config.badgeRect.origin.y, 20, accuracy: 0.001)
        XCTAssertEqual(config.singleDigitFontSize, 6, accuracy: 0.001)
        XCTAssertEqual(config.multiDigitXAdjust, 4, accuracy: 0.001)
    }

    func testBadgeRenderConfigUsesLegacySingleDigitXAdjustWhenNewKeyMissing() {
        let suiteName = "MenuBarIconDebugSettingsTests.LegacyX.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(2.5, forKey: MenuBarIconDebugSettings.legacySingleDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.singleDigitXAdjust, 2.5, accuracy: 0.001)
    }
}

@MainActor


final class MenuBarIconRendererTests: XCTestCase {
    func testImageWidthDoesNotShiftWhenBadgeAppears() {
        let noBadge = MenuBarIconRenderer.makeImage(unreadCount: 0)
        let withBadge = MenuBarIconRenderer.makeImage(unreadCount: 2)

        XCTAssertEqual(noBadge.size.width, 18, accuracy: 0.001)
        XCTAssertEqual(withBadge.size.width, 18, accuracy: 0.001)
    }
}
