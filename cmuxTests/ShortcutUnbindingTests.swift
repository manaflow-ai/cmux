import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class ShortcutUnbindingRoutingTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testEmptySettingsFileShortcutBindingPassesThroughDefaultKeypress() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-unbinding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "newTab": ""
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let event = makeKeyDownEvent(windowNumber: window.windowNumber) else {
            XCTFail("Expected test window, manager, and Cmd+N event")
            return
        }

        let initialCount = manager.tabs.count

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: event),
            "An empty shortcut binding should pass the keypress through to the focused surface"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(manager.tabs.count, initialCount)
    }

    private func makeKeyDownEvent(windowNumber: Int) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        )
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

@MainActor
final class ShortcutRecorderEventRoutingTests: XCTestCase {
    override func tearDown() {
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testShortcutRecorderReportsFirstStrokeConflictImmediately() {
#if DEBUG
        KeyboardShortcutSettings.resetAll()

        let button = ShortcutRecorderNSButton(frame: .zero)
        let conflictingShortcut = StoredShortcut(
            key: "t",
            command: true,
            shift: false,
            option: false,
            control: false,
            keyCode: 17
        )
        var rejectedAttempt: ShortcutRecorderRejectedAttempt?

        button.transformRecordedShortcut = { shortcut in
            XCTAssertEqual(shortcut, conflictingShortcut)
            return .rejected(.conflictsWithAction(.newSurface))
        }
        button.onRecorderFeedbackChanged = { rejectedAttempt = $0 }
        button.performClick(nil)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 17
        ) else {
            XCTFail("Failed to construct Command-T event")
            return
        }

        XCTAssertNil(button.debugHandleRecordingEvent(event))
        XCTAssertEqual(
            rejectedAttempt,
            ShortcutRecorderRejectedAttempt(
                reason: .conflictsWithAction(.newSurface),
                proposedShortcut: conflictingShortcut
            )
        )
        XCTAssertTrue(button.debugIsRecording)
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testShortcutRecorderKeepsCaptureActiveAfterRejectedBareKeys() {
#if DEBUG
        KeyboardShortcutSettings.resetAll()

        let button = ShortcutRecorderNSButton(frame: .zero)
        var rejectedAttempt: ShortcutRecorderRejectedAttempt?
        button.onRecorderFeedbackChanged = { rejectedAttempt = $0 }
        button.performClick(nil)

        guard let firstEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("Failed to construct bare A event")
            return
        }
        guard let secondEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 17
        ) else {
            XCTFail("Failed to construct bare T event")
            return
        }
        guard let escapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

        XCTAssertNil(
            button.debugHandleMonitoredRecordingEvent(firstEvent),
            "The recorder's local monitor must swallow consumed key events so Settings search and sidebar type-selection cannot see them."
        )
        XCTAssertEqual(rejectedAttempt?.reason, .bareKeyNotAllowed)
        XCTAssertTrue(button.debugIsRecording)
        XCTAssertNil(
            button.debugHandleMonitoredRecordingEvent(secondEvent),
            "The recorder must keep swallowing later invalid keys while the validation message is visible."
        )
        XCTAssertEqual(rejectedAttempt?.reason, .bareKeyNotAllowed)
        XCTAssertTrue(button.debugIsRecording)
        XCTAssertNil(button.debugHandleMonitoredRecordingEvent(escapeEvent))
        XCTAssertFalse(button.debugIsRecording)
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }
}

final class ShortcutUnbindingParsingTests: XCTestCase {
    func testSettingsFileStoreParsesEmptyShortcutBindingAsUnbound() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-unbinding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "newTab": "",
            "openBrowser": "none",
            "splitRight": null
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(store.override(for: .newTab), StoredShortcut.unbound)
        XCTAssertEqual(store.override(for: .openBrowser), StoredShortcut.unbound)
        XCTAssertEqual(store.override(for: .splitRight), StoredShortcut.unbound)
    }

    func testSwapShortcutConflictDoesNotPersistAgainstManagedConflict() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let currentAction = KeyboardShortcutSettings.Action.openBrowser
        let conflictingAction = KeyboardShortcutSettings.Action.newSurface
        let originalCurrentData = UserDefaults.standard.data(forKey: currentAction.defaultsKey)
        let originalConflictingData = UserDefaults.standard.data(forKey: conflictingAction.defaultsKey)
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            restoreShortcutDefaultsData(originalCurrentData, for: currentAction)
            restoreShortcutDefaultsData(originalConflictingData, for: conflictingAction)
        }

        UserDefaults.standard.removeObject(forKey: currentAction.defaultsKey)
        UserDefaults.standard.removeObject(forKey: conflictingAction.defaultsKey)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-managed-shortcut-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "newSurface": "cmd+t"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let previousShortcut = KeyboardShortcutSettings.Action.openBrowser.defaultShortcut
        let proposedShortcut = KeyboardShortcutSettings.Action.newSurface.defaultShortcut

        XCTAssertFalse(
            KeyboardShortcutSettings.swapShortcutConflict(
                proposedShortcut: proposedShortcut,
                currentAction: currentAction,
                conflictingAction: conflictingAction,
                previousShortcut: previousShortcut
            )
        )
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: currentAction), previousShortcut)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: conflictingAction), proposedShortcut)
    }

    func testSystemWideHotkeyShortcutPrefersManagedOverrideOverPersistedValue() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let action = SystemWideHotkeySettings.action
        let originalData = UserDefaults.standard.data(forKey: action.defaultsKey)
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            restoreShortcutDefaultsData(originalData, for: action)
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-managed-global-hotkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        let persistedShortcut = StoredShortcut(
            key: "h",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        KeyboardShortcutSettings.setShortcut(persistedShortcut, for: action)

        try """
        {
          "shortcuts": {
            "showHideAllWindows": "ctrl+option+h"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            SystemWideHotkeySettings.shortcut(),
            StoredShortcut(key: "h", command: false, shift: false, option: true, control: true)
        )
    }

    func testUnboundShortcutNeverMatchesKeypress() {
        let shortcut = StoredShortcut.unbound

        XCTAssertFalse(
            shortcut.matches(
                keyCode: 45,
                modifierFlags: [.command],
                eventCharacter: "n",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
        XCTAssertNil(shortcut.keyEquivalent)
        XCTAssertNil(shortcut.menuItemKeyEquivalent)
        XCTAssertNil(shortcut.carbonHotKeyRegistration)
    }

    func testShortcutRecorderValidationPresentationSuppressesSwapForManagedConflicts() {
        let presentation = ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(
                reason: .conflictsWithAction(.newSurface),
                proposedShortcut: StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
            ),
            action: .openBrowser,
            currentShortcut: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut,
            shortcutForAction: { $0.defaultShortcut },
            isManagedBySettingsFile: { $0 == .newSurface }
        )

        XCTAssertEqual(presentation?.message, "This shortcut conflicts with New Surface (⌘T).")
        XCTAssertNil(presentation?.swapButtonTitle)
        XCTAssertFalse(presentation?.canSwap ?? true)
        XCTAssertEqual(presentation?.undoButtonTitle, "Undo")
    }

    private func restoreShortcutDefaultsData(
        _ data: Data?,
        for action: KeyboardShortcutSettings.Action
    ) {
        if let data {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
    }
}
