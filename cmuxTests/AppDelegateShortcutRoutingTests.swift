import XCTest
import CmuxTerminal
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
@testable import CmuxSettingsUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
private let appDelegateLastSurfaceCloseShortcutDefaultsKey = "closeWorkspaceOnLastSurfaceShortcut"
private final class FakeWKInspectorContainerView: NSView {}
private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
private final class FakeTextBoxSubmitSurface: TextBoxSubmitSurfaceControlling {
    var clipboardReadGeneration = 0
    var textBoxSubmitObservationWindow: NSWindow?
    var textBoxSubmitTerminalSurface: TerminalSurface? { nil }
    var visibleTextValue: String?
    var sendKeyTextResult = true
    var sendTextResult = true
    var sendNamedKeyResult: TerminalSurface.NamedKeySendResult = .sent
    var performBindingActionResult = true
    private(set) var sentText: [String] = []
    private(set) var sentKeys: [String] = []

    func visibleText() -> String? {
        visibleTextValue
    }

    @discardableResult
    func sendKeyText(_ text: String) -> Bool {
        sentText.append(text)
        return sendKeyTextResult
    }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        sentText.append(text)
        return sendTextResult
    }

    @discardableResult
    func sendNamedKey(_ keyName: String) -> TerminalSurface.NamedKeySendResult {
        sentKeys.append(keyName)
        return sendNamedKeyResult
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        sentKeys.append(action)
        return performBindingActionResult
    }

    func completeClipboardRead() {
        clipboardReadGeneration += 1
        NotificationCenter.default.post(
            name: .terminalSurfaceDidCompleteClipboardRead,
            object: self
        )
    }
}
private final class MenuActionProbe: NSObject {
    var callCount = 0
    @objc func perform(_ sender: Any?) {
        callCount += 1
    }
}
private final class GhosttyCommandEquivalentProbeView: GhosttyNSView {
    var afterMenuMissCallCount = 0
    var keyDownCallCount = 0
    var lastKeyDownCharactersIgnoringModifiers: String?
    var pasteCallCount = 0
    var pasteAsPlainTextCallCount = 0
    var performAfterMenuMissResult = true

    override func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        afterMenuMissCallCount += 1
        return performAfterMenuMissResult
    }

    override func keyDown(with event: NSEvent) {
        keyDownCallCount += 1
        lastKeyDownCharactersIgnoringModifiers = event.charactersIgnoringModifiers
    }

    override func paste(_ sender: Any?) {
        pasteCallCount += 1
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pasteAsPlainTextCallCount += 1
    }
}

@MainActor
final class AppDelegateShortcutRoutingTests: XCTestCase {
    private static var retainedTextBoxUndoWindows: [NSWindow] = []
    private static var retainedTextBoxRenderScrollViews: [NSScrollView] = []
    private static var retainedTextBoxRestoreViews: [TextBoxInputTextView] = []
    private var savedShortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var actionsWithPersistedShortcut: Set<KeyboardShortcutSettings.Action> = []
    // Optional, not IUO: setUpWithError() can XCTSkip before this is assigned,
    // and tearDown() still runs after a skip, so it must tolerate a nil here.
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore?

    private func makeKeyEvent(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
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
            fatalError("Failed to construct key event")
        }
        return event
    }

    private func ghosttyConfigKeyIsBinding(
        _ config: ghostty_config_t,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt32
    ) -> Bool {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keyCode
        keyEvent.mods = ghosttyMods(from: modifiers)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = key.unicodeScalars.first.map { UInt32($0.value) } ?? 0
        keyEvent.composing = false

        return key.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_config_key_is_binding(config, keyEvent)
        }
    }

    private func ghosttyMods(from modifiers: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var rawValue = GHOSTTY_MODS_NONE.rawValue
        if modifiers.contains(.shift) { rawValue |= GHOSTTY_MODS_SHIFT.rawValue }
        if modifiers.contains(.control) { rawValue |= GHOSTTY_MODS_CTRL.rawValue }
        if modifiers.contains(.option) { rawValue |= GHOSTTY_MODS_ALT.rawValue }
        if modifiers.contains(.command) { rawValue |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: rawValue)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Prevent a single hanging test from consuming the entire CI timeout budget.
        executionTimeAllowance = 30
        AppDelegate.installWindowResponderSwizzlesForTesting()
        #if DEBUG
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugBeginShortcutRoutingFocusedWindowCaptureForTesting()
        #endif
        actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-shortcut-routing")
        KeyboardShortcutSettings.resetAll()
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
    }

    override func tearDown() {
        #if DEBUG
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugEndShortcutRoutingFocusedWindowCaptureForTesting()
        KeyboardShortcutSettings.shortcutLookupObserver = nil
        TextBoxSubmit.debugResetForTesting()
        #endif
        if let originalSettingsFileStore {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        }
        AppDelegate.shared?.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        AppDelegate.shared?.debugCloseMainWindowConfirmationHandler = nil
        AppDelegate.shared?.debugCreateMainWindowSourceIsNativeFullScreenOverride = nil
        if AppDelegate.shared?.dismissNotificationsPopoverIfShown() == true {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        for action in KeyboardShortcutSettings.Action.allCases {
            if actionsWithPersistedShortcut.contains(action),
               let savedShortcut = savedShortcutsByAction[action] {
                KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        for window in Self.retainedTextBoxUndoWindows {
            window.orderOut(nil)
            window.close()
        }
        Self.retainedTextBoxUndoWindows.removeAll()
        Self.retainedTextBoxRenderScrollViews.removeAll()
        Self.retainedTextBoxRestoreViews.removeAll()
        super.tearDown()
    }

    func testShortcutMonitorIgnoresSystemDefinedEvents() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 7,
            data1: 1,
            data2: 1
        ) else {
            XCTFail("Failed to construct system-defined event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleShortcutMonitorEvent(event: event))
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif
    }

    func testStopAllRecordingClearsStaleRecorderActivityCount() {
        defer { KeyboardShortcutRecorderActivity.stopAllRecording() }

        KeyboardShortcutRecorderActivity.beginRecording()
        KeyboardShortcutRecorderActivity.beginRecording()
        XCTAssertTrue(KeyboardShortcutRecorderActivity.isAnyRecorderActive)

        KeyboardShortcutRecorderActivity.stopAllRecording()

        XCTAssertFalse(KeyboardShortcutRecorderActivity.isAnyRecorderActive)
    }

    func testFocusHistoryShortcutsConsumeEventWhenNoHistoryIsAvailable() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let originalTabManager = appDelegate.tabManager
        let manager = TabManager()
        appDelegate.tabManager = manager
        defer {
            appDelegate.tabManager = originalTabManager
        }

        XCTAssertFalse(manager.canNavigateBack)
        XCTAssertFalse(manager.canNavigateForward)
        let backEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "[",
            charactersIgnoringModifiers: "[",
            keyCode: 33
        )
        let forwardEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "]",
            charactersIgnoringModifiers: "]",
            keyCode: 30
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: backEvent))
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: forwardEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdNUsesEventWindowContextWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        XCTAssertTrue(appDelegate.focusMainWindow(windowId: firstWindowId))

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: secondWindow.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Cmd+N should not add workspace to stale active window")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Cmd+N should add workspace to the event's window")
    }

    func testChordedNewWorkspaceShortcutConsumesPrefixAndTriggersOnSecondKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "n"
        )

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            XCTAssertEqual(manager.tabs.count, initialCount, "Chord prefix must not fire the action early")

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "Chord second key should dispatch the configured shortcut")
    }

    func testOptionCommandNDefaultShortcutCreatesBrowserWorkspace() throws {
#if DEBUG
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let hadBrowserDisabledOverride =
            UserDefaults.standard.object(forKey: BrowserAvailabilitySettings.disabledKey) != nil
        let originalBrowserDisabled = UserDefaults.standard.bool(forKey: BrowserAvailabilitySettings.disabledKey)
        UserDefaults.standard.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            if hadBrowserDisabledOverride {
                UserDefaults.standard.set(originalBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
            }
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count

        withTemporaryShortcut(action: .newBrowserWorkspace) {
            guard let event = makeKeyDownEvent(
                key: "n",
                modifiers: [.command, .option],
                keyCode: 45, // kVK_ANSI_N
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Option+Cmd+N event")
                return
            }

            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "Option+Cmd+N should create a workspace")

        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected the new browser workspace to be selected")
            return
        }
        XCTAssertEqual(workspace.panels.count, 1)
        guard let browserPanel = workspace.panels.values.first as? BrowserPanel else {
            XCTFail("Expected the new workspace's initial surface to be a browser pane")
            return
        }
        XCTAssertNil(workspace.focusedTerminalPanel)
        XCTAssertEqual(
            browserPanel.preferredFocusIntentForActivation(),
            .browser(.addressBar),
            "Browser workspace should land first focus in the address bar"
        )
#else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
#endif
    }

    func testNewBrowserWorkspaceShortcutIsBlockedWhileBrowserDisabled() throws {
#if DEBUG
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let hadBrowserDisabledOverride =
            UserDefaults.standard.object(forKey: BrowserAvailabilitySettings.disabledKey) != nil
        let originalBrowserDisabled = UserDefaults.standard.bool(forKey: BrowserAvailabilitySettings.disabledKey)
        UserDefaults.standard.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            if hadBrowserDisabledOverride {
                UserDefaults.standard.set(originalBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            }
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count

        withTemporaryShortcut(action: .newBrowserWorkspace) {
            guard let event = makeKeyDownEvent(
                key: "n",
                modifiers: [.command, .option],
                keyCode: 45, // kVK_ANSI_N
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Option+Cmd+N event")
                return
            }

            XCTAssertTrue(
                appDelegate.debugHandleCustomShortcut(event: event),
                "The shortcut stays consumed while the browser is disabled"
            )
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(
            manager.tabs.count,
            initialCount,
            "No workspace should be created while the browser is disabled"
        )
#else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
#endif
    }

    func testSettingsFileChordDispatchesNewWorkspaceShortcut() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and tab manager")
            return
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "newTab": ["ctrl+b", "n"]
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        #if DEBUG
        appDelegate.debugResetShortcutRoutingStateForTesting()
        #endif

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count

        guard let prefixEvent = makeKeyDownEvent(
            key: "b",
            modifiers: [.control],
            keyCode: 11,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Ctrl+B prefix event")
            return
        }

        guard let actionEvent = makeKeyDownEvent(
            key: "n",
            modifiers: [],
            keyCode: 45,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct N action event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
        XCTAssertEqual(manager.tabs.count, initialCount, "Chord prefix must not fire the action early")
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "cmux.json chord should dispatch the configured shortcut")
    }

    func testConfiguredChordPrefixIsClearedWhenAppResignsActive() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "n"
        )

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            appDelegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialCount, "Chord suffix should not fire after the app resigns active")
    }

    func testConfiguredChordPrefixBeatsConflictingSingleStrokeShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count
        let shortcut = StoredShortcut(
            key: ",",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "n"
        )

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: ",",
                modifiers: [.command],
                keyCode: 43,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+, prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "Chord prefix should arm instead of firing Settings")
    }

    func testConfiguredChordPrefixBlocksUnrelatedSingleStrokeShortcutOnSecondKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window and workspace")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialWorkspaceCount = manager.tabs.count
        let initialPanelCount = workspace.panels.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )

        withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let conflictingSingleStrokeEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [.command],
                keyCode: 45,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+N event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: conflictingSingleStrokeEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialWorkspaceCount, "Pending chord should block unrelated single-stroke actions")
        XCTAssertEqual(workspace.panels.count, initialPanelCount, "Mismatched second key should not split the workspace")
    }

    func testConfiguredChordDoesNotCrossWindowBoundary() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstWindow = window(withId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId) else {
            XCTFail("Expected both test windows and managers")
            return
        }

        firstWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialFirstCount = firstManager.tabs.count
        let initialSecondCount = secondManager.tabs.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "n"
        )

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: firstWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: secondWindow.windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(firstManager.tabs.count, initialFirstCount, "Prefix window should not change without a matching suffix")
        XCTAssertEqual(secondManager.tabs.count, initialSecondCount, "Chord suffix in another window must not trigger the action")
    }

    func testShortcutChangeClearsPendingConfiguredChord() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window and workspace")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialPanelCount = workspace.panels.count
        let chordShortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )

        withTemporaryShortcut(action: .splitRight, shortcut: chordShortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let suffixEvent = makeKeyDownEvent(
                key: "d",
                modifiers: [],
                keyCode: 2,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct D suffix event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            return
#endif

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "d", command: true, shift: false, option: false, control: false),
                for: .splitRight
            )
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: suffixEvent))
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(workspace.panels.count, initialPanelCount, "Changing shortcuts should discard any pending chord prefix")
    }

    func testChordedShortcutMismatchDoesNotConsumeSecondKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window and workspace")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialPanelCount = workspace.panels.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )

        withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let mismatchEvent = makeKeyDownEvent(
                key: "x",
                modifiers: [],
                keyCode: 7,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct mismatch event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: mismatchEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(workspace.panels.count, initialPanelCount, "Unmatched chord suffix must not trigger the action")
    }

    func testCreateMainWindowDoesNotDisallowFullScreenTilingByDefault() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        XCTAssertFalse(
            window.collectionBehavior.contains(.fullScreenDisallowsTiling),
            "Main windows should still support standard macOS Split View when not created from a fullscreen source"
        )
    }

    func testCreateMainWindowTemporarilyDisallowsFullScreenTilingFromFullscreenSource() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        appDelegate.debugCreateMainWindowSourceIsNativeFullScreenOverride = true

        let newWindowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: newWindowId)
        }

        guard let newWindow = window(withId: newWindowId) else {
            XCTFail("Expected new window")
            return
        }

        XCTAssertTrue(
            newWindow.collectionBehavior.contains(.fullScreenDisallowsTiling),
            "New windows should temporarily opt out of fullscreen tiling while opening from a fullscreen source"
        )

        appDelegate.debugCreateMainWindowSourceIsNativeFullScreenOverride = nil
        waitUntil(timeout: 1.0) {
            !newWindow.collectionBehavior.contains(.fullScreenDisallowsTiling)
        }

        XCTAssertFalse(
            newWindow.collectionBehavior.contains(.fullScreenDisallowsTiling),
            "The fullscreen tiling opt-out should be cleared after initial presentation so Split View keeps working"
        )
    }

    func testAddWorkspaceInPreferredMainWindowIgnoresStaleTabManagerPointer() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        secondWindow.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Force a stale app-level pointer to a different manager.
        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        _ = appDelegate.addWorkspaceInPreferredMainWindow()

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Stale pointer must not receive menu-driven workspace creation")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Workspace creation should target key/main window context")
    }

    func testToggleSidebarInActiveMainWindowIgnoresStaleTabManagerPointer() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstVisibleBefore = appDelegate.sidebarVisibility(windowId: firstWindowId),
              let secondVisibleBefore = appDelegate.sidebarVisibility(windowId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Force a stale app-level pointer to another manager. Window-local UI
        // controls should still target the key/main window, not this stale pointer.
        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        XCTAssertTrue(appDelegate.toggleSidebarInActiveMainWindow())

        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: firstWindowId),
            firstVisibleBefore,
            "Stale active-manager pointer must not receive sidebar toggles"
        )
        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: secondWindowId),
            !secondVisibleBefore,
            "Sidebar toggle should target the key/main window context"
        )
    }

    func testWelcomeWindowSidebarShortcutsUseSharedToggleCommands() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleSidebar.label,
            String(localized: "shortcut.toggleLeftSidebar.label", defaultValue: "Toggle Left Sidebar"),
            "Welcome should expose the shared left-sidebar toggle command"
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleSidebar.defaultShortcut,
            StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleRightSidebar.label,
            String(localized: "shortcut.toggleRightSidebar.label", defaultValue: "Toggle Right Sidebar"),
            "Welcome should expose the shared right-sidebar toggle command, not a File Explorer-only action"
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleRightSidebar.defaultShortcut,
            StoredShortcut(key: "b", command: true, shift: false, option: true, control: false)
        )

        let defaults = UserDefaults.standard
        let previousRightSidebarVisibility = defaults.object(forKey: "fileExplorer.isVisible")
        defer {
            restoreDefaultsValue(previousRightSidebarVisibility, forKey: "fileExplorer.isVisible", defaults: defaults)
        }

        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")

        let tabManager = TabManager()
        let sidebarState = SidebarState(isVisible: true)
        let sidebarSelectionState = SidebarSelectionState()
        let fileExplorerState = FileExplorerState()
        fileExplorerState.setVisible(false)

        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState
        )

        defer {
            window.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let leftSidebarEvent = makeKeyDownEvent(
            key: "b",
            modifiers: [.command],
            keyCode: 11,
            windowNumber: window.windowNumber
        ), let rightSidebarEvent = makeKeyDownEvent(
            key: "b",
            modifiers: [.command, .option],
            keyCode: 11,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct sidebar shortcut events")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: leftSidebarEvent))
        XCTAssertFalse(sidebarState.isVisible, "Cmd+B should toggle the Welcome window left sidebar")

        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: rightSidebarEvent))
        _ = waitForCondition { fileExplorerState.isVisible }
        XCTAssertTrue(fileExplorerState.isVisible, "Cmd+Option+B should toggle the Welcome window right sidebar")
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdNResolvesEventWindowWhenObjectKeyLookupIsMismatched() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
        XCTAssertTrue(appDelegate.debugInjectWindowContextKeyMismatch(windowId: secondWindowId))
#else
        XCTFail("debugInjectWindowContextKeyMismatch is only available in DEBUG")
#endif

        // Ensure stale active-manager pointer does not mask routing errors.
        appDelegate.tabManager = firstManager

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: secondWindow.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Cmd+N should not route to another window when object-key lookup misses")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Cmd+N should still route by event window metadata when object-key lookup misses")
    }

    func testDockMenuNewWindowItemCreatesMainWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let existingWindowId = appDelegate.createMainWindow()
        var createdWindowId: UUID?
        defer {
            if let createdWindowId {
                closeWindow(withId: createdWindowId)
            }
            closeWindow(withId: existingWindowId)
        }

        let existingWindowIds = mainWindowIds()

        let delegate: NSApplicationDelegate = appDelegate
        guard let dockMenu = delegate.applicationDockMenu?(NSApp) else {
            XCTFail("Expected Dock menu")
            return
        }

        let expectedTitle = String(localized: "menu.file.newWindow", defaultValue: "New Window")
        guard let item = dockMenu.items.first(where: { $0.action == #selector(AppDelegate.openNewMainWindow(_:)) }) else {
            XCTFail("Expected New Window item in Dock menu")
            return
        }

        XCTAssertEqual(item.title, expectedTitle)
        XCTAssertTrue(NSApp.sendAction(#selector(AppDelegate.openNewMainWindow(_:)), to: item.target, from: item))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let newWindowIds = mainWindowIds().subtracting(existingWindowIds)
        XCTAssertEqual(newWindowIds.count, 1, "Dock menu New Window should create one main window")
        createdWindowId = newWindowIds.first
    }

    func testRestorePreviousSessionSnapshotCreatesNewWindowWithoutClosingCurrentWindows() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let baselineWindowIds = mainWindowIds()
        let liveWindowId = appDelegate.createMainWindow(shouldActivate: false)
        defer {
            for windowId in mainWindowIds().subtracting(baselineWindowIds) {
                closeWindow(withId: windowId)
            }
        }

        guard let liveManager = appDelegate.tabManagerFor(windowId: liveWindowId),
              let liveWorkspace = liveManager.selectedWorkspace else {
            XCTFail("Expected live window manager and workspace")
            return
        }
        liveWorkspace.setCustomTitle("Current Work")
        let windowIdsAfterLiveWindow = mainWindowIds()

        let restoredManager = TabManager(autoWelcomeIfNeeded: false)
        let restoredWorkspace = try XCTUnwrap(restoredManager.selectedWorkspace)
        restoredWorkspace.setCustomTitle("Previous Work")
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_700_000_000,
            windows: [sessionWindowSnapshot(tabManager: restoredManager)]
        )

        XCTAssertTrue(appDelegate.restorePreviousSessionSnapshot(snapshot, shouldActivate: false))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let finalWindowIds = mainWindowIds()
        XCTAssertTrue(finalWindowIds.contains(liveWindowId))
        XCTAssertEqual(liveManager.selectedWorkspace?.customTitle, "Current Work")

        let createdWindowIds = finalWindowIds.subtracting(windowIdsAfterLiveWindow)
        XCTAssertEqual(createdWindowIds.count, 1)
        let restoredWindowId = try XCTUnwrap(createdWindowIds.first)
        let restoredWindowManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: restoredWindowId))
        XCTAssertEqual(restoredWindowManager.selectedWorkspace?.customTitle, "Previous Work")
    }

    func testRestorePreviousSessionSnapshotRemapsClosedWorkspaceWindowIds() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let baselineWindowIds = mainWindowIds()
        let liveWindowId = appDelegate.createMainWindow(shouldActivate: false)
        defer {
            for windowId in mainWindowIds().subtracting(baselineWindowIds) {
                closeWindow(withId: windowId)
            }
        }

        let liveManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: liveWindowId))
        let oldRestoredWindowId = UUID()

        let restoredManager = TabManager(autoWelcomeIfNeeded: false)
        let restoredWorkspace = try XCTUnwrap(restoredManager.selectedWorkspace)
        restoredWorkspace.setCustomTitle("Previous Work")

        let closedWorkspaceManager = TabManager(autoWelcomeIfNeeded: false)
        let closedWorkspace = try XCTUnwrap(closedWorkspaceManager.selectedWorkspace)
        closedWorkspace.setCustomTitle("Closed Previous Workspace")
        let closedRecordId = UUID()
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: closedRecordId,
            closedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: closedWorkspace.id,
                windowId: oldRestoredWindowId,
                workspaceIndex: 1,
                snapshot: closedWorkspace.sessionSnapshot(includeScrollback: false)
            ))
        ))

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_700_000_001,
            windows: [sessionWindowSnapshot(tabManager: restoredManager, windowId: oldRestoredWindowId)]
        )

        XCTAssertTrue(appDelegate.restorePreviousSessionSnapshot(snapshot, shouldActivate: false))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let restoredWindowIds = mainWindowIds().subtracting(baselineWindowIds).subtracting([liveWindowId])
        XCTAssertEqual(restoredWindowIds.count, 1)
        let restoredWindowId = try XCTUnwrap(restoredWindowIds.first)
        let restoredWindowManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: restoredWindowId))

        XCTAssertTrue(
            appDelegate.reopenClosedHistoryItem(
                id: closedRecordId,
                preferredTabManager: liveManager,
                shouldActivate: false
            )
        )
        XCTAssertTrue(restoredWindowManager.tabs.contains { $0.customTitle == "Closed Previous Workspace" })
        XCTAssertFalse(liveManager.tabs.contains { $0.customTitle == "Closed Previous Workspace" })
    }

    func testFailedClosedWindowRestoreDoesNotRemapClosedPanelHistoryToDiscardedWindow() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let baselineWindowIds = mainWindowIds()
        defer {
            for windowId in mainWindowIds().subtracting(baselineWindowIds) {
                closeWindow(withId: windowId)
            }
        }

        let sourceManager = TabManager(autoWelcomeIfNeeded: false)
        let sourceWorkspace = try XCTUnwrap(sourceManager.selectedWorkspace)
        let originalWorkspaceId = sourceWorkspace.id
        var closedPanelSnapshot = try XCTUnwrap(sourceWorkspace.sessionSnapshot(includeScrollback: false).panels.first)
        closedPanelSnapshot.customTitle = "Panel From Failed Window"
        let closedPanelRecordId = UUID()
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: closedPanelRecordId,
            closedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: originalWorkspaceId,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: closedPanelSnapshot
            ))
        ))

        var invalidWorkspaceSnapshot = sourceWorkspace.sessionSnapshot(includeScrollback: false)
        var invalidPanelSnapshot = try XCTUnwrap(invalidWorkspaceSnapshot.panels.first)
        invalidPanelSnapshot.type = .markdown
        invalidPanelSnapshot.title = "Broken Markdown"
        invalidPanelSnapshot.customTitle = "Broken Markdown"
        invalidPanelSnapshot.terminal = nil
        invalidPanelSnapshot.browser = nil
        invalidPanelSnapshot.markdown = nil
        invalidPanelSnapshot.filePreview = nil
        invalidPanelSnapshot.rightSidebarTool = nil
        invalidWorkspaceSnapshot.panels = [invalidPanelSnapshot]
        invalidWorkspaceSnapshot.layout = .pane(SessionPaneLayoutSnapshot(
            panelIds: [invalidPanelSnapshot.id],
            selectedPanelId: invalidPanelSnapshot.id
        ))

        let originalWindowId = UUID()
        let failedWindowRecordId = UUID()
        let failedWindowSnapshot = SessionWindowSnapshot(
            windowId: originalWindowId,
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [invalidWorkspaceSnapshot]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: failedWindowRecordId,
            closedAt: Date(timeIntervalSince1970: 1_700_000_001),
            entry: .window(ClosedWindowHistoryEntry(
                windowId: originalWindowId,
                snapshot: failedWindowSnapshot,
                workspaceIds: [originalWorkspaceId]
            ))
        ))

        XCTAssertFalse(appDelegate.reopenClosedHistoryItem(
            id: failedWindowRecordId,
            shouldActivate: false
        ))

        let record = try XCTUnwrap(ClosedItemHistoryStore.shared.removeRecord(id: closedPanelRecordId)?.record)
        guard case .panel(let panelEntry) = record.entry else {
            return XCTFail("Expected closed panel history")
        }
        XCTAssertEqual(panelEntry.workspaceId, originalWorkspaceId)
        XCTAssertTrue(panelEntry.restoreInOriginalPane)
    }

    func testCmdShiftNCreatesWindowFromEventWindowWithoutAddingWorkspace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()
        var createdWindowId: UUID?

        defer {
            if let createdWindowId {
                closeWindow(withId: createdWindowId)
            }
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let firstWindow = window(withId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let visibleFrame = (secondWindow.screen ?? NSScreen.main)?.visibleFrame else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstFrame = NSRect(
            x: visibleFrame.minX + 40,
            y: visibleFrame.maxY - 460,
            width: 760,
            height: 420
        )
        let secondFrame = NSRect(
            x: min(visibleFrame.minX + 180, visibleFrame.maxX - 600),
            y: max(visibleFrame.minY + 80, visibleFrame.maxY - 560),
            width: 560,
            height: 380
        )
        firstWindow.setFrame(firstFrame, display: true)
        secondWindow.setFrame(secondFrame, display: true)
        firstWindow.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let eventSourceFrame = secondWindow.frame
        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count
        let existingWindowIds = mainWindowIds()

        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command, .shift],
            keyCode: 45,
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let newWindowIds = mainWindowIds().subtracting(existingWindowIds)
        XCTAssertEqual(newWindowIds.count, 1, "Cmd+Shift+N should create one new main window")
        createdWindowId = newWindowIds.first

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Cmd+Shift+N must not create a workspace in the key window")
        XCTAssertEqual(secondManager.tabs.count, secondCount, "Cmd+Shift+N must not create a workspace in the event window")

        guard let createdWindowId,
              let createdWindow = window(withId: createdWindowId) else {
            XCTFail("Expected created window")
            return
        }

        XCTAssertEqual(createdWindow.frame.width, eventSourceFrame.width, accuracy: 1)
        XCTAssertEqual(createdWindow.frame.height, eventSourceFrame.height, accuracy: 1)
        XCTAssertTrue(
            visibleFrame.contains(createdWindow.frame),
            "New window should be placed inside the source window display"
        )
    }

    func testAddWorkspaceInPreferredMainWindowUsesKeyWindowWhenObjectKeyLookupIsMismatched() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
        XCTAssertTrue(appDelegate.debugInjectWindowContextKeyMismatch(windowId: secondWindowId))
#else
        XCTFail("debugInjectWindowContextKeyMismatch is only available in DEBUG")
#endif

        // Stale pointer should not receive the new workspace.
        appDelegate.tabManager = firstManager

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        _ = appDelegate.addWorkspaceInPreferredMainWindow()

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Menu-driven add workspace should not route to stale window")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Menu-driven add workspace should still route to key window context when object-key lookup misses")
    }

    func testAddWorkspaceInPreferredMainWindowPrunesOrphanedContextWithoutLiveWindow() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let orphanWindowId = UUID()
        let orphanManager = TabManager()
        let orphanSidebarState = SidebarState()
        let orphanSidebarSelectionState = SidebarSelectionState()
        let orphanFileExplorerState = FileExplorerState()

        autoreleasepool {
            var orphanWindow: NSWindow? = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            orphanWindow?.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(orphanWindowId.uuidString)")
            appDelegate.registerMainWindow(
                orphanWindow!,
                windowId: orphanWindowId,
                tabManager: orphanManager,
                sidebarState: orphanSidebarState,
                sidebarSelectionState: orphanSidebarSelectionState,
                fileExplorerState: orphanFileExplorerState
            )
            orphanWindow = nil
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertNil(appDelegate.mainWindow(for: orphanWindowId), "Test precondition: orphaned context should not have a live window")

        let orphanCount = orphanManager.tabs.count
        XCTAssertNil(
            appDelegate.addWorkspaceInPreferredMainWindow(),
            "Workspace creation should refuse orphaned contexts with no live window"
        )
        XCTAssertEqual(orphanManager.tabs.count, orphanCount, "Orphaned manager must not receive a new workspace")
        XCTAssertNil(appDelegate.tabManagerFor(windowId: orphanWindowId), "Orphaned context should be pruned after failed resolution")
    }

    func testCustomCmdTNewWorkspacePrunesOrphanedContextWithoutLiveWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let existingWindowIds = mainWindowIds()
        let orphanWindowId = UUID()
        let orphanManager = TabManager()
        let orphanSidebarState = SidebarState()
        let orphanSidebarSelectionState = SidebarSelectionState()
        let orphanFileExplorerState = FileExplorerState()

        autoreleasepool {
            var orphanWindow: NSWindow? = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            orphanWindow?.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(orphanWindowId.uuidString)")
            appDelegate.registerMainWindow(
                orphanWindow!,
                windowId: orphanWindowId,
                tabManager: orphanManager,
                sidebarState: orphanSidebarState,
                sidebarSelectionState: orphanSidebarSelectionState,
                fileExplorerState: orphanFileExplorerState
            )
            orphanWindow = nil
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertNil(appDelegate.mainWindow(for: orphanWindowId), "Test precondition: orphaned context should not have a live window")

        let orphanCount = orphanManager.tabs.count
        let remappedCmdT = StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)

        withTemporaryShortcut(action: .newTab, shortcut: remappedCmdT) {
            guard let event = makeKeyDownEvent(
                key: "t",
                modifiers: [.command],
                keyCode: 17, // kVK_ANSI_T
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct remapped Cmd+T event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        XCTAssertEqual(orphanManager.tabs.count, orphanCount, "Orphaned manager must not receive a new workspace from remapped Cmd+T")
        XCTAssertNil(appDelegate.tabManagerFor(windowId: orphanWindowId), "Remapped Cmd+T should prune the orphaned context after failed resolution")

        let createdWindowIds = mainWindowIds().subtracting(existingWindowIds)
        for windowId in createdWindowIds {
            closeWindow(withId: windowId)
        }
    }

    func testCmdDigitRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        _ = firstManager.addTab(select: true)
        _ = secondManager.addTab(select: true)

        guard let firstSelectedBefore = firstManager.selectedTabId,
              let secondSelectedBefore = secondManager.selectedTabId else {
            XCTFail("Expected selected tabs in both windows")
            return
        }
        guard let secondFirstTabId = secondManager.tabs.first?.id else {
            XCTFail("Expected at least one tab in second window")
            return
        }

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        guard let event = makeKeyDownEvent(
            key: "1",
            modifiers: [.command],
            keyCode: 18, // kVK_ANSI_1
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+1 event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.selectedTabId, firstSelectedBefore, "Cmd+1 must not select a tab in stale active window")
        XCTAssertNotEqual(secondManager.selectedTabId, secondSelectedBefore, "Cmd+1 should change tab selection in event window")
        XCTAssertEqual(secondManager.selectedTabId, secondFirstTabId, "Cmd+1 should select first tab in the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Shortcut routing should retarget active manager to event window")
    }

    func testCmdTRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = UUID()
        let secondWindowId = UUID()
        let firstWindow = makeRegisteredShortcutRoutingWindow(id: firstWindowId)
        let secondWindow = makeRegisteredShortcutRoutingWindow(id: secondWindowId)
        let firstManager = TabManager()
        let secondManager = TabManager()
        let firstSidebarState = SidebarState(isVisible: true)
        let secondSidebarState = SidebarState(isVisible: true)

        appDelegate.registerMainWindow(
            firstWindow,
            windowId: firstWindowId,
            tabManager: firstManager,
            sidebarState: firstSidebarState,
            sidebarSelectionState: SidebarSelectionState()
        )
        appDelegate.registerMainWindow(
            secondWindow,
            windowId: secondWindowId,
            tabManager: secondManager,
            sidebarState: secondSidebarState,
            sidebarSelectionState: SidebarSelectionState()
        )
        defer {
            closeRegisteredShortcutRoutingWindow(firstWindow, id: firstWindowId)
            closeRegisteredShortcutRoutingWindow(secondWindow, id: secondWindowId)
        }

        let firstVisibleBefore = firstSidebarState.isVisible
        let secondVisibleBefore = secondSidebarState.isVisible

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        guard let event = makeKeyDownEvent(
            key: "t",
            modifiers: [.command],
            keyCode: 17, // kVK_ANSI_T
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+T event")
            return
        }

        withTemporaryShortcut(
            action: .toggleSidebar,
            shortcut: StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
        ) {
#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: firstWindowId), firstVisibleBefore, "Cmd+T must not route to the stale active window")
        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: secondWindowId), !secondVisibleBefore, "Cmd+T should route to the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Shortcut routing should retarget active manager to event window")
    }

    func testCmdDRoutesSplitToEventWindowWhenKeyWindowIsDifferent() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = UUID()
        let secondWindowId = UUID()
        let firstWindow = makeRegisteredShortcutRoutingWindow(id: firstWindowId)
        let secondWindow = makeRegisteredShortcutRoutingWindow(id: secondWindowId)
        let firstManager = TabManager()
        let secondManager = TabManager()
        let firstSidebarState = SidebarState(isVisible: true)
        let secondSidebarState = SidebarState(isVisible: true)

        appDelegate.registerMainWindow(
            firstWindow,
            windowId: firstWindowId,
            tabManager: firstManager,
            sidebarState: firstSidebarState,
            sidebarSelectionState: SidebarSelectionState()
        )
        appDelegate.registerMainWindow(
            secondWindow,
            windowId: secondWindowId,
            tabManager: secondManager,
            sidebarState: secondSidebarState,
            sidebarSelectionState: SidebarSelectionState()
        )
        defer {
            closeRegisteredShortcutRoutingWindow(firstWindow, id: firstWindowId)
            closeRegisteredShortcutRoutingWindow(secondWindow, id: secondWindowId)
        }

        firstWindow.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let firstVisibleBefore = firstSidebarState.isVisible
        let secondVisibleBefore = secondSidebarState.isVisible

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2, // kVK_ANSI_D
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        withTemporaryShortcut(
            action: .toggleSidebar,
            shortcut: StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
        ) {
#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: firstWindowId), firstVisibleBefore, "Cmd+D must not route to the stale key window")
        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: secondWindowId), !secondVisibleBefore, "Cmd+D should route to the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Shortcut routing should keep the event window active")
    }

    func testCmdDPropagatesWhenSplitRightShortcutIsCleared() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window, manager, and workspace")
            return
        }

        window.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialPanelCount = workspace.panels.count

        withTemporaryShortcut(action: .splitRight, shortcut: .unbound) {
            guard let event = makeKeyDownEvent(
                key: "d",
                modifiers: [.command],
                keyCode: 2,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+D event")
                return
            }

#if DEBUG
            XCTAssertFalse(
                appDelegate.debugHandleCustomShortcut(event: event),
                "Cleared Cmd+D split shortcut should not be consumed by cmux"
            )
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(
            workspace.panels.count,
            initialPanelCount,
            "Cleared Cmd+D split shortcut should propagate instead of creating a new pane"
        )
    }

    func testPerformSplitShortcutSplitsFocusedTerminalSurfaceWhenSelectedWorkspaceIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let originalPanelIds = Set(workspace.panels.keys)

        guard let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let leftPaneBefore = workspace.paneId(forPanelId: leftPanel.id),
              let rightPaneBefore = workspace.paneId(forPanelId: rightPanel.id) else {
            XCTFail("Expected split pane IDs")
            return
        }
        let layoutBefore = workspace.bonsplitController.layoutSnapshot()
        guard let leftPaneBeforeFrame = layoutBefore.panes.first(where: { $0.paneId == leftPaneBefore.id.uuidString })?.frame,
              let rightPaneBeforeFrame = layoutBefore.panes.first(where: { $0.paneId == rightPaneBefore.id.uuidString })?.frame else {
            XCTFail("Expected pane frames before shortcut split")
            return
        }
        XCTAssertLessThan(leftPaneBeforeFrame.x, rightPaneBeforeFrame.x, "Expected baseline layout to start left-to-right")

        guard let leftSurfaceView = surfaceView(in: leftPanel.hostedView) else {
            XCTFail("Expected left terminal surface view")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        workspace.focusPanel(rightPanel.id)
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id, "Expected Bonsplit selection to stay on the right pane")
        leftPanel.hostedView.suppressReparentFocus()
        XCTAssertTrue(window.makeFirstResponder(leftSurfaceView))
        leftPanel.hostedView.clearSuppressReparentFocus()
        XCTAssertTrue(window.firstResponder === leftSurfaceView, "Expected left Ghostty surface to stay first responder")
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id, "Expected selected pane to stay stale after first-responder change")
        XCTAssertEqual(leftSurfaceView.tabId, workspace.id, "Expected focused Ghostty view to keep its workspace ID")
        XCTAssertEqual(leftSurfaceView.terminalSurface?.id, leftPanel.id, "Expected focused Ghostty view to keep its surface ID")

        XCTAssertTrue(
            appDelegate.performSplitShortcut(direction: .right, preferredWindow: window),
            "Split shortcut should use the focused terminal surface even when selectedTabId is stale"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))

        let newPanelIds = Set(workspace.panels.keys)
            .subtracting(originalPanelIds)
            .subtracting([rightPanel.id])
        guard newPanelIds.count == 1, let newPanelId = newPanelIds.first else {
            XCTFail("Expected exactly one shortcut-created split panel")
            return
        }
        guard let newPaneId = workspace.paneId(forPanelId: newPanelId),
              let rightPaneAfter = workspace.paneId(forPanelId: rightPanel.id) else {
            XCTFail("Expected pane IDs after shortcut split")
            return
        }
        let layoutAfter = workspace.bonsplitController.layoutSnapshot()
        guard let newPaneFrame = layoutAfter.panes.first(where: { $0.paneId == newPaneId.id.uuidString })?.frame,
              let rightPaneAfterFrame = layoutAfter.panes.first(where: { $0.paneId == rightPaneAfter.id.uuidString })?.frame else {
            XCTFail("Expected pane frames after shortcut split")
            return
        }
        XCTAssertEqual(layoutAfter.panes.count, 3, "Cmd+D should create a third pane")
        XCTAssertLessThan(
            newPaneFrame.x,
            rightPaneAfterFrame.x,
            "Cmd+D should split the focused left terminal pane, not the stale selected right pane"
        )
    }

    func testOpenDiffViewerShortcutDefaultsToCmdCtrlDAndRoutesToSharedDiffPath() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Default is Cmd+Ctrl+Shift+D. Plain Cmd+Ctrl+D is reserved by macOS ("Look Up")
        // and never reaches the app, and the rest of the Cmd+D family is taken by split
        // actions; the default must be conflict-free so the recorder accepts it as-is.
        let cmdCtrlShiftD = StoredShortcut(key: "d", command: true, shift: true, option: false, control: true)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .openDiffViewer), cmdCtrlShiftD)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.openDiffViewer.normalizedRecordedShortcutResult(cmdCtrlShiftD),
            .accepted(cmdCtrlShiftD),
            "Default Open Diff Viewer shortcut must not conflict with any other action"
        )
        XCTAssertTrue(
            KeyboardShortcutSettings.settingsVisibleActions.contains(.openDiffViewer),
            "Open Diff Viewer must be visible/editable in Settings → Keyboard Shortcuts"
        )

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        // Intercept the shared diff-open path so the dispatch test never spawns a
        // subprocess; we only assert the shortcut routes here.
        var openDiffViewerCount = 0
        appDelegate.debugOpenDiffViewerHandler = { openDiffViewerCount += 1 }
        defer { appDelegate.debugOpenDiffViewerHandler = nil }

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command, .control, .shift],
            keyCode: 2, // kVK_ANSI_D
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+Shift+D event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+Ctrl+Shift+D should be consumed by the Open Diff Viewer shortcut"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertEqual(
            openDiffViewerCount,
            1,
            "Cmd+Ctrl+Shift+D must route to the shared diff-open path (same path as the command palette)"
        )
    }

    func testCmdCtrlWPromptsBeforeClosingWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        var promptedWindow: NSWindow?
        appDelegate.debugCloseMainWindowConfirmationHandler = { candidate in
            promptedWindow = candidate
            return false
        }

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command, .control],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(promptedWindow === targetWindow, "Cmd+Ctrl+W should prompt for the target main window")
        XCTAssertNotNil(self.window(withId: windowId), "Cancelling the confirmation should keep the window open")
    }

    func testCmdCtrlWClosesWindowAfterConfirmation() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }
        targetWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = nil }

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command, .control],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        waitUntil(timeout: 1.0) {
            self.window(withId: windowId)?.isVisible != true
        }

        XCTAssertFalse(
            self.window(withId: windowId)?.isVisible == true,
            "Confirming Cmd+Ctrl+W should close the window"
        )
    }

    func testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Auto-confirm window close to avoid a modal dialog that blocks the RunLoop.
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = nil }

        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defaults.set(true, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defer {
            restoreDefaultsValue(originalSetting, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey, defaults: defaults)
        }

        let windowId = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let targetWindow = makeRegisteredShortcutRoutingWindow(id: windowId)
        appDelegate.registerMainWindow(
            targetWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        defer { closeRegisteredShortcutRoutingWindow(targetWindow, id: windowId) }

        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test workspace")
            return
        }

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(workspace.panels.count, 1)

        targetWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        waitUntil(timeout: 1.0) {
            self.window(withId: windowId)?.isVisible != true
        }

        XCTAssertFalse(
            self.window(withId: windowId)?.isVisible == true,
            "Cmd+W on the last surface in the last workspace should close the window"
        )
    }

    func testCmdWKeepsLastSurfaceWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }

        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let targetWindow = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected test window, manager, workspace, and focused panel")
            return
        }

        // This test exercises keep-workspace-open semantics, not close-confirm heuristics.
        // Mark the shell idle so Cmd+W routes through the immediate close path deterministically.
        workspace.updatePanelShellActivityState(panelId: initialPanelId, state: .promptIdle)

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertNotNil(
            self.window(withId: windowId),
            "Cmd+W should keep the window open when the keep-workspace-open preference is enabled"
        )
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testCmdWTargetsFocusedWindowWhenEventWindowMetadataIsStale() {
        assertCloseShortcutTargetsFocusedWindowWhenEventWindowMetadataIsStale(
            actionName: "Cmd+W",
            modifiers: [.command],
            expectedAction: .closeTab
        )
    }

    func testCmdShiftWTargetsFocusedWindowWhenEventWindowMetadataIsStale() {
        assertCloseShortcutTargetsFocusedWindowWhenEventWindowMetadataIsStale(
            actionName: "Cmd+Shift+W",
            modifiers: [.command, .shift],
            expectedAction: .closeWorkspace
        )
    }

    func testRemappedCloseTabDoesNotLetCmdWReachGhosttyCloseSurfaceFallback() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        AppDelegate.installWindowResponderSwizzlesForTesting()

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let mainWindow = window(withId: windowId) else {
            XCTFail("Expected test main window")
            return
        }
        mainWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        probeWindow.isReleasedWhenClosed = false
        probeWindow.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let probeView = GhosttyCommandEquivalentProbeView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
            probeWindow.close()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        let staleMenu = NSMenu(title: "Test")
        let staleCloseItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "w"
        )
        staleCloseItem.keyEquivalentModifierMask = [.command]
        staleCloseItem.target = menuProbe
        staleMenu.addItem(staleCloseItem)
        NSApp.mainMenu = staleMenu

        probeWindow.contentView = contentView
        contentView.addSubview(probeView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(probeView), "Expected probe Ghostty view to own first responder")

        guard let ghosttyConfig = GhosttyApp.shared.config else {
            XCTFail("Expected loaded Ghostty config")
            return
        }

        let remappedCloseTab = StoredShortcut(
            key: "w",
            command: true,
            shift: false,
            option: true,
            control: false
        )

        withTemporaryShortcut(action: .closeTab, shortcut: remappedCloseTab) {
            guard let staleCmdW = makeKeyDownEvent(
                key: "w",
                modifiers: [.command],
                keyCode: 13,
                windowNumber: probeWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+W event")
                return
            }

            XCTAssertFalse(
                KeyboardShortcutSettings.shortcut(for: .closeTab).matches(event: staleCmdW),
                "After Close Tab is remapped, Cmd+W must not match the cmux Close Tab action"
            )
            if ghosttyConfigKeyIsBinding(ghosttyConfig, key: "w", modifiers: [.command], keyCode: 13) {
                XCTFail("After Close Tab is remapped, Ghostty must not retain its super+w close_surface fallback")
                return
            }

            XCTAssertTrue(
                probeWindow.performKeyEquivalent(with: staleCmdW),
                "Remapped-away Cmd+W should be handled only by forwarding it to the focused terminal"
            )
            XCTAssertEqual(
                menuProbe.callCount,
                0,
                "A stale Close Tab menu equivalent must not keep consuming Cmd+W after remap"
            )
            XCTAssertEqual(
                probeView.keyDownCallCount,
                1,
                "Remapped-away Cmd+W should reach the terminal as input instead of closing through cmux"
            )
            XCTAssertEqual(probeView.lastKeyDownCharactersIgnoringModifiers, "w")

            guard let remappedCmdOptionW = makeKeyDownEvent(
                key: "w",
                modifiers: [.command, .option],
                keyCode: 13,
                windowNumber: probeWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+Option+W event")
                return
            }

            XCTAssertTrue(
                KeyboardShortcutSettings.shortcut(for: .closeTab).matches(event: remappedCmdOptionW),
                "The remapped Cmd+Option+W shortcut should match the cmux Close Tab action"
            )
#if DEBUG
            XCTAssertTrue(
                appDelegate.debugHandleShortcutMonitorEvent(event: remappedCmdOptionW),
                "The remapped Cmd+Option+W shortcut should trigger the cmux Close Tab action"
            )
#else
            XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif
        }
    }

    func testGhosttyConfigDoesNotRetainNumberedGotoTabFallback() throws {
        // Regression for https://github.com/manaflow-ai/cmux/issues/5189.
        // cmux owns "Select Workspace 1…9" (default ⌘1–9) through KeyboardShortcutSettings.
        // Ghostty's built-in super+1…8 = goto_tab and super+9 = last_tab fallbacks must be
        // unbound — exactly like cmux already unbinds super+d / super+w — so the numbered
        // shortcut is driven solely by the configured value. Otherwise a remapped-away ⌘1–9
        // still reaches the focused terminal and switches "tabs", making the rebind look
        // hardcoded.
        guard let ghosttyConfig = GhosttyApp.shared.config else {
            XCTFail("Expected loaded Ghostty config")
            return
        }

        let digitKeyCodes: [(String, UInt32)] = [
            ("1", UInt32(kVK_ANSI_1)),
            ("2", UInt32(kVK_ANSI_2)),
            ("3", UInt32(kVK_ANSI_3)),
            ("4", UInt32(kVK_ANSI_4)),
            ("5", UInt32(kVK_ANSI_5)),
            ("6", UInt32(kVK_ANSI_6)),
            ("7", UInt32(kVK_ANSI_7)),
            ("8", UInt32(kVK_ANSI_8)),
            ("9", UInt32(kVK_ANSI_9)),
        ]

        for (digit, keyCode) in digitKeyCodes {
            XCTAssertFalse(
                ghosttyConfigKeyIsBinding(
                    ghosttyConfig,
                    key: digit,
                    modifiers: [.command],
                    keyCode: keyCode
                ),
                "Ghostty must not retain its super+\(digit) goto_tab/last_tab fallback; the numbered workspace shortcut is owned by KeyboardShortcutSettings"
            )
        }
    }

    func testRebindingSelectWorkspaceByNumberHonorsNewModifierAndDropsDefault() {
        // Companion to testGhosttyConfigDoesNotRetainNumberedGotoTabFallback (#5189):
        // the cmux routing layer must drive the numbered shortcut from the configured
        // value, so a rebound modifier selects the workspace and the old ⌘ default no
        // longer routes through cmux.
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let mainWindow = window(withId: windowId) else {
            XCTFail("Expected window context")
            return
        }

        // Need at least two workspaces so a digit-1 selection is observable.
        _ = manager.addTab(select: true)
        _ = manager.addTab(select: true)
        guard manager.tabs.count >= 2,
              let firstTabId = manager.tabs.first?.id else {
            XCTFail("Expected at least two workspaces")
            return
        }
        manager.selectTab(at: manager.tabs.count - 1)
        appDelegate.tabManager = manager
        let selectionBeforeStaleDefault = manager.selectedTabId
        XCTAssertNotEqual(selectionBeforeStaleDefault, firstTabId, "Expected a non-first workspace selected before the digit press")

        let rebound = StoredShortcut(key: "1", command: false, shift: false, option: true, control: true)
        withTemporaryShortcut(action: .selectWorkspaceByNumber, shortcut: rebound) {
            guard let staleCmd1 = makeKeyDownEvent(
                key: "1",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_1),
                windowNumber: mainWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+1 event")
                return
            }
#if DEBUG
            XCTAssertFalse(
                appDelegate.debugHandleCustomShortcut(event: staleCmd1),
                "After rebinding Select Workspace 1…9, the old ⌘1 must not be routed by cmux"
            )
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            XCTAssertEqual(
                manager.selectedTabId,
                selectionBeforeStaleDefault,
                "⌘1 must not change workspace selection after the shortcut is rebound away from ⌘"
            )

            guard let reboundEvent = makeKeyDownEvent(
                key: "1",
                modifiers: [.control, .option],
                keyCode: UInt16(kVK_ANSI_1),
                windowNumber: mainWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+Option+1 event")
                return
            }
#if DEBUG
            XCTAssertTrue(
                appDelegate.debugHandleCustomShortcut(event: reboundEvent),
                "The rebound Ctrl+Option+1 shortcut should be routed by cmux"
            )
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            XCTAssertEqual(
                manager.selectedTabId,
                firstTabId,
                "Ctrl+Option+1 should select the first workspace after the rebind"
            )
        }
    }

    func testBrowserPopupPanelCloseShortcutFollowsCloseTabRemap() throws {
        let defaultCloseTab = KeyboardShortcutSettings.Action.closeTab.defaultShortcut
        let previousMainMenu = NSApp.mainMenu
        let menuProbe = MenuActionProbe()
        let staleMenu = NSMenu(title: "Stale Close Tab")
        let staleCloseItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: defaultCloseTab.menuItemKeyEquivalent ?? ""
        )
        staleCloseItem.keyEquivalentModifierMask = defaultCloseTab.modifierFlags
        staleCloseItem.target = menuProbe
        staleMenu.addItem(staleCloseItem)
        NSApp.mainMenu = staleMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let remappedCloseTab = StoredShortcut(
            key: defaultCloseTab.key,
            command: defaultCloseTab.command,
            shift: defaultCloseTab.shift,
            option: !defaultCloseTab.option,
            control: defaultCloseTab.control,
            keyCode: defaultCloseTab.keyCode
        )

        withTemporaryShortcut(action: .closeTab, shortcut: remappedCloseTab) {
            let panel = BrowserPopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }

            guard let staleDefaultCloseTab = makeKeyDownEvent(
                shortcut: defaultCloseTab,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct default Close Tab event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: staleDefaultCloseTab),
                "After Close Tab is remapped, the default Close Tab shortcut should be consumed without closing a browser popup"
            )
            XCTAssertTrue(panel.isVisible, "Remapped-away default Close Tab shortcut should leave the browser popup open")
            XCTAssertEqual(menuProbe.callCount, 0, "Stale Close Tab menu items must not close the parent browser tab")

            guard let remappedCloseTabEvent = makeKeyDownEvent(
                shortcut: remappedCloseTab,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct remapped Close Tab event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: remappedCloseTabEvent),
                "The configured Close Tab shortcut should close the browser popup"
            )
            XCTAssertFalse(panel.isVisible, "Remapped Close Tab shortcut should close the browser popup")
        }
    }

    func testBrowserPopupPanelCloseShortcutSupportsChordedCloseTabRemap() throws {
        guard AppDelegate.shared != nil else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let chordedCloseTab = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            keyCode: 11,
            chordKey: "n",
            chordCommand: false,
            chordShift: false,
            chordOption: false,
            chordControl: false,
            chordKeyCode: 45
        )

        withTemporaryShortcut(action: .closeTab, shortcut: chordedCloseTab) {
            let panel = BrowserPopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }

            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let suffixEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct N suffix event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: prefixEvent),
                "A chorded Close Tab prefix should be consumed without closing the browser popup"
            )
            XCTAssertTrue(panel.isVisible, "Chord prefix alone should leave the browser popup open")

            XCTAssertTrue(
                panel.performKeyEquivalent(with: suffixEvent),
                "The chorded Close Tab suffix should close the browser popup"
            )
            XCTAssertFalse(panel.isVisible, "Chorded Close Tab shortcut should close the browser popup")
        }
    }

    func testBrowserPopupPanelLeavesDefaultCloseTabShortcutAloneWhenCloseTabIsUnbound() throws {
        let defaultCloseTab = KeyboardShortcutSettings.Action.closeTab.defaultShortcut
        withTemporaryShortcut(action: .closeTab, shortcut: .unbound) {
            let panel = BrowserPopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }

            guard let defaultCloseTabEvent = makeKeyDownEvent(
                shortcut: defaultCloseTab,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct default Close Tab event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: defaultCloseTabEvent),
                "Unbinding Close Tab should consume the default Close Tab shortcut without closing a browser popup"
            )
            XCTAssertTrue(panel.isVisible, "Unbound Close Tab should leave the browser popup open")
        }
    }

    func testCmdWClosesAuxiliaryWindowInsteadOfMainTerminalPanel() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        XCTAssertNotNil(window(withId: windowId), "Expected test window")

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test manager")
            return
        }

        let mainWorkspaceCount = manager.tabs.count
        let auxiliaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        auxiliaryWindow.isReleasedWhenClosed = false
        auxiliaryWindow.animationBehavior = .none
        auxiliaryWindow.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        auxiliaryWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(auxiliaryWindow.isVisible, "Expected auxiliary window to be visible before Cmd+W")

        defer {
            if auxiliaryWindow.isVisible {
                closeTestWindow(auxiliaryWindow)
            }
        }

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: auxiliaryWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(auxiliaryWindow.isVisible, "Cmd+W should close the auxiliary window")
        XCTAssertNotNil(self.window(withId: windowId), "Cmd+W in auxiliary window should not close the main window")
        XCTAssertEqual(manager.tabs.count, mainWorkspaceCount, "Cmd+W in auxiliary window should not close a terminal panel")
        XCTAssertNotEqual(NSApp.keyWindow?.identifier?.rawValue, "cmux.about", "Closed auxiliary window should not remain key")
    }

    func testCmdWClosesMobilePairingWindowInsteadOfTerminalTab() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        XCTAssertNotNil(window(withId: windowId), "Expected test window")

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test manager")
            return
        }

        let mainWorkspaceCount = manager.tabs.count
        // The same window shape MobilePairingWindowController creates, keyed by
        // the same identifier constant, so this test fails if the pairing
        // window's identifier ever drops out of cmuxAuxiliaryWindowIdentifiers
        // (the regression: Cmd+W on "Pair iPhone" closed a terminal tab in the
        // main window behind it instead of the pairing window).
        let pairingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        pairingWindow.isReleasedWhenClosed = false
        pairingWindow.animationBehavior = .none
        pairingWindow.identifier = NSUserInterfaceItemIdentifier(MobilePairingWindowController.windowIdentifier)
        pairingWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(pairingWindow.isVisible, "Expected pairing window to be visible before Cmd+W")

        defer {
            if pairingWindow.isVisible {
                closeTestWindow(pairingWindow)
            }
        }

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: pairingWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(pairingWindow.isVisible, "Cmd+W should close the Pair iPhone window")
        XCTAssertNotNil(self.window(withId: windowId), "Cmd+W in the pairing window should not close the main window")
        XCTAssertEqual(manager.tabs.count, mainWorkspaceCount, "Cmd+W in the pairing window should not close a terminal tab")
        XCTAssertNotEqual(
            NSApp.keyWindow?.identifier?.rawValue,
            MobilePairingWindowController.windowIdentifier,
            "Closed pairing window should not remain key"
        )
    }

    func testCmdPhysicalIWithDvorakCharactersDoesNotTriggerShowNotifications() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(action: .showNotifications) {
            // Dvorak: physical ANSI "I" key can produce the character "c".
            // This should behave like Cmd+C (copy), not match the Cmd+I app shortcut.
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 34 // kVK_ANSI_I
            ) else {
                XCTFail("Failed to construct Dvorak Cmd+C event on physical ANSI I key")
                return
            }

#if DEBUG
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        let savedLegacyTitlebar = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebar, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView else {
            XCTFail("Expected main window content view")
            return
        }

        contentView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            contentView.safeAreaInsets.top,
            0,
            accuracy: 0.5,
            "Minimal mode should not leave a top safe-area inset in the main window content view"
        )
    }

    func testMinimalModeTitlebarPaddingOnlyCancelsHostingSafeArea() {
        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: false,
                isFullScreen: false,
                titlebarPadding: 32,
                hostingSafeAreaTop: 0
            ),
            WindowChromeMetrics.appTitlebarHeight,
            accuracy: 0.5,
            "Standard mode should align terminal content with cmux's visual titlebar height even when AppKit reports a taller native titlebar zone"
        )

        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: true,
                isFullScreen: true,
                titlebarPadding: 32,
                hostingSafeAreaTop: 32
            ),
            0,
            accuracy: 0.5,
            "Fullscreen minimal mode should not offset for a titlebar"
        )

        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: true,
                isFullScreen: false,
                titlebarPadding: 32,
                hostingSafeAreaTop: 0
            ),
            0,
            accuracy: 0.5,
            "Manually hosted minimal windows already have zero safe area, so the Bonsplit strip must not be pulled offscreen"
        )

        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: true,
                isFullScreen: false,
                titlebarPadding: 32,
                hostingSafeAreaTop: 28
            ),
            -28,
            accuracy: 0.5,
            "SwiftUI WindowGroup windows still need their native titlebar safe area cancelled"
        )
    }

    func testNotificationsPopoverVisibilityIsScopedByWindow() {
        let state = NotificationsPopoverVisibilityState.shared
        state.resetForTesting()
        defer { state.resetForTesting() }

        let firstPopover = NSObject()
        let secondPopover = NSObject()

        state.setShown(true, source: firstPopover, windowNumber: 101)
        XCTAssertTrue(state.isShown)
        XCTAssertTrue(state.isShown(in: 101))
        XCTAssertFalse(state.isShown(in: 202))

        state.setShown(true, source: secondPopover, windowNumber: 202)
        XCTAssertTrue(state.isShown(in: 101))
        XCTAssertTrue(state.isShown(in: 202))

        state.setShown(false, source: firstPopover)
        XCTAssertTrue(state.isShown)
        XCTAssertFalse(state.isShown(in: 101))
        XCTAssertTrue(state.isShown(in: 202))

        state.setShown(false, source: secondPopover)
        XCTAssertFalse(state.isShown)
        XCTAssertFalse(state.isShown(in: 101))
        XCTAssertFalse(state.isShown(in: 202))
    }

    func testWindowChromeTitlebarHeightClampsToSharedRange() {
        [WindowChromeMetrics.appTitlebarHeight, WindowChromeMetrics.bonsplitTabBarHeight, WindowChromeMetrics.secondaryTitlebarHeight, MinimalModeChromeMetrics.titlebarHeight, RightSidebarChromeMetrics.titlebarHeight, RightSidebarChromeMetrics.secondaryBarHeight].forEach { XCTAssertEqual($0, WindowChromeMetrics.sharedChromeBarHeight) }
        XCTAssertEqual(WindowChromeMetrics.clampedTitlebarHeight(12), 28)
        XCTAssertEqual(WindowChromeMetrics.clampedTitlebarHeight(32), 32)
        XCTAssertEqual(WindowChromeMetrics.clampedTitlebarHeight(96), 72)
    }

    func testRightSidebarHeaderChromeUsesSharedButtonsWithCompactIcons() {
        let titlebarConfig = TitlebarControlsStyle.classic.config

        XCTAssertEqual(HeaderChromeControlMetrics.buttonSize, titlebarConfig.buttonSize, accuracy: 0.001)
        XCTAssertEqual(HeaderChromeControlMetrics.iconSize, titlebarConfig.iconSize, accuracy: 0.001)
        XCTAssertEqual(HeaderChromeControlMetrics.cornerRadius, titlebarConfig.buttonCornerRadius, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.headerControlSize, titlebarConfig.buttonSize, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.headerIconSize, 10, accuracy: 0.001)
        XCTAssertEqual(
            RightSidebarChromeMetrics.headerIconFrameSize,
            RightSidebarChromeMetrics.headerIconSize,
            accuracy: 0.001
        )
        XCTAssertLessThan(RightSidebarChromeMetrics.headerIconSize, titlebarConfig.iconSize)
        XCTAssertLessThan(
            RightSidebarChromeMetrics.headerIconFrameSize,
            HeaderChromeIconStyle.iconFrameSize(forIconSize: titlebarConfig.iconSize)
        )
        XCTAssertEqual(RightSidebarChromeMetrics.headerControlCornerRadius, titlebarConfig.buttonCornerRadius, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.controlHeight, RightSidebarChromeMetrics.headerControlSize, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.barVerticalPadding, 4, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.headerControlCenterAlignmentAdjustment, 0, accuracy: 0.001)
    }

    func testRightSidebarPillChromeUsesHeaderIconColorAndWeight() {
        XCTAssertEqual(RightSidebarChromeControlStyle.iconWeight, HeaderChromeIconStyle.weight)
        XCTAssertEqual(RightSidebarChromeControlStyle.labelWeight, HeaderChromeIconStyle.weight)
        XCTAssertEqual(RightSidebarChromeControlStyle.modeIconSize, 11, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeControlStyle.secondaryIconSize, 10, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeControlStyle.labelSize, 11, accuracy: 0.001)
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: false, isHovered: false),
            HeaderChromeIconStyle.foregroundOpacity(isHovering: false, isPressed: false),
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: false, isHovered: true),
            HeaderChromeIconStyle.foregroundOpacity(isHovering: true, isPressed: false),
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: true, isHovered: false),
            HeaderChromeIconStyle.pressedOpacity,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: false, isHovered: true, isEnabled: false),
            HeaderChromeIconStyle.disabledOpacity,
            accuracy: 0.001
        )
    }

    func testMinimalModeCollapsedSidebarResyncsTrafficLightInsetAfterNewWorkspaceCreation() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
        }

        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: false, selection: .tabs, width: nil)
        )
        let windowId = appDelegate.createMainWindow(sessionWindowSnapshot: snapshot)
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected tab manager for created window")
            return
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: windowId), false)

        guard let sourceWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        // Recreate the regression shape: the window chrome state says minimal +
        // collapsed sidebar, but the selected workspace's live Bonsplit inset is stale.
        sourceWorkspace.bonsplitController.configuration.appearance.tabBarLeadingInset = 0

        guard let createdWorkspace = appDelegate.addWorkspaceInPreferredMainWindow(debugSource: "test.issue2737") else {
            XCTFail("Expected workspace creation to route to the test window")
            return
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        guard let newWorkspace = manager.tabs.first(where: { $0.id == createdWorkspace.id }) else {
            XCTFail("Expected new workspace in test window")
            return
        }

        XCTAssertEqual(
            newWorkspace.bonsplitController.configuration.appearance.tabBarLeadingInset,
            80,
            accuracy: 0.5,
            "New minimal-mode workspaces should reserve traffic-light space immediately even when the source workspace inset is stale"
        )
    }

    func testMinimalModeCollapsedSidebarSeedsTrafficLightInsetOnNewWindowCreation() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
        }

        // Simulate the new-window flow: createMainWindow with a snapshot that forces
        // sidebar collapsed. The initial workspace is created inside TabManager.init,
        // before ContentView.onAppear can run syncTrafficLightInset — so the seed in
        // createMainWindow is what protects the first render.
        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: false, selection: .tabs, width: nil)
        )
        let windowId = appDelegate.createMainWindow(sessionWindowSnapshot: snapshot)
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected tab manager for created window")
            return
        }

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: windowId), false)

        guard let initialWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace in fresh window")
            return
        }

        // No RunLoop spin before reading the inset — the seed must be applied by the
        // time createMainWindow returns, not lazily after onAppear runs.
        XCTAssertEqual(
            initialWorkspace.bonsplitController.configuration.appearance.tabBarLeadingInset,
            80,
            accuracy: 0.5,
            "New minimal-mode windows with collapsed sidebar should reserve traffic-light space on the initial workspace before first render"
        )
    }

    func testAttachUpdateAccessoryHidesTitlebarAccessoryWhenMinimalModeEnabled() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        let savedLegacyTitlebar = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.standard.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebar, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected main window")
            return
        }

        let titlebarAccessory: () -> NSTitlebarAccessoryViewController? = {
            window.titlebarAccessoryViewControllers.first {
                $0.view.identifier?.rawValue == "cmux.titlebarControls"
            }
        }

        guard let initialAccessory = titlebarAccessory() else {
            XCTFail("Expected visible-titlebar mode to attach the titlebar accessory")
            return
        }
        XCTAssertFalse(initialAccessory.isHidden, "Expected visible-titlebar mode to show the titlebar accessory")

        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        appDelegate.attachUpdateAccessory(to: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let minimalAccessory = titlebarAccessory() else {
            XCTFail("Minimal mode should keep a hidden titlebar accessory so shortcut-driven popovers still have a controller")
            return
        }
        XCTAssertTrue(minimalAccessory.isHidden, "Minimal mode should hide titlebar accessories")
        XCTAssertTrue(minimalAccessory.view.isHidden, "Minimal mode should hide the titlebar accessory view")
        XCTAssertEqual(minimalAccessory.view.alphaValue, 0, accuracy: 0.01)
    }

    func testWorkspaceButtonFadeModeDefaultsOffWhenTitlebarVisible() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defaults.set(true, forKey: WorkspaceTitlebarSettings.showTitlebarKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.disabled.rawValue
        )
    }

    func testWorkspaceButtonFadeModeDefaultsOnWhenTitlebarHidden() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.enabled.rawValue
        )
    }

    func testWorkspaceButtonFadeModeMigratesLegacyHoverVisibilityPreference() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.set(true, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set("always", forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.set("onHover", forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.enabled.rawValue
        )
    }

    func testWorkspaceButtonFadeModePreservesExistingStoredMode() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.set(WorkspaceButtonFadeSettings.Mode.disabled.rawValue, forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set("onHover", forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.set("onHover", forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.disabled.rawValue
        )
    }

    func testWorkspaceMinimalModeDefaultsToStandardPresentation() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        let savedLegacyTitlebar = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyFade = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebar, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyFade, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set(WorkspaceButtonFadeSettings.Mode.enabled.rawValue, forKey: WorkspaceButtonFadeSettings.modeKey)

        XCTAssertEqual(
            WorkspacePresentationModeSettings.mode(defaults: defaults),
            .standard
        )
    }

    func testKeyboardShortcutSettingsSetShortcutPostsSpecificChangeNotification() {
        let notificationName = Notification.Name("cmux.keyboardShortcutSettingsDidChange")
        let expectedAction = KeyboardShortcutSettings.Action.toggleSidebar.rawValue
        let expectation = expectation(forNotification: notificationName, object: nil) { notification in
            notification.userInfo?["action"] as? String == expectedAction
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "s", command: true, shift: false, option: false, control: true),
            for: .toggleSidebar
        )

        wait(for: [expectation], timeout: 0.2)
    }

    func testCmdPhysicalPWithDvorakCharactersDoesNotTriggerCommandPaletteSwitcher() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let switcherExpectation = expectation(description: "Cmd+L should not request command palette switcher")
        switcherExpectation.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Dvorak: physical ANSI "P" key can produce "l".
        // This should behave as Cmd+L, not as physical Cmd+P.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+L event on physical ANSI P key")
            return
        }

#if DEBUG
        _ = appDelegate.debugHandleCustomShortcut(event: event)
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdPWithCapsLockStillTriggersCommandPaletteSwitcher() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let switcherExpectation = expectation(description: "Cmd+P with Caps Lock should request command palette switcher")
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .capsLock],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Cmd+P + Caps Lock event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdPFallsBackToANSIKeyCodeWhenCharactersAndLayoutTranslationAreUnavailable() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.shortcutLayoutCharacterProvider = { _, _ in nil }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let switcherExpectation = expectation(description: "Cmd+P with unavailable characters should request command palette switcher")
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Cmd+P event with unavailable characters")
            return
        }

        XCTAssertTrue(appDelegate.handleBrowserSurfaceKeyEquivalent(event))
        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdPDoesNotFallbackToANSIKeyCodeWhenLayoutTranslationProvidesDifferentLetter() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.shortcutLayoutCharacterProvider = { _, _ in "b" }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let switcherExpectation = expectation(description: "Non-P layout translation should not request command palette switcher")
        switcherExpectation.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Cmd+P event with unavailable characters")
            return
        }

        _ = appDelegate.handleBrowserSurfaceKeyEquivalent(event)
        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdPFallsBackToCommandAwareLayoutTranslationWhenCharactersAreUnavailable() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.shortcutLayoutCharacterProvider = { keyCode, modifierFlags in
            guard keyCode == 35 else { return nil } // kVK_ANSI_P
            return modifierFlags.contains(.command) ? "p" : "r"
        }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let switcherExpectation = expectation(description: "Command-aware layout translation should request command palette switcher")
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Cmd+P event with unavailable characters")
            return
        }

        XCTAssertTrue(appDelegate.handleBrowserSurfaceKeyEquivalent(event))
        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdShiftPhysicalPWithDvorakCharactersDoesNotTriggerCommandPalette() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let paletteExpectation = expectation(description: "Cmd+Shift+L should not request command palette")
        paletteExpectation.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { _ in
            paletteExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Dvorak: physical ANSI "P" key can produce "l".
        // This should behave as Cmd+Shift+L, not as physical Cmd+Shift+P.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+Shift+L event on physical ANSI P key")
            return
        }

#if DEBUG
        _ = appDelegate.debugHandleCustomShortcut(event: event)
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [paletteExpectation], timeout: 0.15)
    }

    func testCmdOptionPhysicalTWithDvorakCharactersDoesNotTriggerCloseOtherTabsShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        // Dvorak: physical ANSI "T" key can produce "y".
        // This should not match the Cmd+Option+T app shortcut.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: 17 // kVK_ANSI_T
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+Option+Y event on physical ANSI T key")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdShiftPRequestsCommandPaletteCommands() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let paletteExpectation = expectation(description: "Expected command palette commands request for Cmd+Shift+P")
        var observedPaletteWindow: NSWindow?
        let paletteToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedPaletteWindow = notification.object as? NSWindow
            paletteExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(paletteToken) }

        let switcherExpectation = expectation(description: "Cmd+Shift+P should not request command palette switcher")
        switcherExpectation.isInverted = true
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        guard let event = makeKeyDownEvent(
            key: "P",
            modifiers: [.command, .shift],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [paletteExpectation, switcherExpectation], timeout: 1.0)
        XCTAssertEqual(observedPaletteWindow?.windowNumber, window.windowNumber)
    }

    func testCmdPStillRequestsCommandPaletteSwitcherWhilePaletteIsVisible() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { window.close() }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer { appDelegate.setCommandPaletteVisible(false, for: window) }

        let switcherExpectation = expectation(description: "Expected switcher request while command palette is visible")
        var observedSwitcherWindow: NSWindow?
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedSwitcherWindow = notification.object as? NSWindow
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        guard let event = makeKeyDownEvent(
            key: "p",
            modifiers: [.command],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [switcherExpectation], timeout: 1.0)
        XCTAssertEqual(observedSwitcherWindow?.windowNumber, window.windowNumber)
    }

    func testCmdShiftPStillRequestsCommandPaletteCommandsWhilePaletteIsVisible() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { window.close() }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer { appDelegate.setCommandPaletteVisible(false, for: window) }

        let paletteExpectation = expectation(description: "Expected commands request while command palette is visible")
        var observedPaletteWindow: NSWindow?
        let paletteToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedPaletteWindow = notification.object as? NSWindow
            paletteExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(paletteToken) }

        guard let event = makeKeyDownEvent(
            key: "P",
            modifiers: [.command, .shift],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [paletteExpectation], timeout: 1.0)
        XCTAssertEqual(observedPaletteWindow?.windowNumber, window.windowNumber)
    }

    func testCmdFFocusedBrowserOpensBrowserFind() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              manager.openBrowser(inWorkspace: workspace.id) != nil else {
            XCTFail("Expected focused browser panel")
            return
        }

        XCTAssertNotNil(manager.focusedBrowserPanel)
        XCTAssertNil(manager.focusedBrowserPanel?.searchState)
        let initialMode = appDelegate.fileExplorerState?.mode

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+F should open browser find when browser web content is focused"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertNotNil(manager.focusedBrowserPanel?.searchState)
        XCTAssertEqual(appDelegate.fileExplorerState?.mode, initialMode)
    }

    func testOmnibarArrowSelectionUsesResponderResolvedPanelWhenTrackedFocusWasCleared() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id) else {
            XCTFail("Expected focused browser panel")
            return
        }

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = browserPanelId
        field.stringValue = "example"
        attachTestResponder(field, to: window)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: browserPanelId)
        defer {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: browserPanelId)
            field.removeFromSuperview()
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(field.currentEditor())

        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: browserPanelId)

        let moveExpectation = expectation(
            description: "Expected omnibar move-selection notification for responder-resolved panel"
        )
        var observedPanelId: UUID?
        var observedDelta: Int?
        let moveToken = NotificationCenter.default.addObserver(
            forName: .browserMoveOmnibarSelection,
            object: nil,
            queue: nil
        ) { notification in
            observedPanelId = notification.object as? UUID
            observedDelta = notification.userInfo?["delta"] as? Int
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 1.0)
        XCTAssertEqual(observedPanelId, browserPanelId)
        XCTAssertEqual(observedDelta, 1)
    }

    func testOmnibarArrowSelectionDoesNotInterceptMarkedTextComposition() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id) else {
            XCTFail("Expected focused browser panel")
            return
        }

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = browserPanelId
        field.stringValue = "ㄉㄚˋ"
        attachTestResponder(field, to: window)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: browserPanelId)

        defer {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: browserPanelId)
            field.removeFromSuperview()
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard let fieldEditor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected omnibar field editor")
            return
        }
        fieldEditor.setMarkedText(
            "ㄉㄚˋ",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(fieldEditor.hasMarkedText())
        NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: browserPanelId)

        let moveExpectation = expectation(
            description: "Down Arrow belongs to the input method while omnibar marked text is active"
        )
        moveExpectation.isInverted = true
        let moveToken = NotificationCenter.default.addObserver(
            forName: .browserMoveOmnibarSelection,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.object as? UUID == browserPanelId else { return }
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 0.1)
    }

    func testOmnibarArrowSelectionSurvivesTransientWindowFirstResponder() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected focused browser panel")
            return
        }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = browserPanelId
        field.stringValue = "example"
        attachTestResponder(field, to: window)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: browserPanelId)
        defer {
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: browserPanelId)
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: browserPanelId)
            field.removeFromSuperview()
        }

        XCTAssertTrue(appDelegate.requestBrowserAddressBarFocus(panelId: browserPanelId))
        XCTAssertEqual(appDelegate.focusedBrowserAddressBarPanelId(), browserPanelId)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.firstResponder === window)

        let moveExpectation = expectation(
            description: "Expected omnibar move-selection notification while first responder is transiently the window"
        )
        var observedPanelId: UUID?
        var observedDelta: Int?
        let moveToken = NotificationCenter.default.addObserver(
            forName: .browserMoveOmnibarSelection,
            object: nil,
            queue: nil
        ) { notification in
            observedPanelId = notification.object as? UUID
            observedDelta = notification.userInfo?["delta"] as? Int
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 1.0)
        XCTAssertEqual(observedPanelId, browserPanelId)
        XCTAssertEqual(observedDelta, 1)
    }

    func testCmdPhysicalWWithDvorakCharactersDoesNotTriggerClosePanelShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window and workspace")
            return
        }

        let panelCountBefore = workspace.panels.count

        // Dvorak: physical ANSI "W" key can produce ",".
        // This should not match the Cmd+W close-panel shortcut.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: ",",
            charactersIgnoringModifiers: ",",
            isARepeat: false,
            keyCode: 13 // kVK_ANSI_W
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+, event on physical ANSI W key")
            return
        }

        withTemporaryShortcut(action: .openSettings, shortcut: .unbound) {
#if DEBUG
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        XCTAssertEqual(workspace.panels.count, panelCountBefore)
    }

    func testCmdIStillTriggersShowNotificationsShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(action: .showNotifications) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "i",
                charactersIgnoringModifiers: "i",
                isARepeat: false,
                keyCode: 34 // kVK_ANSI_I
            ) else {
                XCTFail("Failed to construct Cmd+I event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdUnshiftedSymbolDoesNotMatchDigitShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "8", command: true, shift: false, option: false, control: false)
        ) {
            withTemporaryShortcut(action: .focusHistoryForward, shortcut: .unbound) {
                withTemporaryShortcut(action: .browserForward, shortcut: .unbound) {
                    // Some non-US layouts can produce "*" without Shift.
                    // This must not be coerced into "8" for a Cmd+8 shortcut match.
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        characters: "*",
                        charactersIgnoringModifiers: "*",
                        isARepeat: false,
                        keyCode: 30 // kVK_ANSI_RightBracket
                    ) else {
                        XCTFail("Failed to construct Cmd+* event")
                        return
                    }

#if DEBUG
                    XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
                    XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
                }
            }
        }
    }

    func testCmdDigitShortcutFallsBackByKeyCodeOnSymbolFirstLayouts() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
        ) {
            // Symbol-first layouts (for example AZERTY) can report "&" for the ANSI 1 key.
            // Cmd+1 shortcuts should still match via keyCode fallback in this case.
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "&",
                charactersIgnoringModifiers: "&",
                isARepeat: false,
                keyCode: 18 // kVK_ANSI_1
            ) else {
                XCTFail("Failed to construct Cmd+& event on ANSI 1 key")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftNonDigitKeySymbolDoesNotMatchShiftedDigitShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "8", command: true, shift: true, option: false, control: false)
        ) {
            // Avoid unrelated default Cmd+Shift+] handling for this assertion.
            withTemporaryShortcut(
                action: .nextSurface,
                shortcut: StoredShortcut(key: "x", command: true, shift: true, option: false, control: false)
            ) {
                // On some non-US layouts, Shift+RightBracket can produce "*".
                // This must not be interpreted as Shift+8.
                guard let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.command, .shift],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: "*",
                    charactersIgnoringModifiers: "*",
                    isARepeat: false,
                    keyCode: 30 // kVK_ANSI_RightBracket
                ) else {
                    XCTFail("Failed to construct Cmd+Shift+* event from non-digit key")
                    return
                }

#if DEBUG
                XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            }
        }
    }

    func testCmdShiftDigitShortcutMatchesShiftedDigitKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "8", command: true, shift: true, option: false, control: false)
        ) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "*",
                charactersIgnoringModifiers: "*",
                isARepeat: false,
                keyCode: 28 // kVK_ANSI_8
            ) else {
                XCTFail("Failed to construct Cmd+Shift+8 event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftQuestionMarkMatchesSlashShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(
            action: .triggerFlash,
            shortcut: StoredShortcut(key: "/", command: true, shift: true, option: false, control: false)
        ) {
            let event = makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "?",
                charactersIgnoringModifiers: "?",
                keyCode: 44 // kVK_ANSI_Slash
            )

#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .triggerFlash))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testReactGrabShortcutIsConsumedWhenNoBrowserRouteExists() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(action: .toggleReactGrab) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "G",
                charactersIgnoringModifiers: "g",
                isARepeat: false,
                keyCode: 5
            ) else {
                XCTFail("Failed to construct Cmd+Shift+G event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftISOAngleBracketDoesNotMatchCommaShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: ",", command: true, shift: true, option: false, control: false)
        ) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "<",
                charactersIgnoringModifiers: "<",
                isARepeat: false,
                keyCode: 10 // kVK_ISO_Section
            ) else {
                XCTFail("Failed to construct Cmd+Shift+< event from ISO key")
                return
            }

#if DEBUG
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftRightBracketCanFallbackByKeyCodeOnNonUSLayouts() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(action: .nextSurface) {
            // Non-US layouts can report "*" (or other symbols) for kVK_ANSI_RightBracket with Shift.
            // Shortcut matching should still allow Cmd+Shift+] via keyCode fallback.
            let event = makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "*",
                charactersIgnoringModifiers: "*",
                keyCode: 30 // kVK_ANSI_RightBracket
            )

#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .nextSurface))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testConfiguredCmdPhysicalOWithDvorakCharactersTriggersRenameTabShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let renameTabExpectation = expectation(description: "Expected rename tab request for semantic Cmd+R")
        var observedRenameTabWindow: NSWindow?
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedRenameTabWindow = notification.object as? NSWindow
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        let switcherExpectation = expectation(description: "Cmd+R should not trigger command palette switcher")
        switcherExpectation.isInverted = true
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        withTemporaryShortcut(action: .renameTab) {
            // Dvorak: physical ANSI "O" key can produce "r".
            // This should behave as semantic Cmd+R (rename tab), not Cmd+P.
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "r",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: 31 // kVK_ANSI_O
            ) else {
                XCTFail("Failed to construct Dvorak Cmd+R event on physical ANSI O key")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        wait(for: [renameTabExpectation, switcherExpectation], timeout: 1.0)
        XCTAssertEqual(observedRenameTabWindow?.windowNumber, window.windowNumber)
    }

    func testCmdPhysicalRWithDvorakCharactersTriggersCommandPaletteSwitcher() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let switcherExpectation = expectation(description: "Expected command palette switcher request for semantic Cmd+P")
        var observedSwitcherWindow: NSWindow?
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedSwitcherWindow = notification.object as? NSWindow
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        let renameTabExpectation = expectation(description: "Physical R on Dvorak should not trigger rename tab")
        renameTabExpectation.isInverted = true
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        // Dvorak: physical ANSI "R" key can produce "p".
        // This should behave as semantic Cmd+P (palette switcher), not Cmd+R.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 15 // kVK_ANSI_R
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+P event on physical ANSI R key")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [switcherExpectation, renameTabExpectation], timeout: 1.0)
        XCTAssertEqual(observedSwitcherWindow?.windowNumber, window.windowNumber)
    }

    func testConfiguredCmdShiftRRequestsRenameWorkspaceInCommandPalette() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let workspaceExpectation = expectation(description: "Expected command palette rename workspace notification")
        var observedWorkspaceWindow: NSWindow?
        var didObserveWorkspaceNotification = false
        let workspaceToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameWorkspaceRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard !didObserveWorkspaceNotification else { return }
            didObserveWorkspaceNotification = true
            observedWorkspaceWindow = notification.object as? NSWindow
            workspaceExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(workspaceToken) }

        let renameTabExpectation = expectation(description: "Rename tab notification should not fire for Cmd+Shift+R")
        renameTabExpectation.isInverted = true
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        guard let event = makeKeyDownEvent(
            key: "r",
            modifiers: [.command, .shift],
            keyCode: 15, // kVK_ANSI_R
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+R event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [workspaceExpectation, renameTabExpectation], timeout: 1.0)
        XCTAssertEqual(observedWorkspaceWindow?.windowNumber, window.windowNumber)
    }

    func testCmdOptionERequestsEditWorkspaceDescriptionInCommandPalette() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let descriptionExpectation = expectation(description: "Expected command palette edit workspace description notification")
        var observedWorkspaceWindow: NSWindow?
        var didObserveDescriptionNotification = false
        let descriptionToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteEditWorkspaceDescriptionRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard !didObserveDescriptionNotification else { return }
            didObserveDescriptionNotification = true
            observedWorkspaceWindow = notification.object as? NSWindow
            descriptionExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(descriptionToken) }

        let renameWorkspaceExpectation = expectation(description: "Rename workspace notification should not fire for Cmd+Option+E")
        renameWorkspaceExpectation.isInverted = true
        let renameWorkspaceToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameWorkspaceRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameWorkspaceExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

        guard let event = makeKeyDownEvent(
            key: "e",
            modifiers: [.command, .option],
            keyCode: 14, // kVK_ANSI_E
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Option+E event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [descriptionExpectation, renameWorkspaceExpectation], timeout: 1.0)
        XCTAssertEqual(observedWorkspaceWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDismissesVisibleCommandPaletteAndIsConsumed() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        let dismissExpectation = expectation(description: "Expected command palette dismiss notification for Escape")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let event = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53, // kVK_Escape
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDoesNotDismissCommandPaletteWhenInputHasMarkedText() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let fieldEditor = CommandPaletteMarkedTextFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fieldEditor.isFieldEditor = true
        fieldEditor.hasMarkedTextForTesting = true
        window.contentView?.addSubview(fieldEditor)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
            fieldEditor.removeFromSuperview()
        }

        let dismissExpectation = expectation(
            description: "Escape should not dismiss command palette while IME marked text is active"
        )
        dismissExpectation.isInverted = true
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard let dismissWindow = notification.object as? NSWindow,
                  dismissWindow.windowNumber == window.windowNumber else { return }
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should pass through to IME composition instead of dismissing command palette"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 0.2)
    }

    func testEscapeDismissesCommandPaletteWhenVisibilitySyncLagsAfterOpenRequest() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let dismissExpectation = expectation(description: "Expected command palette dismiss notification for Escape")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

#if DEBUG
        appDelegate.debugMarkCommandPaletteOpenPending(window: window)
#else
        XCTFail("debugMarkCommandPaletteOpenPending is only available in DEBUG")
#endif

        // Model the normal open-palette state so the test reads like the user-facing scenario.
        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testArrowNavigationRoutesWhileCommandPaletteOverlayIsInteractiveBeforeVisibilitySync() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId),
              let contentView = window.contentView else {
            XCTFail("Expected test window")
            return
        }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let overlayHost = contentView.superview ?? contentView
        let overlayContainer = NSView(frame: overlayHost.bounds)
        overlayContainer.identifier = commandPaletteOverlayContainerIdentifier
        overlayContainer.alphaValue = 1
        overlayContainer.isHidden = false
        overlayHost.addSubview(overlayContainer)

        let fieldEditor = CommandPaletteMarkedTextFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fieldEditor.isFieldEditor = true
        overlayContainer.addSubview(fieldEditor)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        appDelegate.setCommandPaletteVisible(false, for: window)
        defer {
            overlayContainer.removeFromSuperview()
            fieldEditor.removeFromSuperview()
        }

        let moveExpectation = expectation(
            description: "Expected command palette move-selection notification while overlay is interactive"
        )
        var observedDelta: Int?
        var observedWindow: NSWindow?
        let moveToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteMoveSelection,
            object: nil,
            queue: nil
        ) { notification in
            observedWindow = notification.object as? NSWindow
            observedDelta = notification.userInfo?["delta"] as? Int
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        window.displayIfNeeded()
        XCTAssertTrue(
            window.makeFirstResponder(fieldEditor),
            "Expected command palette field editor to own first responder"
        )

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 1.0)
        XCTAssertEqual(observedWindow?.windowNumber, window.windowNumber)
        XCTAssertEqual(observedDelta, 1)
    }

    func testControlKDoesNotRoutePaletteMoveSelectionWhenSearchFieldIsFocused() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId),
              let contentView = window.contentView else {
            XCTFail("Expected test window")
            return
        }

        let overlayContainer = NSView(frame: contentView.bounds)
        overlayContainer.identifier = commandPaletteOverlayContainerIdentifier
        overlayContainer.alphaValue = 1
        overlayContainer.isHidden = false
        contentView.addSubview(overlayContainer)

        let fieldEditor = CommandPaletteMarkedTextFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fieldEditor.isFieldEditor = true
        overlayContainer.addSubview(fieldEditor)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        appDelegate.setCommandPaletteVisible(false, for: window)
        defer {
            overlayContainer.removeFromSuperview()
            fieldEditor.removeFromSuperview()
        }

        let moveExpectation = expectation(
            description: "Ctrl+K should not be rerouted as command palette move-selection"
        )
        moveExpectation.isInverted = true
        let moveToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteMoveSelection,
            object: nil,
            queue: nil
        ) { _ in
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let controlKEvent = makeKeyDownEvent(
            key: "\u{0b}",
            modifiers: [.control],
            keyCode: 40,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Ctrl+K event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: controlKEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 0.2)
    }

    func testEscapeDismissesCommandPaletteWhenVisibilityStateStaysStalePastInitialPendingWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 1.3),
            "Expected to backdate pending-open age for stale visibility test"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        // Simulate stale app-level visibility bookkeeping.
        appDelegate.setCommandPaletteVisible(false, for: window)

        let dismissExpectation = expectation(description: "Escape should dismiss stale-state command palette after delay")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDismissesCommandPaletteWhenVisibilityStateRemainsStaleForExtendedDelay() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 6.25),
            "Expected to backdate pending-open age for extended stale visibility test"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        // Simulate stale app-level visibility bookkeeping for a longer user delay.
        appDelegate.setCommandPaletteVisible(false, for: window)

        let dismissExpectation = expectation(description: "Escape should dismiss stale-state command palette after extended delay")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDoesNotConsumeWhenMenuTriggeredPendingOpenStateExpires() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        window.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 20.0),
            "Expected to seed an expired pending-open request state"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        appDelegate.setCommandPaletteVisible(false, for: window)

        let dismissExpectation = expectation(description: "No dismiss notification for expired pending-open state")
        dismissExpectation.isInverted = true
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { _ in
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should pass through once pending-open grace has expired"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 0.2)
    }

    func testEscapeDismissesMenuTriggeredCommandPaletteWhenVisibilitySyncIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        // Reproduce the menu-command path (Cmd+Shift+P/Cmd+P) routed via AppDelegate.
        appDelegate.requestCommandPaletteCommands(
            preferredWindow: window,
            source: "test.menuCommandPalette"
        )
        // Simulate delayed/stale visibility sync from SwiftUI overlay state.
        appDelegate.setCommandPaletteVisible(false, for: window)
#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 0.1),
            "Expected deterministic pending-open state for menu-triggered stale-visibility path"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        let dismissExpectation = expectation(description: "Expected command palette dismiss notification for menu-triggered stale visibility")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should still be consumed for menu-triggered command palette opens"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeRepeatIsConsumedImmediatelyAfterPaletteDismiss() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        guard let firstEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct first Escape event")
            return
        }

        guard let repeatedEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: true
        ) else {
            XCTFail("Failed to construct repeated Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: firstEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        // Simulate the palette overlay synchronizing to closed state while the Escape key is still held.
        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: repeatedEscape),
            "Repeated Escape immediately after dismiss should be consumed to prevent terminal passthrough"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeKeyUpIsConsumedAfterPaletteDismissToPreventTerminalLeak() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        guard let escapeKeyDown = makeKeyEvent(
            type: .keyDown,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape keyDown event")
            return
        }

        guard let escapeKeyUp = makeKeyEvent(
            type: .keyUp,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape keyUp event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyDown))
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif

        // Simulate the palette overlay synchronizing to closed state before Escape key-up arrives.
        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyUp),
            "Escape keyUp after palette dismiss should be consumed to prevent terminal passthrough"
        )
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif
    }

    func testEscapeKeyUpIsConsumedAfterCmdPSwitcherDismiss() {
        assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest { appDelegate, window in
            appDelegate.requestCommandPaletteSwitcher(
                preferredWindow: window,
                source: "test.cmdP"
            )
        }
    }

    func testEscapeKeyUpIsConsumedAfterCmdShiftPCommandsDismiss() {
        assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest { appDelegate, window in
            appDelegate.requestCommandPaletteCommands(
                preferredWindow: window,
                source: "test.cmdShiftP"
            )
        }
    }

    func testEscapeDoesNotDismissPaletteInDifferentWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let paletteWindowId = appDelegate.createMainWindow()
        let eventWindowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: paletteWindowId)
            closeWindow(withId: eventWindowId)
        }

        guard let paletteWindow = window(withId: paletteWindowId),
              let eventWindow = window(withId: eventWindowId) else {
            XCTFail("Expected both test windows")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: paletteWindow)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: paletteWindow)
        }

        let dismissExpectation = expectation(description: "Escape in another window should not dismiss palette")
        dismissExpectation.isInverted = true
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { _ in
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: eventWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should remain scoped to the event window"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 0.2)
    }

    func testCmdDigitDoesNotFallbackToOtherWindowWhenEventWindowContextIsMissing() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        _ = firstManager.addTab(select: true)
        _ = secondManager.addTab(select: true)
        guard let firstSelectedBefore = firstManager.selectedTabId,
              let secondSelectedBefore = secondManager.selectedTabId else {
            XCTFail("Expected selected tabs in both windows")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Force stale app-level manager to first window while keyboard event
        // references no known window.
        appDelegate.tabManager = firstManager

        guard let event = makeKeyDownEvent(
            key: "1",
            modifiers: [.command],
            keyCode: 18,
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+1 event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.selectedTabId, firstSelectedBefore, "Unresolved event window must not route Cmd+1 into stale manager")
        XCTAssertEqual(secondManager.selectedTabId, secondSelectedBefore, "Unresolved event window must not route Cmd+1 into key/main fallback manager")
        XCTAssertTrue(appDelegate.tabManager === firstManager, "Unresolved event window should not retarget active manager")
    }

    func testCmdNDoesNotFallbackToOtherWindowWhenEventWindowContextIsMissing() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count
        appDelegate.tabManager = firstManager

        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command],
            keyCode: 45,
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Unresolved event window must not create workspace in stale manager")
        XCTAssertEqual(secondManager.tabs.count, secondCount, "Unresolved event window must not create workspace in fallback window")
        XCTAssertTrue(appDelegate.tabManager === firstManager, "Unresolved event window should not retarget active manager")
    }

    func testCmdShiftMReturnsFalseWhenNoFocusedTerminalCanHandle() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Force unresolved shortcut routing context and no active manager.
        appDelegate.tabManager = nil

        guard let event = makeKeyDownEvent(
            key: "m",
            modifiers: [.command, .shift],
            keyCode: 46, // kVK_ANSI_M
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+Shift+M event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+Shift+M should not be consumed when no terminal can toggle copy mode"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testPresentPreferencesWindowShowsCustomSettingsWindowAndActivates() {
        var showFallbackSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(showFallbackSettingsWindowCallCount, 1)
        XCTAssertEqual(activateApplicationCallCount, 1)
        XCTAssertEqual(receivedNavigationTargets, [nil])
    }

    func testPresentPreferencesWindowSupportsRepeatedCalls() {
        var showFallbackSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(showFallbackSettingsWindowCallCount, 2)
        XCTAssertEqual(activateApplicationCallCount, 2)
        XCTAssertEqual(receivedNavigationTargets, [nil, nil])
    }

    func testPresentPreferencesWindowForwardsNavigationTarget() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            navigationTarget: .keyboardShortcuts,
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(receivedNavigationTarget, .keyboardShortcuts)
        XCTAssertEqual(activateApplicationCallCount, 1)
    }

    func testPresentPreferencesWindowForwardsBrowserImportNavigationTarget() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            navigationTarget: .browserImport,
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(receivedNavigationTarget, .browserImport)
        XCTAssertEqual(activateApplicationCallCount, 1)
    }

    // MARK: - Shortcut settings consultation regression tests

    func testExampleShortcutRoutingConsultsConfiguredShortcutSettings() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let cases: [(action: KeyboardShortcutSettings.Action, modifiers: NSEvent.ModifierFlags, key: String, keyCode: UInt16)] = [
            (
                .toggleRightSidebar,
                [.command, .option],
                "b",
                11
            ),
            (
                .focusRightSidebar,
                [.command, .shift],
                "e",
                14
            ),
            (
                .findInDirectory,
                [.command, .shift],
                "f",
                3
            ),
            (
                .toggleUnread,
                [.command, .option],
                "u",
                32
            ),
        ]

        for testCase in cases {
            var observedActions: [KeyboardShortcutSettings.Action] = []
            #if DEBUG
            KeyboardShortcutSettings.shortcutLookupObserver = { action in
                observedActions.append(action)
            }
            #else
            XCTFail("shortcutLookupObserver is only available in DEBUG")
            #endif

            guard let event = makeKeyDownEvent(
                key: testCase.key,
                modifiers: testCase.modifiers,
                keyCode: testCase.keyCode,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct \(testCase.action.rawValue) shortcut event")
                return
            }

            #if DEBUG
            _ = appDelegate.debugHandleCustomShortcut(event: event)
            #else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            #endif

            XCTAssertTrue(
                observedActions.contains(testCase.action),
                "\(testCase.action.rawValue) routing must read KeyboardShortcutSettings.shortcut(for:) instead of matching a literal combo"
            )
        }
    }

    func testBrowserFindCommandPreflightConsultsConfiguredFindFamilyShortcuts() {
        #if DEBUG
        let cases: [(action: KeyboardShortcutSettings.Action, modifiers: NSEvent.ModifierFlags, key: String, keyCode: UInt16)] = [
            (.find, [.command], "f", 3),
            (.findInDirectory, [.command, .shift], "f", 3),
            (.findNext, [.command], "g", 5),
            (.findPrevious, [.command, .option], "g", 5),
            (.hideFind, [.command, .option, .shift], "f", 3),
            (.useSelectionForFind, [.command], "e", 14),
        ]

        for testCase in cases {
            var observedActions: [KeyboardShortcutSettings.Action] = []
            KeyboardShortcutSettings.shortcutLookupObserver = { action in
                observedActions.append(action)
            }

            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.key,
                charactersIgnoringModifiers: testCase.key,
                keyCode: testCase.keyCode
            )

            _ = shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event)

            XCTAssertTrue(
                observedActions.contains(testCase.action),
                "Browser find command preflight must read the configured \(testCase.action.rawValue) shortcut instead of matching a literal combo"
            )
        }
        #else
        XCTFail("shortcutLookupObserver is only available in DEBUG")
        #endif
    }

    // MARK: - Browser find shortcut routing tests

    func testBrowserFirstFindShortcutRoutingRecognizesBrowserLocalFindCommandFamily() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-g", [.command], "g", 5),
            ("cmd-option-g", [.command, .option], "g", 5),
            ("cmd-option-shift-f", [.command, .option, .shift], "f", 3),
            ("cmd-e", [.command], "e", 14),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )
            XCTAssertTrue(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Expected browser-first routing for \(testCase.name)"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingExcludesAppOwnedFindCommands() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-f", [.command], "f", 3),
            ("cmd-shift-f", [.command, .shift], "f", 3),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )

            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "\(testCase.name) belongs to cmux find routing, not browser-first routing"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingFallsBackToKeyCodeForNonLatinInput() {
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "",
            charactersIgnoringModifiers: "п", // Cyrillic p from a non-Latin input source
            keyCode: 5 // kVK_ANSI_G
        )

        XCTAssertTrue(
            shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
            "Expected browser-first routing to keep Cmd+G eligible under non-Latin input"
        )
    }

    func testBrowserFirstFindShortcutRoutingDoesNotUseANSIPositionsForMismatchedASCIICharacters() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-u-on-ansi-f", [.command], "u", 3),
            ("cmd-o-on-ansi-g", [.command], "o", 5),
            ("cmd-period-on-ansi-e", [.command], ".", 14),
            ("cmd-shift-u-on-ansi-f", [.command, .shift], "u", 3),
            ("cmd-shift-o-on-ansi-g", [.command, .shift], "o", 5),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )

            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Did not expect browser-first routing for mismatched ASCII shortcut \(testCase.name)"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingExcludesWebInspectorResponders() {
        let inspectorContainer = FakeWKInspectorContainerView(frame: .zero)
        let inspectorChild = NSView(frame: .zero)
        inspectorContainer.addSubview(inspectorChild)

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "g",
            charactersIgnoringModifiers: "g",
            keyCode: 5
        )

        XCTAssertFalse(
            shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
                event,
                responder: inspectorChild
            ),
            "Did not expect browser-first routing while a Web Inspector responder is focused"
        )
    }

    func testBrowserFirstFindShortcutRoutingExcludesNonFindCommands() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-n", [.command], "n", 45),
            ("cmd-w", [.command], "w", 13),
            ("cmd-l", [.command], "l", 37),
            ("cmd-option-f", [.command, .option], "f", 3),
            ("cmd-shift-g-toggle-react-grab", [.command, .shift], "g", 5),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )
            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Did not expect browser-first routing for \(testCase.name)"
            )
        }
    }

    func testInlineVSCodeCommandPaletteShortcutRoutesThroughWebContentForTrackedServeWebOrigin() {
        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "P",
            charactersIgnoringModifiers: "p",
            keyCode: 35
        )
        let pageURL = URL(string: "http://127.0.0.1:63266/?folder=%2FUsers%2Ftester%2Fproject")!

        XCTAssertTrue(
            shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
                event,
                pageURL: pageURL,
                inlineVSCodeURLMatcher: { $0 == pageURL },
                shortcutForAction: { action in
                    XCTAssertEqual(action, .commandPalette)
                    return StoredShortcut(key: "p", command: true, shift: true, option: false, control: false, keyCode: 35)
                }
            ),
            "Expected Cmd+Shift+P to stay inside inline VS Code when the focused browser URL belongs to the live serve-web process"
        )
    }

    func testInlineVSCodeCommandPaletteShortcutDoesNotRouteForUntrackedLocalhostPage() {
        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "P",
            charactersIgnoringModifiers: "p",
            keyCode: 35
        )
        let pageURL = URL(string: "http://127.0.0.1:3000/?folder=%2FUsers%2Ftester%2Fproject")!

        XCTAssertFalse(
            shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
                event,
                pageURL: pageURL,
                inlineVSCodeURLMatcher: { _ in false },
                shortcutForAction: { _ in
                    StoredShortcut(key: "p", command: true, shift: true, option: false, control: false, keyCode: 35)
                }
            ),
            "A localhost page with a folder query must not steal cmux's command palette shortcut unless it is the tracked VS Code serve-web origin"
        )
    }

    func testInlineVSCodeCommandPaletteShortcutDoesNotRouteUnrelatedShortcut() {
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "l",
            charactersIgnoringModifiers: "l",
            keyCode: 37
        )
        let pageURL = URL(string: "http://127.0.0.1:63266/?folder=%2FUsers%2Ftester%2Fproject")!

        XCTAssertFalse(
            shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
                event,
                pageURL: pageURL,
                inlineVSCodeURLMatcher: { $0 == pageURL },
                shortcutForAction: { _ in
                    StoredShortcut(key: "p", command: true, shift: true, option: false, control: false, keyCode: 35)
                }
            ),
            "Only the configured command palette shortcut should bypass cmux for inline VS Code"
        )
    }

    // MARK: - Non-Latin keyboard layout shortcut tests

    func testCmdTWorksWithRussianKeyboardLayout() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window context")
            return
        }

        let surfaceCountBefore = workspace.panels.count

        // Simulate Russian keyboard: layout provider returns "t" via ASCII fallback,
        // but event.charactersIgnoringModifiers returns Cyrillic "е".
        appDelegate.shortcutLayoutCharacterProvider = { keyCode, _ in
            keyCode == 17 ? "t" : nil
        }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "е", // Cyrillic е (Russian layout)
            isARepeat: false,
            keyCode: 17 // kVK_ANSI_T
        ) else {
            XCTFail("Failed to construct Russian-layout Cmd+T event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event), "Cmd+T should be handled with Russian keyboard layout")
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(workspace.panels.count, surfaceCountBefore + 1, "Cmd+T should create a new surface with Russian keyboard layout")
    }

    func testCmdTFallsBackToKeyCodeWithNonLatinLayoutWhenLayoutTranslationFails() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Simulate non-Latin layout where layout translation also fails (returns nil).
        // The ANSI keyCode fallback should still match the physical T key.
        appDelegate.shortcutLayoutCharacterProvider = { _, _ in nil }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "",
            charactersIgnoringModifiers: "е", // Cyrillic е — non-ASCII
            keyCode: 17 // kVK_ANSI_T
        )

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugMatchesConfiguredShortcut(event: event, action: .newSurface),
            "Cmd+T should fall back to keyCode with non-Latin layout"
        )
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testPrintableOptionTextBypassesConfiguredShortcutRouting() throws {
#if DEBUG
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window context")
            return
        }

        let workspaceCountBefore = manager.tabs.count
        let optionQShortcut = StoredShortcut(
            key: "q",
            command: false,
            shift: false,
            option: true,
            control: false
        )

        withTemporaryShortcut(action: .newTab, shortcut: optionQShortcut) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "@",
                charactersIgnoringModifiers: "q",
                isARepeat: false,
                keyCode: 12 // kVK_ANSI_Q
            ) else {
                XCTFail("Failed to construct Turkish-Q Option+Q event")
                return
            }

            XCTAssertFalse(
                appDelegate.debugHandleCustomShortcut(event: event),
                "Option+Q that produces @ on Turkish Q should pass through as text input"
            )
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            XCTAssertEqual(
                manager.tabs.count,
                workspaceCountBefore,
                "Printable Option text should not trigger the remapped New Workspace shortcut"
            )
        }
#else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
#endif
    }

    func testWindowSendEventRepairsLostFirstResponderForFocusedTerminalTyping() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        focusHostedTerminalForRepairTesting(window: window, hostedView: terminalPanel.hostedView)

        let orphanResponder = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        installStrandedResponderDriftForTesting(orphanResponder, in: window, hostedView: terminalPanel.hostedView)

#if DEBUG
        appDelegate.debugSetShortcutRoutingKeyRepairFirstResponderForTesting(orphanResponder)
        defer { appDelegate.debugSetShortcutRoutingKeyRepairFirstResponderForTesting(nil) }

        let repairProbe = installFocusedTerminalRepairProbeForTesting(appDelegate: appDelegate, keyCode: 0)
        defer { repairProbe.restore() }

#else
        throw XCTSkip("DEBUG-only simulated responder override is required for deterministic key-repair coverage")
#endif

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

        window.sendEvent(keyDown)
        waitUntil(timeout: 1.0) {
            terminalPanel.hostedView.isSurfaceViewFirstResponder() && window.firstResponder === terminalView
        }

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Typing should repair first responder back to the focused terminal surface"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Typing repair should restore the Ghostty surface view as first responder")
#if DEBUG
        XCTAssertEqual(repairProbe.repairCount(), 1, "window.sendEvent should run the focused terminal repair path")
        XCTAssertTrue(repairProbe.repairResponder() === orphanResponder, "Repair should evaluate the simulated stranded responder")
        XCTAssertGreaterThan(
            repairProbe.forwardedKeyDownCount(),
            0,
            "Typing repair should forward the keyDown into Ghostty"
        )
#endif
    }

    func testWindowPerformKeyEquivalentDefersTerminalPasteMenuMissToGhosttyBindingResolution() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let probeView = GhosttyCommandEquivalentProbeView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let emptyMenu = NSMenu(title: "Test")
        emptyMenu.addItem(withTitle: "Placeholder", action: nil, keyEquivalent: "")
        NSApp.mainMenu = emptyMenu

        probeWindow.contentView = contentView
        contentView.addSubview(probeView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(probeView), "Expected probe Ghostty view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "v",
            modifiers: [.command],
            keyCode: 9,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+V event")
            return
        }

        XCTAssertTrue(
            probeWindow.performKeyEquivalent(with: event),
            "Cmd+V menu miss should still route through Ghostty binding resolution"
        )
        XCTAssertEqual(probeView.afterMenuMissCallCount, 1, "Ghostty binding resolution should run after the menu miss")
        XCTAssertEqual(probeView.pasteCallCount, 0, "Window routing must not force paste before Ghostty inspects bindings")
        XCTAssertEqual(
            probeView.pasteAsPlainTextCallCount,
            0,
            "Window routing must not force plain-text paste before Ghostty inspects bindings"
        )
    }

    func testWindowPerformKeyEquivalentForwardsClearedCmdDPastStaleMenuShortcut() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let probeView = GhosttyCommandEquivalentProbeView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let staleMenu = NSMenu(title: "Test")
        let staleSplitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        staleSplitItem.keyEquivalentModifierMask = [.command]
        staleSplitItem.target = menuProbe
        staleMenu.addItem(staleSplitItem)
        NSApp.mainMenu = staleMenu

        probeWindow.contentView = contentView
        contentView.addSubview(probeView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(probeView), "Expected probe Ghostty view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        withTemporaryShortcut(action: .splitRight, shortcut: .unbound) {
            XCTAssertTrue(
                probeWindow.performKeyEquivalent(with: event),
                "Cleared Cmd+D should still be handled by forwarding it to the focused terminal"
            )
        }

        XCTAssertEqual(menuProbe.callCount, 0, "A stale menu equivalent must not keep consuming cleared Cmd+D")
        XCTAssertEqual(probeView.keyDownCallCount, 1, "Cleared Cmd+D should be forwarded into the terminal")
        XCTAssertEqual(probeView.lastKeyDownCharactersIgnoringModifiers, "d")
    }

    func testWindowPerformKeyEquivalentSuppressesRemappedCmdDStaleMenuShortcut() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let focusableView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let staleMenu = NSMenu(title: "Test")
        let staleSplitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        staleSplitItem.keyEquivalentModifierMask = [.command]
        staleSplitItem.target = menuProbe
        staleMenu.addItem(staleSplitItem)
        NSApp.mainMenu = staleMenu

        probeWindow.contentView = contentView
        contentView.addSubview(focusableView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(focusableView), "Expected probe view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        let remappedSplitRight = StoredShortcut(
            key: "j",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        withTemporaryShortcut(action: .splitRight, shortcut: remappedSplitRight) {
            XCTAssertFalse(
                probeWindow.performKeyEquivalent(with: event),
                "Remapped Cmd+D should not be consumed by stale cmux menu equivalents"
            )
        }

        XCTAssertEqual(menuProbe.callCount, 0, "Cmd+D must not keep splitting after splitRight is remapped")
    }

    func testCurrentGlobalSearchShortcutIsNotSuppressedAsStaleMenuShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        let remappedGlobalSearch = StoredShortcut(
            key: "d",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        withTemporaryShortcut(action: .globalSearch, shortcut: remappedGlobalSearch) {
            XCTAssertFalse(
                appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                "Current globalSearch remaps must not be treated as stale menu shortcuts"
            )
        }
    }

    func testCurrentNumberedDigitShortcutIsNotSuppressedAsStaleMenuShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "2",
            modifiers: [.command],
            keyCode: 19,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+2 event")
            return
        }

        let remappedWorkspaceNumber = StoredShortcut(
            key: "1",
            command: false,
            shift: false,
            option: false,
            control: true
        )
        let currentSurfaceNumber = StoredShortcut(
            key: "1",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        withTemporaryShortcut(action: .selectWorkspaceByNumber, shortcut: remappedWorkspaceNumber) {
            withTemporaryShortcut(action: .selectSurfaceByNumber, shortcut: currentSurfaceNumber) {
                XCTAssertFalse(
                    appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                    "A current numbered-digit shortcut must own Cmd+2 before stale menu suppression"
                )
            }
        }
    }

    func testStaleCloseDefaultShortcutsSuppressMenuFallbackAfterReassignment() {
        assertStaleCloseDefaultShortcutSuppressesMenuFallback(
            staleAction: .closeTab,
            replacementAction: .newTab,
            replacementShortcut: StoredShortcut(key: "w", command: true, shift: false, option: false, control: false),
            remappedStaleShortcut: StoredShortcut(key: "w", command: true, shift: false, option: true, control: false)
        )

        assertStaleCloseDefaultShortcutSuppressesMenuFallback(
            staleAction: .closeWorkspace,
            replacementAction: .newWindow,
            replacementShortcut: StoredShortcut(key: "w", command: true, shift: true, option: false, control: false),
            remappedStaleShortcut: StoredShortcut(key: "w", command: true, shift: true, option: true, control: false)
        )

        assertStaleCloseDefaultShortcutSuppressesMenuFallback(
            staleAction: .closeWindow,
            replacementAction: .toggleFullScreen,
            replacementShortcut: StoredShortcut(key: "w", command: true, shift: false, option: false, control: true),
            remappedStaleShortcut: StoredShortcut(key: "w", command: true, shift: false, option: true, control: true)
        )
    }

    func testApplicationSendEventRoutesReassignedCmdWBeforeStaleCloseTabMenuEquivalent() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        AppDelegate.installWindowResponderSwizzlesForTesting()

        let windowId = appDelegate.createMainWindow()
        guard let window = appDelegate.windowForMainWindowId(windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let initialSidebarVisible = appDelegate.sidebarVisibility(windowId: windowId) else {
            closeWindow(withId: windowId)
            XCTFail("Expected a main window context")
            return
        }

        let previousMainMenu = NSApp.mainMenu
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            closeWindow(withId: windowId)
        }

        let staleMenu = NSMenu(title: "Test")
        let staleCloseItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "w"
        )
        staleCloseItem.keyEquivalentModifierMask = [.command]
        staleCloseItem.target = menuProbe
        staleMenu.addItem(staleCloseItem)
        NSApp.mainMenu = staleMenu

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

        let initialWorkspaceCount = manager.tabs.count
        let remappedCloseTab = StoredShortcut(key: "w", command: true, shift: false, option: true, control: false)
        let reassignedSidebarToggle = StoredShortcut(key: "w", command: true, shift: false, option: false, control: false)

        withTemporaryShortcut(action: .closeTab, shortcut: remappedCloseTab) {
            withTemporaryShortcut(action: .toggleSidebar, shortcut: reassignedSidebarToggle) {
                NSApp.sendEvent(event)
            }
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(menuProbe.callCount, 0, "A stale Cmd+W Close Tab menu item must not run after Cmd+W is reassigned")
        XCTAssertEqual(
            manager.tabs.count,
            initialWorkspaceCount,
            "Plain Cmd+W must not close a tab after Close Tab is remapped away"
        )
        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: windowId),
            !initialSidebarVisible,
            "The action currently assigned to Cmd+W should run before stale Close Tab menu fallback"
        )
    }

    func testApplicationSendEventSuppressesRemappedCmdDStaleMenuShortcut() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let focusableView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let staleMenu = NSMenu(title: "Test")
        let staleSplitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        staleSplitItem.keyEquivalentModifierMask = [.command]
        staleSplitItem.target = menuProbe
        staleMenu.addItem(staleSplitItem)
        NSApp.mainMenu = staleMenu

        probeWindow.contentView = contentView
        contentView.addSubview(focusableView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(focusableView), "Expected probe view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        let remappedSplitRight = StoredShortcut(
            key: "j",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        withTemporaryShortcut(action: .splitRight, shortcut: remappedSplitRight) {
            NSApp.sendEvent(event)
        }

        XCTAssertEqual(menuProbe.callCount, 0, "App-level Cmd+D dispatch must not fire a stale split menu item after remap")
    }

    func testApplicationSendEventRoutesCmdDMenuEquivalentToActiveShortcutRecorder() {
#if DEBUG
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let recorder = ShortcutRecorderNSButton(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        let menuProbe = MenuActionProbe()
        var recordedShortcut: StoredShortcut?

        defer {
            KeyboardShortcutRecorderActivity.stopAllRecording()
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let menu = NSMenu(title: "Test")
        let splitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        splitItem.keyEquivalentModifierMask = [.command]
        splitItem.target = menuProbe
        menu.addItem(splitItem)
        NSApp.mainMenu = menu

        recorder.onShortcutRecorded = { recordedShortcut = $0 }
        probeWindow.contentView = contentView
        contentView.addSubview(recorder)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(recorder), "Expected shortcut recorder to own first responder")
        recorder.performClick(nil)
        XCTAssertTrue(recorder.debugIsRecording)

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        withTemporaryShortcut(action: .splitRight) {
            NSApp.sendEvent(event)
        }

        XCTAssertEqual(
            recordedShortcut,
            StoredShortcut(key: "d", command: true, shift: false, option: false, control: false, keyCode: 2),
            "Cmd+D must remain recordable while the same menu equivalent is installed"
        )
        XCTAssertEqual(menuProbe.callCount, 0, "The menu equivalent must not fire while the recorder is capturing")
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testWindowSendEventRepairsVisibleSameWindowResponderDriftForFocusedTerminalTyping() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let strayView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        focusHostedTerminalForRepairTesting(window: window, hostedView: terminalPanel.hostedView)
        installVisibleResponderDriftForTesting(
            strayView,
            in: window,
            hostedView: terminalPanel.hostedView,
            mismatchMessage: "Expected the simulated responder to disagree with the focused terminal"
        )
        defer { strayView.removeFromSuperview() }

#if DEBUG
        appDelegate.debugSetShortcutRoutingKeyRepairFirstResponderForTesting(strayView)
        defer { appDelegate.debugSetShortcutRoutingKeyRepairFirstResponderForTesting(nil) }

        let repairProbe = installFocusedTerminalRepairProbeForTesting(appDelegate: appDelegate, keyCode: 0)
        defer { repairProbe.restore() }

#else
        throw XCTSkip("DEBUG-only simulated responder override is required for deterministic key-repair coverage")
#endif

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

        window.sendEvent(keyDown)
        waitUntil(timeout: 1.0) {
            terminalPanel.hostedView.isSurfaceViewFirstResponder() && window.firstResponder === terminalView
        }

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Typing should repair first responder back to the focused terminal surface"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Typing repair should restore the Ghostty surface view as first responder")
#if DEBUG
        XCTAssertEqual(repairProbe.repairCount(), 1, "window.sendEvent should run the focused terminal repair path")
        XCTAssertTrue(repairProbe.repairResponder() === strayView, "Repair should evaluate the simulated wrong same-window responder")
        XCTAssertGreaterThan(
            repairProbe.forwardedKeyDownCount(),
            0,
            "Typing repair should forward the keyDown into Ghostty"
        )
#endif
    }

    func testFocusTextBoxShortcutMovesFocusBackToTerminalWhenTextBoxIsFirstResponder() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        textBoxView.onToggleFocus = { _ = terminalPanel.focusTextBoxInputOrTerminal() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        attachTestResponder(textBoxScrollView, to: window)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before TextBox focus"
        )

        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        XCTAssertTrue(window.firstResponder === textBoxView, "Expected TextBox to own first responder")
        XCTAssertEqual(
            terminalPanel.captureFocusIntent(in: window),
            .terminal(.textBoxInput),
            "TextBox focus must be represented as a terminal panel focus intent"
        )

        let focusTextBoxShortcut = StoredShortcut(
            key: "a",
            command: true,
            shift: true,
            option: false,
            control: false,
            keyCode: 0
        )
        guard let event = makeKeyDownEvent(
            shortcut: focusTextBoxShortcut,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+A event")
            return
        }

        withTemporaryShortcut(action: .focusTextBoxInput, shortcut: focusTextBoxShortcut) {
            window.sendEvent(event)
        }
        waitFor(
            timeout: 1.0,
            until: { terminalPanel.hostedView.isSurfaceViewFirstResponder() }
        )

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Cmd+Shift+A from TextBox must move AppKit first responder back to the terminal"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Terminal must be the only focused input endpoint")
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.surface))
    }

    func testTextBoxConfiguredShortcutStandsDownWhilePackageRecorderIsActive() {
        let focusTextBoxShortcut = StoredShortcut(
            key: "a",
            command: true,
            shift: true,
            option: false,
            control: false,
            keyCode: 0
        )
        guard let event = makeKeyDownEvent(
            shortcut: focusTextBoxShortcut,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+Shift+A event")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        var toggleFocusCount = 0
        textBoxView.onToggleFocus = { toggleFocusCount += 1 }

        withTemporaryShortcut(action: .focusTextBoxInput, shortcut: focusTextBoxShortcut) {
            XCTAssertTrue(textBoxView.performKeyEquivalent(with: event))
            XCTAssertEqual(toggleFocusCount, 1)

            let recorder = RecorderHostButton(frame: .zero)
            defer {
                if RecorderHostButton.isActivelyRecording {
                    recorder.debugStopRecording()
                }
            }
            recorder.debugStartRecording()

            XCTAssertTrue(RecorderHostButton.isActivelyRecording)
            XCTAssertFalse(textBoxView.performKeyEquivalent(with: event))
            XCTAssertEqual(toggleFocusCount, 1)
        }
    }

    func testTextBoxSecondEscapeDoesNotHideWhenAnotherResponderOwnsFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 36, width: 120, height: 24))
        contentView.addSubview(textBoxScrollView)
        contentView.addSubview(otherView)
        defer {
            textBoxScrollView.removeFromSuperview()
            otherView.removeFromSuperview()
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        XCTAssertTrue(window.firstResponder === textBoxView)
        terminalPanel.handleTextBoxEscape()
        XCTAssertTrue(terminalPanel.isTextBoxActive)
        XCTAssertTrue(window.makeFirstResponder(otherView))

        XCTAssertFalse(terminalPanel.consumeTextBoxHideEscapeIfArmed(in: window))
        XCTAssertTrue(
            terminalPanel.isTextBoxActive,
            "Second Escape must not hide TextBox while another main-window control owns focus"
        )
    }

    func testTextBoxSecondEscapeHidesWhenTerminalSurfaceOwnsFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        terminalPanel.handleTextBoxEscape()
        waitFor(
            timeout: 1.0,
            until: { terminalPanel.hostedView.isSurfaceViewFirstResponder() }
        )

        XCTAssertTrue(terminalPanel.hostedView.isSurfaceViewFirstResponder())
        XCTAssertTrue(terminalPanel.consumeTextBoxHideEscapeIfArmed(in: window))
        XCTAssertFalse(terminalPanel.isTextBoxActive)
    }

    func testTextBoxSecondEscapeAfterFocusMovesToAnotherSplitClearsArmWithoutHiding() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        leftPanel.hostedView.setVisibleInUI(true)
        leftPanel.hostedView.setActive(true)
        leftPanel.hostedView.moveFocus()
        leftPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(leftPanel.toggleTextBoxInput())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })

        leftPanel.handleTextBoxEscape()
        XCTAssertTrue(leftPanel.isTextBoxActive)
#if DEBUG
        XCTAssertTrue(leftPanel.debugHasTextBoxHideEscapeArm)
#endif
        workspace.focusPanel(rightPanel.id)
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
#if DEBUG
        XCTAssertFalse(leftPanel.debugHasTextBoxHideEscapeArm)
#endif

        XCTAssertFalse(manager.consumeFocusedTerminalTextBoxHideEscapeIfArmed(in: window))
        XCTAssertTrue(
            leftPanel.isTextBoxActive,
            "Escape after moving to another split should not hide or refocus the stale split"
        )
    }

    func testTextBoxFilePanelFocusRestorerRefocusesAfterSheetEnds() {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 40, width: 320, height: 40))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textBoxScrollView.documentView = textView
        contentView.addSubview(otherView)
        contentView.addSubview(textBoxScrollView)
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = contentView
        hostWindow.makeKeyAndOrderFront(nil)
        Self.retainedTextBoxUndoWindows.append(hostWindow)
        defer { hostWindow.orderOut(nil) }

        XCTAssertTrue(hostWindow.makeFirstResponder(otherView))
        XCTAssertTrue(hostWindow.firstResponder === otherView)

        let restorer = TextBoxFilePanelFocusRestorer(textView: textView)
        restorer.install(parentWindow: hostWindow)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: hostWindow)
        waitFor(timeout: 1.0, until: { hostWindow.firstResponder === textView })

        XCTAssertTrue(hostWindow.firstResponder === textView)

        XCTAssertTrue(hostWindow.makeFirstResponder(otherView))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: hostWindow)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(hostWindow.firstResponder === otherView)
    }

    // Regression for https://github.com/manaflow-ai/cmux/issues/6380.
    // Paste must preflight into focused browser web content first, exactly like
    // copy/cut/select-all. When paste is missing from the browser document
    // editing commands, Cmd+V is never routed to the focused web view and falls
    // through to the NSWindow.performKeyEquivalent broadcast, where a terminal
    // pane's text box (text box beta) claims it instead of the browser.
    func testBrowserPasteCommandRoutesThroughWebContentFirst() {
        let pasteEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "v",
            charactersIgnoringModifiers: "v",
            keyCode: 9
        )
        XCTAssertTrue(
            shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(pasteEvent),
            "Cmd+V should preflight into focused browser web content like copy/cut/select-all"
        )
    }

    // Regression for https://github.com/manaflow-ai/cmux/issues/6380.
    // `performKeyEquivalent` is broadcast to every view in the window, not just
    // the first responder. A terminal pane's text box (text box beta) must not
    // claim Cmd+V while another view (e.g. the focused browser) owns first
    // responder, or paste lands in the text box instead of the browser.
    func testTextBoxDeclinesPasteShortcutWhenNotFirstResponder() {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 40, width: 320, height: 40))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textBoxScrollView.documentView = textView
        contentView.addSubview(otherView)
        contentView.addSubview(textBoxScrollView)
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = contentView
        hostWindow.makeKeyAndOrderFront(nil)
        Self.retainedTextBoxUndoWindows.append(hostWindow)
        Self.retainedTextBoxRestoreViews.append(textView)
        defer { hostWindow.orderOut(nil) }

        XCTAssertTrue(hostWindow.makeFirstResponder(otherView))
        XCTAssertTrue(hostWindow.firstResponder === otherView)

        let pasteEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "v",
            charactersIgnoringModifiers: "v",
            keyCode: 9
        )
        XCTAssertFalse(
            textView.performKeyEquivalent(with: pasteEvent),
            "Text box must not claim Cmd+V while another view owns first responder"
        )
    }

    // The first-responder gate must not regress normal text box paste: when the
    // text box itself owns first responder, Cmd+V is handled by the text box.
    func testTextBoxHandlesPasteShortcutWhenFirstResponder() {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textBoxScrollView.documentView = textView
        contentView.addSubview(textBoxScrollView)
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = contentView
        hostWindow.makeKeyAndOrderFront(nil)
        Self.retainedTextBoxUndoWindows.append(hostWindow)
        Self.retainedTextBoxRestoreViews.append(textView)
        defer { hostWindow.orderOut(nil) }

        XCTAssertTrue(hostWindow.makeFirstResponder(textView))
        XCTAssertTrue(hostWindow.firstResponder === textView)

        let pasteEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "v",
            charactersIgnoringModifiers: "v",
            keyCode: 9
        )
        XCTAssertTrue(
            textView.performKeyEquivalent(with: pasteEvent),
            "Text box must still handle Cmd+V while it owns first responder"
        )
    }

    // Cmd+Shift+V (paste-and-match-style) must keep its dedicated CmuxWebView
    // path and must not resolve as a plain document-editing paste.
    func testBrowserPlainTextPasteCommandIsNotADocumentEditingPaste() {
        let pasteAsPlainTextEvent = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "v",
            charactersIgnoringModifiers: "v",
            keyCode: 9
        )
        XCTAssertFalse(
            shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(pasteAsPlainTextEvent),
            "Cmd+Shift+V keeps its dedicated paste-as-plain-text path"
        )
    }

    func testFocusTextBoxShortcutRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstPanel = firstManager.selectedWorkspace?.focusedTerminalPanel,
              let secondPanel = secondManager.selectedWorkspace?.focusedTerminalPanel else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        let focusTextBoxShortcut = StoredShortcut(
            key: "a",
            command: true,
            shift: true,
            option: false,
            control: false,
            keyCode: 0
        )
        guard let event = makeKeyDownEvent(
            shortcut: focusTextBoxShortcut,
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+A event")
            return
        }

        withTemporaryShortcut(action: .focusTextBoxInput, shortcut: focusTextBoxShortcut) {
#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        XCTAssertFalse(firstPanel.isTextBoxActive, "Cmd+Shift+A must not activate TextBox in the stale active window")
        XCTAssertTrue(secondPanel.isTextBoxActive, "Cmd+Shift+A should activate TextBox in the event window")
    }

    func testTextBoxFocusIntentRestoresAfterYieldToAnotherPanel() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)

        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        XCTAssertTrue(window.firstResponder === textBoxView, "Expected TextBox focus before yielding")
        XCTAssertTrue(terminalPanel.yieldFocusIntent(.terminal(.textBoxInput), in: window))
        XCTAssertFalse(window.firstResponder === textBoxView, "Yielding to another panel must release AppKit first responder")
        XCTAssertEqual(
            terminalPanel.preferredFocusIntentForActivation(),
            .terminal(.textBoxInput),
            "Yielding TextBox focus should preserve the user's preferred left-pane input target"
        )

        XCTAssertTrue(terminalPanel.restoreFocusIntent(.terminal(.textBoxInput)))
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )
        XCTAssertTrue(window.firstResponder === textBoxView, "Returning to the panel should restore TextBox focus")
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.textBoxInput))
    }

    func testTextBoxShortcutReturnsToTextBoxAfterTerminalRegainsFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })

        XCTAssertTrue(window.makeFirstResponder(terminalView))
        terminalPanel.terminalDidBecomeFocused()
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.surface))

        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })
        XCTAssertTrue(window.firstResponder === textBoxView, "Shortcut should focus the TextBox after terminal focus is recorded")
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.textBoxInput))
    }

    func testTextBoxFocusInNonFocusedSplitUpdatesFocusedPanel() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        workspace.focusPanel(leftPanel.id)
        waitFor(
            timeout: 1.0,
            until: { workspace.focusedPanelId == leftPanel.id }
        )
        XCTAssertEqual(workspace.focusedPanelId, leftPanel.id, "Test should start with the left split focused")

        let rightTextBoxInputView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        rightTextBoxInputView.onFocusTextBox = {
            rightPanel.textBoxDidBecomeFocused()
            workspace.focusPanel(rightPanel.id, trigger: .terminalFirstResponder)
        }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = rightTextBoxInputView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }
        rightPanel.registerTextBoxInputView(rightTextBoxInputView)

        window.makeFirstResponder(rightTextBoxInputView)
        waitFor(
            timeout: 2.0,
            until: {
                return workspace.focusedPanelId == rightPanel.id &&
                    window.firstResponder === rightTextBoxInputView
            }
        )

        XCTAssertEqual(
            workspace.focusedPanelId,
            rightPanel.id,
            "Focusing a TextBox in another split must move the workspace focus to its owning panel"
        )
        XCTAssertTrue(
            window.firstResponder === rightPanel.textBoxInputView,
            "The TextBox should remain the only focused input endpoint after the split focus update"
        )
        XCTAssertEqual(rightPanel.captureFocusIntent(in: window), .terminal(.textBoxInput))
    }

    func testTextBoxPendingFocusIsCanceledOnUnfocusBeforeViewRegisters() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
#if DEBUG
        XCTAssertTrue(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif
        terminalPanel.unfocus()
#if DEBUG
        XCTAssertFalse(
            terminalPanel.debugHasPendingTextBoxFocusRequest,
            "Panel unfocus must cancel stale pending TextBox focus and file picker requests"
        )
#endif
    }

    func testTextBoxPendingFocusRunsWhenTextViewMovesToWindow() {
        let terminalPanel = TerminalPanel(workspaceId: UUID())
        defer { terminalPanel.surface.teardownSurface() }

        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
#if DEBUG
        XCTAssertTrue(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textView.onMoveToWindow = { [weak terminalPanel] view in
            terminalPanel?.textBoxInputViewDidMoveToWindow(view)
        }
        terminalPanel.registerTextBoxInputView(textView)
#if DEBUG
        XCTAssertTrue(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif

        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        hostWindow.contentView?.addSubview(textBoxScrollView)
        hostWindow.makeKeyAndOrderFront(nil)
        Self.retainedTextBoxUndoWindows.append(hostWindow)
        defer {
            textView.onMoveToWindow = { _ in }
            hostWindow.orderOut(nil)
        }
        textBoxScrollView.documentView = textView
        XCTAssertTrue(textView.window === hostWindow)

#if DEBUG
        waitFor(timeout: 1.0, until: {
            hostWindow.firstResponder === textView
                && !terminalPanel.debugHasPendingTextBoxFocusRequest
        })
#else
        waitFor(timeout: 1.0, until: { hostWindow.firstResponder === textView })
#endif
        XCTAssertTrue(hostWindow.firstResponder === textView)
#if DEBUG
        XCTAssertFalse(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif
    }

    func testTextBoxFocusShortcutReportsUnhandledWhenTerminalCannotReceiveFocus() {
        let terminalPanel = TerminalPanel(workspaceId: UUID())
        defer { terminalPanel.surface.teardownSurface() }

        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
        XCTAssertFalse(
            terminalPanel.focusTextBoxInputOrTerminal(),
            "Returning from TextBox focus to the terminal should only consume the shortcut when terminal focus succeeds"
        )
    }

    func testTextBoxSessionRestoreShowsDraftWithoutStealingFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("restore me")]
        ))

        XCTAssertTrue(terminalPanel.isTextBoxActive)
        XCTAssertEqual(terminalPanel.textBoxContent, "restore me")
        XCTAssertEqual(terminalPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
#if DEBUG
        XCTAssertFalse(
            terminalPanel.debugHasPendingTextBoxFocusRequest,
            "Visible restored TextBox drafts must not queue first-responder focus"
        )
#endif
    }

    func testTextBoxMentionCompletionDetectsFileAndSkillTokens() {
        let filePrompt = "open @Sources/TextBox"
        let fileQuery = TextBoxMentionCompletionDetector.query(
            in: filePrompt,
            selectedRange: NSRange(location: (filePrompt as NSString).length, length: 0)
        )
        XCTAssertEqual(fileQuery?.kind, .file)
        XCTAssertEqual(fileQuery?.trigger, "@")
        XCTAssertEqual(fileQuery?.query, "Sources/TextBox")
        XCTAssertEqual(fileQuery?.range, NSRange(location: 5, length: 16))

        let skillPrompt = "use /swift-guidance before editing"
        let cursor = (skillPrompt as NSString).range(of: " before").location
        let skillQuery = TextBoxMentionCompletionDetector.query(
            in: skillPrompt,
            selectedRange: NSRange(location: cursor, length: 0)
        )
        XCTAssertEqual(skillQuery?.kind, .skill)
        XCTAssertEqual(skillQuery?.trigger, "/")
        XCTAssertEqual(skillQuery?.query, "swift-guidance")
        XCTAssertEqual(skillQuery?.range, NSRange(location: 4, length: 15))

        let dollarSkillPrompt = "use $axiom-swift now"
        let dollarCursor = (dollarSkillPrompt as NSString).range(of: " now").location
        let dollarSkillQuery = TextBoxMentionCompletionDetector.query(
            in: dollarSkillPrompt,
            selectedRange: NSRange(location: dollarCursor, length: 0)
        )
        XCTAssertEqual(dollarSkillQuery?.kind, .skill)
        XCTAssertEqual(dollarSkillQuery?.trigger, "$")
        XCTAssertEqual(dollarSkillQuery?.query, "axiom-swift")
        XCTAssertEqual(dollarSkillQuery?.range, NSRange(location: 4, length: 12))

        let bareSlashPrompt = "cd /"
        let bareSlashQuery = TextBoxMentionCompletionDetector.query(
            in: bareSlashPrompt,
            selectedRange: NSRange(location: (bareSlashPrompt as NSString).length, length: 0)
        )
        XCTAssertEqual(bareSlashQuery?.kind, .skill)
        XCTAssertEqual(bareSlashQuery?.trigger, "/")
        XCTAssertEqual(bareSlashQuery?.query, "")

        let bareDollarPrompt = "echo $"
        let bareDollarQuery = TextBoxMentionCompletionDetector.query(
            in: bareDollarPrompt,
            selectedRange: NSRange(location: (bareDollarPrompt as NSString).length, length: 0)
        )
        XCTAssertEqual(bareDollarQuery?.kind, .skill)
        XCTAssertEqual(bareDollarQuery?.trigger, "$")
        XCTAssertEqual(bareDollarQuery?.query, "")

        let emailPrompt = "mail lawrence@example.com"
        XCTAssertNil(TextBoxMentionCompletionDetector.query(
            in: emailPrompt,
            selectedRange: NSRange(location: (emailPrompt as NSString).length, length: 0)
        ))
    }

    func testTextBoxMentionFileSuggestionsUseCommandPaletteSearchIndex() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-mentions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "struct TextBoxInput {}".write(
            to: sourceDirectory.appendingPathComponent("TextBoxInput.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "notes".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 13),
                query: "TextBoxInput",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        XCTAssertEqual(suggestions.first?.title, "@Sources/TextBoxInput.swift")
        XCTAssertEqual(suggestions.first?.systemImageName, "doc")
        XCTAssertTrue(suggestions.first?.insertionText.hasPrefix("[@Sources/TextBoxInput.swift](") == true)
    }

    func testTextBoxMentionFileSuggestionsRefreshCachedMisses() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-mentions-refresh-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try "old".write(
            to: root.appendingPathComponent("old-file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let oldSuggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 8),
                query: "old-file",
                trigger: "@"
            ),
            rootDirectory: root.path
        )
        XCTAssertEqual(oldSuggestions.first?.title, "@old-file.txt")

        try "new".write(
            to: root.appendingPathComponent("new-file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let newSuggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 8),
                query: "new-file",
                trigger: "@"
            ),
            rootDirectory: root.path
        )
        XCTAssertEqual(newSuggestions.first?.title, "@new-file.txt")
    }

    func testTextBoxMentionSkillSuggestionsUseTypedDollarTrigger() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-skills-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillDirectory = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("sample-dollar-skill", isDirectory: true)
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "name: sample-dollar-skill\n".write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 20),
                query: "sample-dollar",
                trigger: "$"
            ),
            rootDirectory: root.path
        )

        XCTAssertEqual(suggestions.first?.title, "$sample-dollar-skill")
        XCTAssertEqual(suggestions.first?.systemImageName, "sparkle.magnifyingglass")
        XCTAssertEqual(suggestions.first?.insertionText, "$sample-dollar-skill")
    }

    func testTextBoxMentionRefreshKeepsRowsOnSameTriggerEditButClearsOnTriggerChange() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@a"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let staleSuggestion = TextBoxMentionSuggestion(
            id: "alpha",
            title: "@alpha.txt",
            subtitle: "alpha.txt",
            insertionText: "[@alpha.txt](/tmp/alpha.txt)",
            systemImageName: "doc"
        )

        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 2), query: "a"),
            suggestions: [staleSuggestion]
        )
        XCTAssertEqual(textView.debugMentionSuggestionCount(), 1)

        textView.string = "@al"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.refreshMentionCompletions()
        XCTAssertEqual(textView.debugMentionSuggestionCount(), 1)
        XCTAssertFalse(textView.debugMentionSuggestionsAreCurrent())
        XCTAssertFalse(textView.debugAcceptMentionCompletion())
        XCTAssertFalse(textView.debugAcceptMentionCompletion(suggestion: staleSuggestion))
        XCTAssertEqual(textView.string, "@al")
        var submitCount = 0
        textView.onSubmit = { submitCount += 1 }
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(textView.string, "@al")

        textView.string = "/z"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.refreshMentionCompletions()
        XCTAssertEqual(textView.debugMentionSuggestionCount(), 0)
    }

    func testTextBoxSubmitUsesPastePayloadAndSeparateReturn() throws {
        XCTAssertEqual(TextBoxSubmit.submittedPasteText(for: "hello"), "hello")
        XCTAssertEqual(TextBoxSubmit.submittedPasteText(for: "hello\nworld"), "hello\nworld")
        XCTAssertNil(TextBoxSubmit.submittedPasteText(for: "\n"))
        XCTAssertNil(TextBoxSubmit.submittedPasteText(for: " \t\n"))
        XCTAssertEqual(TextBoxSubmit.submittedPasteText(for: " echo hi "), " echo hi ")

        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let imageSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" now"),
                .waitForVisibleText(" now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "initialCommand:/bin/zsh -lc claude --resume"
            ),
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:claude"
            )
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "initialCommand:/bin/zsh -lc 'claude --resume'"
            ),
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:claude"
            )
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text(" now")],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" now"),
                .waitForVisibleText(" now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .pasteText(" "),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:codex"
            ),
            [
                .pasteText("what is \(imageSubmissionText) now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "panelTitle:Claude Code"
            ),
            [
                .pasteText("what is \(imageSubmissionText) now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "initialCommand:echo Claude Code"
            ),
            [
                .pasteText("what is \(imageSubmissionText) now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("hello\nworld")],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [.pasteText("hello\nworld"), .namedKey("ctrl+enter")]
        )
    }

    func testTextBoxSubmitStagesClaudeImagePromptWithMultilineTail() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let imageSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: imageURL)

        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [
                    .text("how are you "),
                    .attachment(attachment),
                    .text("what does this say?\n\n3+3")
                ],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("how are you "),
                .waitForVisibleText("how are you "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" what does this say?\n\n3+3"),
                .waitForVisibleText(" what does this say?\n\n3+3"),
                .namedKey("ctrl+enter")
            ]
        )
    }

    func testTextBoxSubmitBoundsVisibleWaitForLongClaudePromptSegments() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let longPrompt = "\(String(repeating: "alpha ", count: 60))\nshort visible tail"

        let events = TextBoxSubmit.dispatchEvents(
            for: [.text(longPrompt), .attachment(attachment)],
            terminalAgentContext: "restoredAgent:claude"
        )
        let visibleWaitTexts = events.compactMap { event -> String? in
            if case .waitForVisibleText(let text) = event { return text }
            return nil
        }

        XCTAssertTrue(events.contains(.pasteText(longPrompt)))
        XCTAssertFalse(events.contains(.waitForVisibleText(longPrompt)))
        XCTAssertEqual(visibleWaitTexts.first, "short visible tail")
    }

    func testTextBoxSubmitUsesLocalPreviewPathForClaudeRemoteImage() throws {
        let previewURL = try makeTemporaryPNGFile(named: "moon.png")
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: previewURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )

        let events = TextBoxSubmit.dispatchEvents(
            for: [.text("what is "), .attachment(attachment), .text("now")],
            terminalAgentContext: "restoredAgent:claude"
        )

        XCTAssertEqual(
            events.compactMap { event -> String? in
                if case .pasteFilePath(let path) = event { return path }
                return nil
            },
            [previewURL.path]
        )
        XCTAssertTrue(events.contains(.waitForClaudeImageToken(attachment.submissionText)))
        XCTAssertFalse(events.contains(.pasteFilePath(remotePath)))
        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude",
                completionContext: TextBoxSubmit.CompletionContext(
                    confirmedClaudeImageSubmissionTexts: [
                        attachment.submissionText: 1
                    ]
                )
            ).map(\.displayName),
            ["moon.png"]
        )
    }

    func testTextBoxSubmitVisibleWaitAcceptsMultilinePromptRendering() {
        let baseline = """
        > how are you [Image #3]
        """
        let visible = """
        > how are you [Image #3] what does this say?

        3+3
        """

        XCTAssertTrue(
            TextBoxSubmit.visibleTextReady(
                expectedText: " what does this say?\n\n3+3",
                visibleText: visible,
                baseline: baseline
            )
        )
        XCTAssertFalse(
            TextBoxSubmit.visibleTextReady(
                expectedText: " what does this say?\n\n3+3",
                visibleText: baseline,
                baseline: baseline
            )
        )
    }

    func testTextBoxSubmitClipboardReadWaitStaysPendingUntilCompletionNotification() {
#if DEBUG
        let surface = FakeTextBoxSubmitSurface()
        TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
        defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }

        var completionContext: TextBoxSubmit.CompletionContext?
        TextBoxSubmit.debugRunDispatchEvents(
            [
                .captureClipboardReadBaseline,
                .waitForClipboardRead,
                .pasteText("after")
            ],
            via: surface
        ) { context in
            completionContext = context
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(surface.sentText, [])
        XCTAssertNil(completionContext)

        surface.completeClipboardRead()
        waitFor(timeout: 1.0, until: { surface.sentText == ["after"] })

        XCTAssertEqual(surface.sentText, ["after"])
        XCTAssertEqual(completionContext, TextBoxSubmit.CompletionContext.empty)
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitReportsRejectedTerminalWriteWithoutContinuing() {
#if DEBUG
        let surface = FakeTextBoxSubmitSurface()
        surface.sendTextResult = false

        var completionContext: TextBoxSubmit.CompletionContext?
        TextBoxSubmit.debugRunDispatchEvents(
            [
                .pasteText("draft"),
                .namedKey("return")
            ],
            via: surface
        ) { context in
            completionContext = context
        }

        XCTAssertEqual(surface.sentText, ["draft"])
        XCTAssertEqual(surface.sentKeys, [])
        XCTAssertEqual(completionContext?.failure, .terminalWriteRejected)
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxFailedSubmitRollbackOnlyRestoresUnchangedClearedDraft() {
        let rollbackSnapshot = TextBoxFailedSubmitRollbackSnapshot(
            revision: 4,
            text: "",
            attachmentCount: 0
        )

        XCTAssertTrue(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 4,
                text: "",
                attachmentCount: 0
            )
        ))
        XCTAssertFalse(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 4,
                text: "new draft",
                attachmentCount: 0
            )
        ))
        XCTAssertFalse(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 4,
                text: "",
                attachmentCount: 1
            )
        ))
        XCTAssertFalse(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 5,
                text: "",
                attachmentCount: 0
            )
        ))
    }

    func testTextBoxSubmitClipboardReadTimeoutRestoresPasteboard() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let surface = FakeTextBoxSubmitSurface()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(pasteboard.setString("user clipboard", forType: .string))
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 0
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }

            let imageURL = try makeTemporaryPNGFile(named: "moon.png")
            var completed = false
            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(imageURL.path),
                    .waitForClipboardRead
                ],
                via: surface
            ) { _ in
                completed = true
            }

            XCTAssertEqual(surface.sentKeys, ["paste_from_clipboard"])
            waitFor(timeout: 1.0, until: { completed })

            XCTAssertTrue(completed)
            XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        }
#else
        throw XCTSkip("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitSerializesRunsPerSurface() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let surface = FakeTextBoxSubmitSurface()
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }
            let imageURL = try makeTemporaryPNGFile(named: "moon.png")
            var completions: [String] = []

            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(imageURL.path),
                    .waitForClipboardRead,
                    .pasteText("first")
                ],
                via: surface
            ) { _ in
                completions.append("first")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [.pasteText("second")],
                via: surface
            ) { _ in
                completions.append("second")
            }

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(surface.sentText, [])
            XCTAssertEqual(completions, [])
            XCTAssertEqual(surface.sentKeys, ["paste_from_clipboard"])

            surface.completeClipboardRead()
            waitFor(timeout: 1.0, until: { completions == ["first", "second"] })

            XCTAssertEqual(surface.sentText, ["first", "second"])
            XCTAssertEqual(completions, ["first", "second"])
        }
#else
        throw XCTSkip("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitSerializesPasteboardRunsAcrossSurfaces() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let firstSurface = FakeTextBoxSubmitSurface()
            let secondSurface = FakeTextBoxSubmitSurface()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(pasteboard.setString("user clipboard", forType: .string))
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }

            let firstURL = try makeTemporaryPNGFile(named: "first.png")
            let secondURL = try makeTemporaryPNGFile(named: "second.png")
            var completions: [String] = []

            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(firstURL.path),
                    .waitForClipboardRead,
                    .pasteText("first")
                ],
                via: firstSurface
            ) { _ in
                completions.append("first")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(secondURL.path),
                    .waitForClipboardRead,
                    .pasteText("second")
                ],
                via: secondSurface
            ) { _ in
                completions.append("second")
            }

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(firstSurface.sentKeys, ["paste_from_clipboard"])
            XCTAssertEqual(secondSurface.sentKeys, [])
            XCTAssertEqual(completions, [])

            firstSurface.completeClipboardRead()
            waitFor(timeout: 1.0, until: {
                completions == ["first"] &&
                    secondSurface.sentKeys == ["paste_from_clipboard"]
            })

            XCTAssertEqual(firstSurface.sentText, ["first"])
            XCTAssertEqual(secondSurface.sentText, [])
            XCTAssertEqual(completions, ["first"])

            secondSurface.completeClipboardRead()
            waitFor(timeout: 1.0, until: { completions == ["first", "second"] })

            XCTAssertEqual(secondSurface.sentText, ["second"])
            XCTAssertEqual(completions, ["first", "second"])
            XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        }
#else
        throw XCTSkip("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitKeepsQueuedRunForStillActiveSurfaceWhenAnotherSurfaceFinishes() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let activeSurface = FakeTextBoxSubmitSurface()
            let finishingSurface = FakeTextBoxSubmitSurface()
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }
            let imageURL = try makeTemporaryPNGFile(named: "moon.png")
            var completions: [String] = []

            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(imageURL.path),
                    .waitForClipboardRead,
                    .pasteText("active-first")
                ],
                via: activeSurface
            ) { _ in
                completions.append("active-first")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [.pasteText("active-second")],
                via: activeSurface
            ) { _ in
                completions.append("active-second")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [.pasteText("finishing")],
                via: finishingSurface
            ) { _ in
                completions.append("finishing")
            }

            waitFor(timeout: 1.0, until: { completions == ["finishing"] })
            XCTAssertEqual(finishingSurface.sentText, ["finishing"])
            XCTAssertEqual(activeSurface.sentText, [])
            XCTAssertEqual(activeSurface.sentKeys, ["paste_from_clipboard"])

            activeSurface.completeClipboardRead()
            waitFor(timeout: 1.0, until: {
                completions == ["finishing", "active-first", "active-second"]
            })

            XCTAssertEqual(activeSurface.sentText, ["active-first", "active-second"])
            XCTAssertEqual(completions, ["finishing", "active-first", "active-second"])
        }
#else
        throw XCTSkip("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitStressMatrixKeepsClaudeImagesInterspersedWithText() throws {
        let firstURL = try makeTemporaryPNGFile(named: "first.png")
        let secondURL = try makeTemporaryPNGFile(named: "second.png")
        let firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        let secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )

        let cases: [(parts: [TextBoxSubmissionPart], paths: [String], submitKey: String)] = [
            (
                [.attachment(firstAttachment), .text("describe this")],
                [firstURL.path],
                "return"
            ),
            (
                [.text("compare "), .attachment(firstAttachment), .text(" and "), .attachment(secondAttachment)],
                [firstURL.path, secondURL.path],
                "return"
            ),
            (
                [.text("first line\n"), .attachment(firstAttachment), .text("second line")],
                [firstURL.path],
                "ctrl+enter"
            ),
            (
                [.attachment(firstAttachment), .attachment(secondAttachment), .text(" done")],
                [firstURL.path, secondURL.path],
                "return"
            ),
        ]

        for testCase in cases {
            let events = TextBoxSubmit.dispatchEvents(
                for: testCase.parts,
                terminalAgentContext: "restoredAgent:claude"
            )
            let pastedFilePaths = events.compactMap { event -> String? in
                if case .pasteFilePath(let path) = event {
                    return path
                }
                return nil
            }
            let imageWaitCount = events.filter { event in
                if case .waitForClaudeImageToken = event {
                    return true
                }
                return false
            }.count

            XCTAssertEqual(pastedFilePaths, testCase.paths)
            XCTAssertEqual(imageWaitCount, testCase.paths.count)
            XCTAssertEqual(events.last, .namedKey(testCase.submitKey))
        }
    }

    func testTextBoxClaudeImageSubmissionDoesNotUseCursorOffsetsForWideCharacters() throws {
        let imageURL = try makeTemporaryPNGFile(named: "wide.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let events = TextBoxSubmit.dispatchEvents(
            for: [
                .text("分析🙂 "),
                .attachment(attachment),
                .text(" これは?")
            ],
            terminalAgentContext: "restoredAgent:claude"
        )

        XCTAssertFalse(events.contains(.namedKeyRepeat(TextBoxTerminalKey.arrowLeft.rawValue, 1)))
        XCTAssertFalse(events.contains(.namedKeyRepeat(TextBoxTerminalKey.arrowRight.rawValue, 1)))
        XCTAssertEqual(
            events,
            [
                .captureVisibleTextBaseline,
                .pasteText("分析🙂 "),
                .waitForVisibleText("分析🙂 "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(attachment.submissionText),
                .captureVisibleTextBaseline,
                .pasteText(" これは?"),
                .waitForVisibleText(" これは?"),
                .namedKey(TextBoxTerminalKey.returnKey.rawValue)
            ]
        )
    }

    func testTextBoxSubmissionPreservesNonBMPUnicode() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "hello 🙂 world"

        XCTAssertEqual(textView.submissionText(), "hello 🙂 world")
    }

    func testTextBoxSubmissionPreservesInlineAttachmentOrder() throws {
        let firstURL = try makeTemporaryPNGFile(named: "moon.png")
        let secondURL = try makeTemporaryPNGFile(named: "sun.png")
        let firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        let secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )
        let firstSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        let secondSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: secondURL)

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "what is "
        textView.setSelectedRange(NSRange(location: ("what is " as NSString).length, length: 0))
        textView.insertAttachments([firstAttachment])
        textView.insertText("and ", replacementRange: textView.selectedRange())
        textView.insertAttachments([secondAttachment])

        XCTAssertEqual(
            textView.submissionText(),
            "what is \(firstSubmissionText) and \(secondSubmissionText) "
        )
        XCTAssertEqual(
            submissionPartSummaries(textView.submissionParts()),
            [
                .text("what is "),
                .attachment(firstSubmissionText),
                .text(" and "),
                .attachment(secondSubmissionText),
                .text(" ")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: textView.submissionParts(),
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(firstURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(firstSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" and "),
                .waitForVisibleText(" and "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(secondURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(secondSubmissionText),
                .pasteText(" "),
                .namedKey("return")
            ]
        )
    }

    func testTextBoxSubmissionPreservesRepeatedAttachmentsInOrder() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([attachment])
        textView.insertText("what is this ", replacementRange: textView.selectedRange())
        textView.insertAttachments([attachment])
        textView.insertText("lol", replacementRange: textView.selectedRange())

        XCTAssertEqual(
            textView.submissionText(),
            "\(TextBoxAttachment.submissionText(forLocalFileURL: imageURL)) what is this \(TextBoxAttachment.submissionText(forLocalFileURL: imageURL)) lol"
        )
    }

    func testTextBoxSessionDraftRoundTripsInterspersedImages() throws {
        let firstURL = try makeTemporaryPNGFile(named: "moon.png")
        let secondURL = try makeTemporaryPNGFile(named: "sun.png")
        let firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        let secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )

        let textView = makeRetainedTextBoxInputTextView()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello "
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        textView.insertAttachments([firstAttachment])
        textView.insertText(" middle ", replacementRange: textView.selectedRange())
        textView.insertAttachments([secondAttachment])
        textView.insertText(" done", replacementRange: textView.selectedRange())

        let draft = try XCTUnwrap(textView.sessionDraftSnapshot(isActive: true))
        let terminalSnapshot = SessionTerminalPanelSnapshot(
            workingDirectory: "/tmp",
            scrollback: nil,
            agent: nil,
            tmuxStartCommand: nil,
            textBoxDraft: draft
        )

        let data = try JSONEncoder().encode(terminalSnapshot)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        let decodedDraft = try XCTUnwrap(decoded.textBoxDraft)
        XCTAssertEqual(decodedDraft, draft)

        let restoredTextView = makeRetainedTextBoxInputTextView()
        restoredTextView.font = NSFont.systemFont(ofSize: 14)
        restoredTextView.textColor = .labelColor
        restoredTextView.installSessionDraft(decodedDraft)

        XCTAssertEqual(restoredTextView.inlineAttachments().map(\.displayName), ["moon.png", "sun.png"])
        XCTAssertEqual(
            submissionPartSummaries(restoredTextView.submissionParts()),
            submissionPartSummaries(textView.submissionParts())
        )
        XCTAssertEqual(restoredTextView.submissionText(), textView.submissionText())
    }

    func testTextBoxSessionDraftCopiesOwnedTemporaryImageToDurableStorage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL)
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertNotEqual(durableURL.path, temporaryURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertEqual(snapshot.submissionPath, durableURL.path)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forLocalFileURL: durableURL))
        XCTAssertTrue(snapshot.cleanupLocalPathWhenDisposed)

        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        let restoredAttachment = snapshot.textBoxAttachment()
        XCTAssertEqual(restoredAttachment.localURL?.standardizedFileURL.path, durableURL.path)
        XCTAssertEqual(restoredAttachment.submissionPath, durableURL.path)
    }

    func testTextBoxSessionDraftSnapshotDoesNotSynchronouslyCopyUnpreparedTemporaryImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        addTeardownBlock {
            attachment.debugCancelSessionDraftCopyForTesting()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let snapshot = SessionTextBoxInputAttachmentSnapshot(attachment)

        let durablePath = try XCTUnwrap(snapshot.localPath)
        XCTAssertNotEqual(durablePath, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionPath, durablePath)
        XCTAssertEqual(
            snapshot.submissionText,
            TextBoxAttachment.submissionText(forLocalFileURL: URL(fileURLWithPath: durablePath))
        )
        XCTAssertTrue(snapshot.cleanupLocalPathWhenDisposed)
    }

    func testTextBoxSessionDraftKeepsOwnedTemporaryImageWhenDurableCopyFails() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        try FileManager.default.removeItem(at: temporaryURL)
        let draft = try XCTUnwrap(
            TextBoxInputTextView.sessionDraftSnapshot(
                text: "",
                attachments: [attachment],
                isActive: true
            )
        )
        let snapshot = try XCTUnwrap(draft.parts.first?.attachment)

        XCTAssertEqual(draft.parts.count, 1)
        XCTAssertEqual(snapshot.localPath, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionPath, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL))
        XCTAssertTrue(snapshot.cleanupLocalPathWhenDisposed)
    }

    func testTextBoxSessionDraftPreservesRemoteSubmissionPathWhenCopyingPreviewImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertNotEqual(durableURL.path, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionPath, remotePath)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forPath: remotePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        let restoredAttachment = snapshot.textBoxAttachment()
        XCTAssertEqual(restoredAttachment.localURL?.standardizedFileURL.path, durableURL.path)
        XCTAssertEqual(restoredAttachment.submissionPath, remotePath)
        XCTAssertEqual(restoredAttachment.submissionText, TextBoxAttachment.submissionText(forPath: remotePath))
    }

    func testTextBoxDraftCopyIsRemovedWhenOriginalTemporaryAttachmentIsDisposed() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.cleanupDisposableAttachmentFiles([attachment])

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxLocalPathSubmitDropsDraftCopyButKeepsSubmittedFile() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:opencode"
            ).isEmpty
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.cleanupCopiedDraftFilesForPreservedLocalPathSubmissions([attachment])

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxDraftCopyIsRemovedWhenAttachmentPillIsDeleted() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([restoredAttachment])

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
    }

    func testTextBoxCutAttachmentPreservesClipboardFile() throws {
        try withPreservedGeneralPasteboard {
            let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
            GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
            let attachment = TextBoxAttachment(
                localURL: temporaryURL,
                submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
                cleanupLocalURLWhenDisposed: true
            )

            let snapshot = try preparedSessionAttachmentSnapshot(attachment)
            let durablePath = try XCTUnwrap(snapshot.localPath)
            let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
            addTeardownBlock {
                try? FileManager.default.removeItem(at: durableURL)
            }
            let restoredAttachment = snapshot.textBoxAttachment()

            let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
            textView.font = NSFont.systemFont(ofSize: 14)
            textView.textColor = .labelColor
            textView.insertAttachments([restoredAttachment])
            _ = textView.debugInteract(action: "select_first_attachment")

            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
            textView.cut(nil)

            XCTAssertTrue(textView.inlineAttachments().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
            XCTAssertEqual(NSPasteboard.general.string(forType: .fileURL), durableURL.absoluteString)
            XCTAssertEqual(
                NSPasteboard.general.string(forType: .string),
                TextBoxAttachment.submissionText(forLocalFileURL: durableURL)
            )
        }
    }

    func testTextBoxCutRestoredAttachmentClearsDeferredCleanup() throws {
        try withPreservedGeneralPasteboard {
            let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
            GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
            let attachment = TextBoxAttachment(
                localURL: temporaryURL,
                submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
                cleanupLocalURLWhenDisposed: true
            )

            let snapshot = try preparedSessionAttachmentSnapshot(attachment)
            let durablePath = try XCTUnwrap(snapshot.localPath)
            let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
            addTeardownBlock {
                try? FileManager.default.removeItem(at: durableURL)
                GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
            }

            let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
            textView.font = NSFont.systemFont(ofSize: 14)
            textView.textColor = .labelColor
            textView.allowsUndo = true

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
            scrollView.documentView = textView
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.makeFirstResponder(textView)
            Self.retainedTextBoxUndoWindows.append(window)

            textView.installDebugInlineFixture(snapshot.textBoxAttachment(), beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "close_first_attachment")
            XCTAssertTrue(textView.undoManager?.canUndo == true)
            textView.undoManager?.undo()
            XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

            _ = textView.debugInteract(action: "select_first_attachment")
            textView.cut(nil)

            XCTAssertTrue(textView.inlineAttachments().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
            XCTAssertEqual(NSPasteboard.general.string(forType: .fileURL), durableURL.absoluteString)

            textView.prepareForSubmit()
            textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()

            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        }
    }

    func testTextBoxRepastedDraftCopyRemainsDisposable() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let repastedAttachment = TextBoxAttachment(
            localURL: durableURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: durableURL),
            cleanupLocalURLWhenDisposed: TextBoxAttachment.shouldCleanupLocalURLWhenDisposed(durableURL)
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([repastedAttachment])

        XCTAssertTrue(TextBoxAttachment.shouldCleanupLocalURLWhenDisposed(durableURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxKeyboardDeleteAttachmentCleansDraftCopy() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([restoredAttachment])
        _ = textView.debugInteract(action: "select_first_attachment")

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxTypingOverSelectedAttachmentCleansDisposableFile() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        addTeardownBlock {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = false
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)
        textView.installDebugInlineFixture(attachment, beforeText: "hello ", afterText: " world")
        _ = textView.debugInteract(action: "select_first_attachment")

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        guard let keyEvent = makeKeyDownEvent(
            key: "x",
            modifiers: [],
            keyCode: UInt16(kVK_ANSI_X),
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct key event")
            return
        }
        textView.keyDown(with: keyEvent)

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertEqual(textView.plainText(), "hello x world")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testTextBoxKeyboardDeleteTextSelectionAfterAttachmentKeepsAttachment() {
        let attachment = TextBoxAttachment(
            displayName: "moon.png",
            submissionText: "[Image #1]",
            submissionPath: "/tmp/moon.png",
            localURL: nil
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.installDebugInlineFixture(attachment, beforeText: "hello ", afterText: " world")

        let selectionStart = ("hello " as NSString).length + 1
        textView.setSelectedRange(NSRange(location: selectionStart, length: (" world" as NSString).length))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(textView.plainText(), "hello ")
    }

    func testTextBoxUndoableDraftAttachmentDeleteDefersCleanupUntilDismantle() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(restoredAttachment, beforeText: "hello ", afterText: " world")
        _ = textView.debugInteract(action: "close_first_attachment")

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        textView.undoManager?.undo()
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            textView.submissionText(),
            expectedImageSubmission(before: "hello ", url: durableURL, after: " world")
        )
        textView.cleanupPendingUndoableAttachmentFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        _ = textView.debugInteract(action: "close_first_attachment")
        textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxPrepareForSubmitFlushesDeletedAttachmentCleanup() throws {
        let deletedTemporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        let inlineTemporaryURL = try makeTemporaryPNGFile(named: "sun.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(deletedTemporaryURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(inlineTemporaryURL)
        let deletedAttachment = TextBoxAttachment(
            localURL: deletedTemporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: deletedTemporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let inlineAttachment = TextBoxAttachment(
            localURL: inlineTemporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: inlineTemporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let deletedSnapshot = try preparedSessionAttachmentSnapshot(deletedAttachment)
        let inlineSnapshot = try preparedSessionAttachmentSnapshot(inlineAttachment)
        let deletedDurablePath = try XCTUnwrap(deletedSnapshot.localPath)
        let inlineDurablePath = try XCTUnwrap(inlineSnapshot.localPath)
        let deletedDurableURL = URL(fileURLWithPath: deletedDurablePath).standardizedFileURL
        let inlineDurableURL = URL(fileURLWithPath: inlineDurablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: deletedDurableURL)
            try? FileManager.default.removeItem(at: inlineDurableURL)
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([deletedTemporaryURL, inlineTemporaryURL])
        }

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.insertAttachments([deletedSnapshot.textBoxAttachment()])
        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletedDurableURL.path))
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.insertAttachments([inlineSnapshot.textBoxAttachment()])
        textView.prepareForSubmit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedDurableURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inlineDurableURL.path))
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["sun.png"])
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testTextBoxPrepareForSubmitDropsPendingCleanupForRestoredAttachment() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(
            snapshot.textBoxAttachment(),
            beforeText: "hello ",
            afterText: " world"
        )
        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        textView.undoManager?.undo()
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

        textView.prepareForSubmit()
        textView.clearContent(cleanupAttachmentFiles: false)
        textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxSubmitClearDefersDraftCopyCleanup() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL)
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([restoredAttachment])

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        textView.clearContent(cleanupAttachmentFiles: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(restoredAttachment)],
                terminalAgentContext: "restoredAgent:opencode"
            ).isEmpty
        )
        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(restoredAttachment)],
                terminalAgentContext: "restoredAgent:claude"
            ).isEmpty
        )
        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(restoredAttachment)],
                terminalAgentContext: "restoredAgent:claude",
                completionContext: TextBoxSubmit.CompletionContext(
                    confirmedClaudeImageSubmissionTexts: [
                        restoredAttachment.submissionText: 1
                    ]
                )
            ).map(\.displayName),
            ["moon.png"]
        )

        textView.cleanupDisposableAttachmentFiles([restoredAttachment])
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxSubmitCleanupPreservesReinsertedActiveAttachment() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(imageURL)
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL),
            cleanupLocalURLWhenDisposed: true
        )
        let textView = makeRetainedTextBoxInputTextView()
        textView.installDebugInlineFixture(
            attachment,
            beforeText: "new ",
            afterText: " prompt"
        )

        textView.cleanupDisposableAttachmentFiles([attachment])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: imageURL.path),
            "Async submit cleanup must not delete a disposable file that is active in the next prompt"
        )

        textView.clearContent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testTextBoxSubmitCleanupDisposesSynchronousRemoteAttachmentAfterEditorClears() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )
        let textView = makeRetainedTextBoxInputTextView()
        textView.installDebugInlineFixture(
            attachment,
            beforeText: "describe ",
            afterText: ""
        )

        textView.prepareForSubmit()
        textView.clearContent(cleanupAttachmentFiles: false)
        let cleanupAttachments = TextBoxSubmit.cleanupAttachmentsAfterSubmit(
            from: [.attachment(attachment)],
            terminalAgentContext: "restoredAgent:opencode"
        )
        textView.cleanupDisposableAttachmentFiles(cleanupAttachments)

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testTextBoxSubmitCleanupCanDisposeRemotePreviewImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )

        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:opencode"
            ).map(\.displayName),
            ["moon.png"]
        )
    }

    func testTextBoxSubmitCleanupKeepsClaudeImageUntilTokenIsConfirmed() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude"
            ).isEmpty
        )
        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude",
                completionContext: TextBoxSubmit.CompletionContext(
                    confirmedClaudeImageSubmissionTexts: [
                        attachment.submissionText: 1
                    ]
                )
            ).map(\.displayName),
            ["moon.png"]
        )
    }

    func testTextBoxSessionDraftRejectsInvalidPartPayloads() throws {
        let invalidTextPart = Data("""
        {
          "kind": "text",
          "attachment": {
            "displayName": "moon.png",
            "submissionText": "/tmp/moon.png",
            "submissionPath": "/tmp/moon.png",
            "localPath": "/tmp/moon.png",
            "cleanupLocalPathWhenDisposed": false
          }
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionTextBoxInputDraftPart.self, from: invalidTextPart))

        let invalidAttachmentPart = Data("""
        {
          "kind": "attachment",
          "text": "moon"
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionTextBoxInputDraftPart.self, from: invalidAttachmentPart))
    }

    func testTextBoxPasteboardRestorationSkipsAfterUserClipboardChange() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.textbox.restore.\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let fileURL = try makeTemporaryPNGFile(named: "moon.png")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        let token = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: fileURL,
            to: pasteboard
        )
        XCTAssertTrue(TextBoxPasteboardRestorationGuard.shouldRestore(pasteboard: pasteboard, token: token))

        pasteboard.clearContents()
        pasteboard.setString("new user clipboard", forType: .string)

        XCTAssertFalse(TextBoxPasteboardRestorationGuard.shouldRestore(pasteboard: pasteboard, token: token))
    }

    func testTextBoxPasteboardRestorationAllowsSameTemporaryFileAfterChangeCountAdvance() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.textbox.restore.\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let fileURL = try makeTemporaryPNGFile(named: "moon.png")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        let token = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: fileURL,
            to: pasteboard
        )
        let staleChangeCountToken = TextBoxPasteboardRestorationToken(
            changeCount: token.changeCount - 1,
            fileURL: token.fileURL
        )

        XCTAssertTrue(
            TextBoxPasteboardRestorationGuard.shouldRestore(
                pasteboard: pasteboard,
                token: staleChangeCountToken
            )
        )
    }

    func testTextBoxPasteboardRestorationRecognizesUserChangeBetweenTemporaryWrites() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.textbox.restore.\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let firstURL = try makeTemporaryPNGFile(named: "moon.png")
        let secondURL = try makeTemporaryPNGFile(named: "sun.png")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([firstURL as NSURL]))
        let firstToken = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: firstURL,
            to: pasteboard
        )
        XCTAssertTrue(
            TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
                pasteboard: pasteboard,
                token: firstToken
            )
        )

        pasteboard.clearContents()
        pasteboard.setString("new user clipboard", forType: .string)
        XCTAssertFalse(
            TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
                pasteboard: pasteboard,
                token: firstToken
            )
        )
        let userClipboardSnapshot = snapshotPasteboardItems(pasteboard)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([secondURL as NSURL]))
        let secondToken = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: secondURL,
            to: pasteboard
        )
        XCTAssertTrue(
            TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
                pasteboard: pasteboard,
                token: secondToken
            )
        )

        restorePasteboardItems(userClipboardSnapshot, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user clipboard")
    }

    func testTextBoxImageAttachmentInsertionAddsTrailingEditorSpace() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello "
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        textView.insertAttachments([attachment])

        XCTAssertEqual(textView.inlineAttachments().count, 1)
        XCTAssertTrue(textView.attributedString().string.hasSuffix(" "))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: textView.attributedString().length, length: 0))
    }

    func testTextBoxImageAttachmentInsertionDoesNotDuplicateExistingFollowingSpace() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello" as NSString).length, length: 0))
        textView.insertAttachments([attachment])

        XCTAssertEqual(
            submissionPartSummaries(textView.submissionParts()),
            [
                .text("hello "),
                .attachment(TextBoxAttachment.submissionText(forLocalFileURL: imageURL)),
                .text(" world")
            ]
        )
    }

    func testTextBoxImageAttachmentDoesNotMoveRenderedSingleLineText() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = makeRenderableTextBoxInput(width: 420, height: 30)
        let text = "hello world"
        textView.string = text
        textView.normalizeTextBaselineOffsets()
        textView.recenterSingleLineTextContainer()

        let textRange = NSRange(location: 0, length: (text as NSString).length)
        let scanRange = NSRange(location: 0, length: ("hello" as NSString).length)
        let scanRect = try renderedTextScanRect(in: textView, characterRange: scanRange)
        let beforeBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: scanRect)

        textView.setSelectedRange(NSRange(location: textRange.upperBound, length: 0))
        textView.insertAttachments([attachment])

        let afterBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: scanRect)
        assertRenderedVerticalBoundsUnchanged(beforeBounds, afterBounds, accuracy: 1)
    }

    func testTextBoxImageAttachmentDoesNotMoveRenderedMultilineText() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = makeRenderableTextBoxInput(width: 420, height: 64)
        let firstLine = "hello world"
        let secondLine = "second line"
        let text = "\(firstLine)\n\(secondLine)"
        textView.string = text
        textView.normalizeTextBaselineOffsets()
        textView.recenterSingleLineTextContainer()

        let firstLineRange = NSRange(location: 0, length: (firstLine as NSString).length)
        let firstScanRange = NSRange(location: 0, length: ("hello" as NSString).length)
        let secondScanRange = NSRange(
            location: firstLineRange.upperBound + 1,
            length: ("second" as NSString).length
        )
        let firstScanRect = try renderedTextScanRect(in: textView, characterRange: firstScanRange)
        let secondScanRect = try renderedTextScanRect(in: textView, characterRange: secondScanRange)
        let beforeFirstBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: firstScanRect)
        let beforeSecondBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: secondScanRect)

        textView.setSelectedRange(NSRange(location: firstLineRange.upperBound, length: 0))
        textView.insertAttachments([attachment])

        let afterFirstBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: firstScanRect)
        let afterSecondBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: secondScanRect)
        assertRenderedVerticalBoundsUnchanged(beforeFirstBounds, afterFirstBounds, accuracy: 1)
        assertRenderedVerticalBoundsUnchanged(beforeSecondBounds, afterSecondBounds, accuracy: 1)
    }

    func testTextBoxInlineAttachmentPixelsDoNotSitAboveTextPixelsWithoutChangingTextBaseline() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = makeRenderableTextBoxInput(width: 420, height: 30)
        let text = "hello world"
        textView.string = text
        textView.normalizeTextBaselineOffsets()
        textView.recenterSingleLineTextContainer()

        let textRange = NSRange(location: 0, length: (text as NSString).length)

        textView.setSelectedRange(NSRange(location: textRange.upperBound, length: 0))
        textView.insertAttachments([attachment])

        let textPixelBounds = try renderedNonBackgroundPixelBounds(
            in: textView,
            scanRect: renderedTextScanRect(
                in: textView,
                characterRange: NSRange(location: 0, length: ("hello" as NSString).length)
            )
        )
        let attachmentPixelBounds = try renderedNonBackgroundPixelBounds(
            in: textView,
            scanRect: try visibleAttachmentCellFrame(in: textView).insetBy(dx: -2, dy: -10)
        )

        XCTAssertEqual(baselineOffsetsForTextRuns(in: textView), [0])
        XCTAssertGreaterThanOrEqual(
            attachmentPixelBounds.midY,
            textPixelBounds.midY,
            "Inline image pills should not sit above adjacent text or move the text baseline."
        )
        XCTAssertLessThan(
            attachmentPixelBounds.midY - textPixelBounds.midY,
            8,
            "Inline image pills should not be pushed so low that they look detached from text."
        )
    }

    func testTextBoxInlineAttachmentVerticalPaddingIsBalancedAcrossLineStates() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let pillOnly = makeRenderableTextBoxInput(width: 420, height: 30)
        pillOnly.insertAttachments([attachment])
        let pillOnlyCell = try visibleAttachmentCellFrame(in: pillOnly)
        let pillOnlyPixels = try renderedNonBackgroundPixelBounds(
            in: pillOnly,
            scanRect: pillOnlyCell.insetBy(dx: -2, dy: -12)
        )

        let inline = makeRenderableTextBoxInput(width: 420, height: 30)
        inline.string = "hello "
        inline.normalizeTextBaselineOffsets()
        inline.recenterSingleLineTextContainer()
        inline.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        inline.insertAttachments([attachment])
        inline.insertText(" world", replacementRange: inline.selectedRange())
        let inlineCell = try visibleAttachmentCellFrame(in: inline)
        let inlinePillPixels = try renderedNonBackgroundPixelBounds(
            in: inline,
            scanRect: inlineCell.insetBy(dx: -2, dy: -12)
        )
        let inlineTextPixels = try renderedNonBackgroundPixelBounds(
            in: inline,
            scanRect: renderedTextScanRect(
                in: inline,
                characterRange: NSRange(location: 0, length: ("hello" as NSString).length)
            )
        )

        let multiline = makeRenderableTextBoxInput(width: 420, height: 64)
        let multilinePrefix = "x\n          "
        multiline.string = multilinePrefix
        multiline.normalizeTextBaselineOffsets()
        multiline.recenterSingleLineTextContainer()
        multiline.setSelectedRange(NSRange(location: (multilinePrefix as NSString).length, length: 0))
        multiline.insertAttachments([attachment])
        multiline.insertText(" world", replacementRange: multiline.selectedRange())
        let multilineCell = try visibleAttachmentCellFrame(in: multiline)
        let multilinePillPixels = try renderedNonBackgroundPixelBounds(
            in: multiline,
            scanRect: multilineCell.insetBy(dx: -2, dy: -12)
        )
        XCTAssertLessThanOrEqual(
            pillOnlyPixels.verticalPaddingDelta,
            2,
            "Pill-only TextBox padding should stay visually centered. Got \(pillOnlyPixels.debugDescription())."
        )
        XCTAssertLessThanOrEqual(
            inlinePillPixels.verticalPaddingDelta,
            1,
            "Inline pill padding should stay centered inside the single-line TextBox. Got \(inlinePillPixels.debugDescription())."
        )
        XCTAssertLessThanOrEqual(
            multilinePillPixels.verticalPaddingDelta,
            1,
            "Multiline pill padding should stay centered in the expanded TextBox. Got \(multilinePillPixels.debugDescription())."
        )
        XCTAssertEqual(baselineOffsetsForTextRuns(in: inline), [0])
        XCTAssertEqual(baselineOffsetsForTextRuns(in: multiline), [0])
        XCTAssertGreaterThan(
            inlinePillPixels.midY,
            inlineTextPixels.midY,
            "The inline pill should remain slightly lower than adjacent text."
        )
    }

    func testTextBoxArrowMovementUsesComposedCharacters() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "a🙂b"
        textView.setSelectedRange(NSRange(location: ("a🙂" as NSString).length, length: 0))

        guard let leftEvent = makeKeyDownEvent(
            key: "",
            modifiers: [],
            keyCode: UInt16(kVK_LeftArrow),
            windowNumber: 0
        ), let rightEvent = makeKeyDownEvent(
            key: "",
            modifiers: [],
            keyCode: UInt16(kVK_RightArrow),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct arrow events")
            return
        }

        textView.keyDown(with: leftEvent)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: ("a" as NSString).length, length: 0))

        textView.keyDown(with: rightEvent)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: ("a🙂" as NSString).length, length: 0))
    }

    func testTextBoxPlainArrowsDeferDuringIMEComposition() {
        XCTAssertFalse(shouldHandleTextBoxPlainArrowLocally(
            keyCode: UInt16(kVK_LeftArrow),
            firstResponderHasMarkedText: true,
            flags: []
        ))
        XCTAssertTrue(shouldHandleTextBoxPlainArrowLocally(
            keyCode: UInt16(kVK_LeftArrow),
            firstResponderHasMarkedText: false,
            flags: []
        ))
        XCTAssertFalse(shouldHandleTextBoxPlainArrowLocally(
            keyCode: UInt16(kVK_LeftArrow),
            firstResponderHasMarkedText: false,
            flags: [.command]
        ))
    }

    func testTextBoxReturnDoesNotSubmitWhileIMEHasMarkedText() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 0, "Return should let the input method commit marked text")

        textView.unmarkText()
        textView.string = "かな"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 1, "Return should submit after marked text is committed")
    }

    func testTextBoxReturnDoesNotSubmitWhileAttachmentUploadPending() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        XCTAssertTrue(textView.hasPendingAttachmentUploadPlaceholder())

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 0)

        XCTAssertTrue(textView.removePendingAttachmentUploadPlaceholder(id: uploadID))
        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 1)
    }

    func testTextBoxReturnDoesNotSubmitEmptyContent() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 0)

        textView.string = "  \n\t  "
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 0)

        textView.string = "hello"
        textView.setSelectedRange(NSRange(location: ("hello" as NSString).length, length: 0))
        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 1)
    }

    func testTextBoxEscapeDoesNotLeaveIMEComposition() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var escapeCount = 0
        textView.onEscape = {
            escapeCount += 1
        }

        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: UInt16(kVK_Escape),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

        textView.keyDown(with: escapeEvent)
        XCTAssertEqual(escapeCount, 0, "Escape should stay inside active IME composition")

        textView.unmarkText()
        textView.keyDown(with: escapeEvent)
        XCTAssertEqual(escapeCount, 1, "Escape should leave TextBox only after IME composition is gone")
    }

    func testTextBoxMentionCompletionDoesNotConsumeIMECommands() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@a"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 2), query: "a"),
            suggestions: [
                TextBoxMentionSuggestion(
                    id: "alpha",
                    title: "@alpha.txt",
                    subtitle: "alpha.txt",
                    insertionText: "[@alpha.txt](/tmp/alpha.txt)",
                    systemImageName: "doc"
                )
            ]
        )

        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }
        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 0)
        XCTAssertFalse(textView.submissionText().contains("alpha.txt"))

        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 0)
        XCTAssertFalse(textView.submissionText().contains("alpha.txt"))
    }

    func testTextBoxShiftReturnInsertsNewlineWhenMentionCompletionOpen() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@a"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 2), query: "a"),
            suggestions: [
                TextBoxMentionSuggestion(
                    id: "alpha",
                    title: "@alpha.txt",
                    subtitle: "alpha.txt",
                    insertionText: "[@alpha.txt](/tmp/alpha.txt)",
                    systemImageName: "doc"
                )
            ]
        )

        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        guard let shiftReturnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: .shift,
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Shift-Return event")
            return
        }

        textView.keyDown(with: shiftReturnEvent)

        XCTAssertEqual(submitCount, 0)
        XCTAssertEqual(textView.attributedString().string, "@a\n")
        XCTAssertFalse(textView.submissionText().contains("alpha.txt"))
    }

    func testFocusedTextBoxFirstEscapeBypassesTerminalFindShortcutHandling() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected a main window with a focused terminal")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })
        XCTAssertTrue(window.firstResponder === textBoxView)

        terminalPanel.searchState = TerminalSurface.SearchState(needle: "")
        defer { terminalPanel.searchState = nil }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: UInt16(kVK_Escape),
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            cmuxCloseFocusedTerminalFindForEscape(event: escapeEvent, appDelegate: appDelegate),
            "The app-level find escape preflight must not close find while TextBox owns focus"
        )
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertNotNil(terminalPanel.searchState, "First Escape should reach the TextBox instead of closing find")
    }

    func testTextBoxFocusedAttachmentCopyCutPasteUseFilePasteboard() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let replacementURL = try makeTemporaryPNGFile(named: "sun.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: originalURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.onPaste = { pasteboard, textView in
            switch TerminalImageTransferPlanner.prepare(pasteboard: pasteboard, mode: .paste) {
            case .fileURLs(let fileURLs):
                textView.insertAttachments(
                    fileURLs.map {
                        TextBoxAttachment(
                            localURL: $0,
                            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0)
                        )
                    }
                )
                return true
            case .insertText(let text):
                textView.insertText(text, replacementRange: textView.selectedRange())
                return true
            case .reject:
                return false
            }
        }

        guard let copyEvent = makeKeyDownEvent(
            key: "c",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_C),
            windowNumber: 0
        ), let cutEvent = makeKeyDownEvent(
            key: "x",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_X),
            windowNumber: 0
        ), let pasteEvent = makeKeyDownEvent(
            key: "v",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_V),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct edit command events")
            return
        }

        try withPreservedGeneralPasteboard {
            textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "select_first_attachment")

            XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 1))
            XCTAssertTrue(textView.performKeyEquivalent(with: copyEvent))
            XCTAssertEqual(PasteboardFileURLReader.fileURLs(from: .general).map(\.path), [originalURL.path])
            XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

            XCTAssertTrue(textView.performKeyEquivalent(with: cutEvent))
            XCTAssertEqual(PasteboardFileURLReader.fileURLs(from: .general).map(\.path), [originalURL.path])
            XCTAssertTrue(textView.inlineAttachments().isEmpty)

            textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "select_first_attachment")
            writeFileURLs([replacementURL], to: .general)

            XCTAssertTrue(textView.performKeyEquivalent(with: pasteEvent))
            XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["sun.png"])
            XCTAssertEqual(
                textView.submissionText(),
                expectedImageSubmission(before: "hello ", url: replacementURL, after: " world")
            )
        }
    }

    func testTextBoxFocusedAttachmentCopyFollowsSelectionAfterSelectionChanges() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        guard let copyEvent = makeKeyDownEvent(
            key: "c",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_C),
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct copy event")
            return
        }

        try withPreservedGeneralPasteboard {
            textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "select_first_attachment")
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 1))

            textView.setSelectedRange(NSRange(location: 0, length: 5))
            textView.refreshInlineAttachmentFocus()
            NSPasteboard.general.clearContents()

            XCTAssertTrue(textView.performKeyEquivalent(with: copyEvent))
            XCTAssertTrue(PasteboardFileURLReader.fileURLs(from: .general).isEmpty)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")
        }
    }

    func testTextBoxFocusedAttachmentClearsWhenTextBoxLosesFocus() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 32, width: 24, height: 24))
        contentView.addSubview(scrollView)
        contentView.addSubview(otherView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
        let focusedState = textView.debugInteract(action: "select_first_attachment")
        XCTAssertEqual(focusedState["focused_attachment_index"] as? Int, 6)

        XCTAssertTrue(window.makeFirstResponder(otherView))
        let unfocusedState = textView.debugInteractionState()
        XCTAssertEqual(unfocusedState["focused_attachment_index"] as? Int, -1)
    }

    func testTextBoxInlineAttachmentsSurviveViewRemount() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let originalTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        originalTextView.font = NSFont.systemFont(ofSize: 14)
        originalTextView.textColor = .labelColor
        originalTextView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)

        let remountedTextView = makeRetainedTextBoxInputTextView()
        terminalPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertEqual(remountedTextView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            remountedTextView.submissionText(),
            expectedImageSubmission(before: "hello ", url: originalURL, after: " world")
        )
    }

    func testTerminalPanelPreservesTextBoxDraftForUnmountWithoutPublishing() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: panelId))
        let originalTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        originalTextView.string = "preserve this"

        var objectWillChangeCount = 0
        let cancellable = terminalPanel.objectWillChange.sink {
            objectWillChangeCount += 1
        }

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)

        let draft = try XCTUnwrap(terminalPanel.sessionTextBoxDraftSnapshot())
        XCTAssertEqual(textBoxSessionDraftPartSummaries(draft.parts), [.text("preserve this")])
        XCTAssertEqual(
            objectWillChangeCount,
            0,
            "TextBox unmount preservation runs from NSViewRepresentable.dismantleNSView and must not publish during SwiftUI teardown"
        )
        withExtendedLifetime(cancellable) {}
    }

    func testTerminalPanelCloseDisposesTextBoxAttachmentDrafts() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: durableURL)
        }

        let textView = makeRetainedTextBoxInputTextView()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.installDebugInlineFixture(attachment, beforeText: "close ", afterText: " draft")
        terminalPanel.registerTextBoxInputView(textView)
        terminalPanel.isTextBoxActive = true

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        terminalPanel.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertNil(terminalPanel.sessionTextBoxDraftSnapshot())
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
    }

    func testWorkspaceSessionRestoreRestoresActiveTextBoxDraftWithImage() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: originalURL)
        )
        let originalTextView = makeRetainedTextBoxInputTextView()
        originalTextView.font = NSFont.systemFont(ofSize: 14)
        originalTextView.textColor = .labelColor
        originalTextView.installDebugInlineFixture(originalAttachment, beforeText: "restore ", afterText: " now")

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)
        terminalPanel.isTextBoxActive = true

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(panelSnapshot.terminal?.textBoxDraft?.isActive, true)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restoredWorkspace.terminalPanel(for: restoredPanelId))
        XCTAssertTrue(restoredPanel.isTextBoxActive)

        let remountedTextView = makeRetainedTextBoxInputTextView()
        remountedTextView.font = NSFont.systemFont(ofSize: 14)
        remountedTextView.textColor = .labelColor
        restoredPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertEqual(remountedTextView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            remountedTextView.submissionText(),
            expectedImageSubmission(before: "restore ", url: originalURL, after: " now")
        )
    }

    func testWorkspaceSessionRestoreKeepsHiddenTextBoxDraftUntilOpened() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: originalURL)
        )
        let originalTextView = makeRetainedTextBoxInputTextView()
        originalTextView.font = NSFont.systemFont(ofSize: 14)
        originalTextView.textColor = .labelColor
        originalTextView.installDebugInlineFixture(originalAttachment, beforeText: "hidden ", afterText: " draft")

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)
        terminalPanel.isTextBoxActive = false

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(panelSnapshot.terminal?.textBoxDraft?.isActive, false)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restoredWorkspace.terminalPanel(for: restoredPanelId))
        XCTAssertFalse(restoredPanel.isTextBoxActive)

        XCTAssertTrue(restoredPanel.focusTextBoxInputOrTerminal())
        let remountedTextView = makeRetainedTextBoxInputTextView()
        remountedTextView.font = NSFont.systemFont(ofSize: 14)
        remountedTextView.textColor = .labelColor
        restoredPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertEqual(remountedTextView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            remountedTextView.submissionText(),
            expectedImageSubmission(before: "hidden ", url: originalURL, after: " draft")
        )
    }

    func testWorkspaceSessionRestoreRestoresTextBoxDraftsAcrossSplits() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let firstPanel = try XCTUnwrap(workspace.terminalPanel(for: firstPanelId))
        let secondPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: firstPanelId,
            orientation: .horizontal,
            focus: false
        ))

        try installTextBoxSessionDraft(
            on: firstPanel,
            imageName: "left.png",
            beforeText: "left split ",
            afterText: " draft",
            isActive: true
        )
        try installTextBoxSessionDraft(
            on: secondPanel,
            imageName: "right.png",
            beforeText: "right split ",
            afterText: " draft",
            isActive: false
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.panels.compactMap { $0.terminal?.textBoxDraft }.count, 2)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        let restoredDrafts = restoredTextBoxDraftSummaries(in: restoredWorkspace)
        XCTAssertEqual(Set(restoredDrafts), Set([
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("left split "), .attachment("left.png"), .text(" draft")]),
            TextBoxSessionDraftSummary(isActive: false, parts: [.text("right split "), .attachment("right.png"), .text(" draft")])
        ]))
    }

    func testTabManagerSessionRestoreRestoresTextBoxDraftsAcrossWorkspaces() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let firstWorkspace = try XCTUnwrap(manager.tabs.first)
        let secondWorkspace = manager.addWorkspace(
            title: "Second",
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false
        )

        try installTextBoxSessionDraft(
            on: XCTUnwrap(firstWorkspace.focusedTerminalPanel),
            imageName: "first-workspace.png",
            beforeText: "first workspace ",
            afterText: " draft",
            isActive: true
        )
        try installTextBoxSessionDraft(
            on: XCTUnwrap(secondWorkspace.focusedTerminalPanel),
            imageName: "second-workspace.png",
            beforeText: "second workspace ",
            afterText: " draft",
            isActive: false
        )

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restoredManager = TabManager(autoWelcomeIfNeeded: false)
        restoredManager.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restoredManager.tabs.count, 2)
        XCTAssertEqual(restoredManager.selectedTabId, restoredManager.tabs.last?.id)
        XCTAssertEqual(Set(restoredManager.tabs.flatMap(restoredTextBoxDraftSummaries(in:))), Set([
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("first workspace "), .attachment("first-workspace.png"), .text(" draft")]),
            TextBoxSessionDraftSummary(isActive: false, parts: [.text("second workspace "), .attachment("second-workspace.png"), .text(" draft")])
        ]))
    }

    func testAppSessionSnapshotRoundTripsTextBoxDraftsAcrossWindows() throws {
        let firstManager = TabManager(autoWelcomeIfNeeded: false)
        let secondManager = TabManager(autoWelcomeIfNeeded: false)

        try installTextBoxSessionDraft(
            on: XCTUnwrap(firstManager.selectedWorkspace?.focusedTerminalPanel),
            imageName: "first-window.png",
            beforeText: "first window ",
            afterText: " draft",
            isActive: true
        )
        try installTextBoxSessionDraft(
            on: XCTUnwrap(secondManager.selectedWorkspace?.focusedTerminalPanel),
            imageName: "second-window.png",
            beforeText: "second window ",
            afterText: " draft",
            isActive: true
        )

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_700_000_000,
            windows: [
                sessionWindowSnapshot(tabManager: firstManager),
                sessionWindowSnapshot(tabManager: secondManager)
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.windows.count, 2)

        let restoredFirstManager = TabManager(autoWelcomeIfNeeded: false)
        let restoredSecondManager = TabManager(autoWelcomeIfNeeded: false)
        restoredFirstManager.restoreSessionSnapshot(decoded.windows[0].tabManager)
        restoredSecondManager.restoreSessionSnapshot(decoded.windows[1].tabManager)

        let restoredDrafts = Set(
            restoredFirstManager.tabs.flatMap(restoredTextBoxDraftSummaries(in:)) +
            restoredSecondManager.tabs.flatMap(restoredTextBoxDraftSummaries(in:))
        )

        XCTAssertEqual(restoredDrafts, Set([
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("first window "), .attachment("first-window.png"), .text(" draft")]),
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("second window "), .attachment("second-window.png"), .text(" draft")])
        ]))
    }

    func testTextBoxPendingAttachmentUploadIsStrippedWhenPreservedForRemount() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = originalTextView
        let textBoxWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        textBoxWindow.isReleasedWhenClosed = false
        textBoxWindow.contentView = scrollView
        textBoxWindow.makeFirstResponder(originalTextView)
        Self.retainedTextBoxUndoWindows.append(textBoxWindow)

        originalTextView.string = "hello world"
        originalTextView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))

        let uploadID = UUID()
        originalTextView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        let uploadToken = originalTextView.pendingAttachmentUploadValidationToken()
        XCTAssertTrue(originalTextView.hasPendingAttachmentUploadPlaceholder())
        XCTAssertTrue(originalTextView.canAcceptPendingAttachmentUpload(validationToken: uploadToken))

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)

        XCTAssertFalse(originalTextView.canAcceptPendingAttachmentUpload(validationToken: uploadToken))

        let remountedTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        terminalPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertFalse(remountedTextView.hasPendingAttachmentUploadPlaceholder())
        XCTAssertEqual(remountedTextView.submissionText(), "hello world")
    }

    func testTextBoxRepresentableDismantleDoesNotWriteSwiftUIBindings() {
        var text = "old"
        var attachments: [TextBoxAttachment] = []
        var height: CGFloat = 24
        var hasPendingAttachmentUpload = true
        var textWriteCount = 0
        var attachmentWriteCount = 0
        var heightWriteCount = 0
        var pendingWriteCount = 0
        var dismantledText: String?

        let inputView = TextBoxInputView(
            text: Binding(
                get: { text },
                set: { newValue in
                    textWriteCount += 1
                    text = newValue
                }
            ),
            attachments: Binding(
                get: { attachments },
                set: { newValue in
                    attachmentWriteCount += 1
                    attachments = newValue
                }
            ),
            textViewHeight: Binding(
                get: { height },
                set: { newValue in
                    heightWriteCount += 1
                    height = newValue
                }
            ),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { newValue in
                    pendingWriteCount += 1
                    hasPendingAttachmentUpload = newValue
                }
            ),
            font: NSFont.systemFont(ofSize: 14),
            backgroundColor: .textBackgroundColor,
            foregroundColor: .labelColor,
            terminalTitle: "codex",
            completionRootDirectory: nil,
            onSubmit: {},
            onEscape: {},
            onFocusTextBox: {},
            onToggleFocus: {},
            onForwardText: { _, _ in },
            onForwardKey: { _ in },
            onForwardControl: { _ in },
            onPaste: { _, _ in false },
            onInsertFileURLs: { _, _ in false },
            onChooseFiles: {},
            onContentChanged: {},
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { textView in
                dismantledText = textView.plainText()
            }
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "preserve this"
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView

        TextBoxInputView.dismantleNSView(
            scrollView,
            coordinator: TextBoxInputView.Coordinator(parent: inputView)
        )

        XCTAssertEqual(dismantledText, "preserve this")
        XCTAssertEqual(textWriteCount, 0)
        XCTAssertEqual(attachmentWriteCount, 0)
        XCTAssertEqual(heightWriteCount, 0)
        XCTAssertEqual(pendingWriteCount, 0)
    }

    func testTextBoxPendingAttachmentUploadPreservesOriginalInsertionPoint() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forPath: "/tmp/remote/moon.png"),
            submissionPath: "/tmp/remote/moon.png"
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))

        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        XCTAssertEqual(textView.plainText(), "hello world")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("say ", replacementRange: textView.selectedRange())

        XCTAssertTrue(textView.replacePendingAttachmentUploadPlaceholder(id: uploadID, with: [originalAttachment]))
        XCTAssertEqual(
            textView.submissionText(),
            "say hello /tmp/remote/moon.png world"
        )
    }

    func testTextBoxPendingAttachmentUploadQueuesDurableDraftCopyForOwnedTemporaryImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let remotePath = "/tmp/remote/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )
        addTeardownBlock {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)

        XCTAssertTrue(textView.replacePendingAttachmentUploadPlaceholder(id: uploadID, with: [attachment]))
        TextBoxInputTextView.flushPendingSessionDraftAttachmentCopies()

        let draft = try XCTUnwrap(textView.sessionDraftSnapshot(isActive: true))
        let snapshot = try XCTUnwrap(draft.parts.first?.attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])

        XCTAssertNotEqual(durableURL.path, temporaryURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertEqual(snapshot.submissionPath, remotePath)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forPath: remotePath))
    }

    func testTextBoxPendingAttachmentUploadRemovalCleansPlaceholder() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))

        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        XCTAssertTrue(textView.hasPendingAttachmentUploadPlaceholder())

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("say ", replacementRange: textView.selectedRange())

        XCTAssertTrue(textView.removePendingAttachmentUploadPlaceholder(id: uploadID))
        XCTAssertFalse(textView.hasPendingAttachmentUploadPlaceholder())
        XCTAssertEqual(textView.plainText(), "say hello world")
        XCTAssertEqual(textView.submissionText(), "say hello world")
    }

    func testTextBoxAttachmentCloseIsUndoable() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            textView.submissionText(),
            expectedImageSubmission(before: "hello ", url: originalURL, after: " world")
        )
    }

    func testTextBoxPendingAttachmentUploadInvalidatesOnClear() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        let token = textView.pendingAttachmentUploadValidationToken()
        XCTAssertTrue(textView.canAcceptPendingAttachmentUpload(validationToken: token))

        textView.clearContent()

        XCTAssertFalse(textView.canAcceptPendingAttachmentUpload(validationToken: token))
    }

    func testTerminalFirstResponderGuardBlocksMoveFocusWhenRightSidebarOwnsKeyboardFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let strayView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        contentView.addSubview(strayView)
        defer { strayView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)

        XCTAssertTrue(window.makeFirstResponder(strayView), "Expected a foreign responder before blocking terminal focus")
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .feed, in: window)

        XCTAssertFalse(
            window.makeFirstResponder(terminalView),
            "Coordinator-owned sidebar focus should block direct terminal first-responder requests"
        )

        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(window.firstResponder === strayView, "Blocked terminal moveFocus should keep the existing responder intact")
        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Blocked terminal moveFocus must not leave the Ghostty surface as first responder"
        )
    }

    func testFindShortcutFromFileTreeOpensRightSidebarFind() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let sidebarResponder = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        attachTestResponder(sidebarResponder, to: window)
        defer { sidebarResponder.removeFromSuperview() }

        XCTAssertTrue(window.makeFirstResponder(sidebarResponder), "Expected right sidebar responder to take focus")
        appDelegate.fileExplorerState?.mode = .files
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .files, in: window)

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertNil(terminalPanel.searchState, "Cmd+F from the file tree should not create terminal search state")
        XCTAssertEqual(appDelegate.fileExplorerState?.mode, .find)
    }

    func testFindShortcutFromTerminalOpensTerminalFind() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        waitUntil(timeout: 1.0) {
            terminalPanel.hostedView.isSurfaceViewFirstResponder()
        }
        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before Cmd+F"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        appDelegate.noteTerminalKeyboardFocusIntent(workspaceId: workspace.id, panelId: terminalPanel.id, in: window)

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        waitUntil(timeout: 1.0) {
            terminalPanel.searchState != nil
        }
        XCTAssertNotNil(terminalPanel.searchState, "Cmd+F from terminal focus should create terminal search state")
    }

    func testFindShortcutFromOtherRightSidebarModeDoesNotStealFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let sidebarResponder = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        attachTestResponder(sidebarResponder, to: window)
        defer { sidebarResponder.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let nonFileMode = RightSidebarMode.sessions
        XCTAssertTrue(window.makeFirstResponder(sidebarResponder), "Expected right sidebar responder to take focus")
#if DEBUG
        let revealResult = appDelegate.debugRevealRightSidebarInActiveMainWindow(
            mode: nonFileMode,
            focusFirstItem: false,
            preferredWindow: window
        )
        XCTAssertTrue(revealResult.stateFound, "Expected registered right sidebar state")
        XCTAssertEqual(revealResult.activeMode, nonFileMode.rawValue)
        XCTAssertTrue(window.makeFirstResponder(sidebarResponder), "Expected sidebar responder to retake focus")
#else
        appDelegate.fileExplorerState?.mode = nonFileMode
#endif
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: nonFileMode, in: window)
        XCTAssertFalse(
            appDelegate.allowsTerminalKeyboardFocus(
                workspaceId: workspace.id,
                panelId: terminalPanel.id,
                in: window
            ),
            "Right sidebar ownership should block direct terminal focus before Cmd+F"
        )

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        withTemporaryShortcut(action: .switchRightSidebarToFiles, shortcut: .unbound) {
            withTemporaryShortcut(action: .switchRightSidebarToFind, shortcut: .unbound) {
                XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
            }
        }
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertFalse(
            appDelegate.allowsTerminalKeyboardFocus(
                workspaceId: workspace.id,
                panelId: terminalPanel.id,
                in: window
            ),
            "Cmd+F should keep keyboard ownership in the existing right sidebar section"
        )
        XCTAssertNil(terminalPanel.searchState, "Cmd+F should not create terminal search state")
        XCTAssertEqual(appDelegate.fileExplorerState?.mode, nonFileMode)
        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Cmd+F from a non-file right sidebar mode should not refocus the terminal responder"
        )
    }

    func testWindowSendEventRepairsFocusedTerminalSearchTypingAfterResponderDrift() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        focusHostedTerminalForRepairTesting(window: window, hostedView: terminalPanel.hostedView)

        let searchState = TerminalSurface.SearchState(needle: "")
        terminalPanel.surface.searchState = searchState
        terminalPanel.hostedView.setSearchOverlay(searchState: searchState)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let searchField = findEditableTextField(in: terminalPanel.hostedView) else {
            XCTFail("Expected mounted terminal search field")
            return
        }

        searchField.selectText(nil)
        _ = window.makeFirstResponder(searchField)
        waitUntil(timeout: 1.0) {
            firstResponderOwnsTextField(window.firstResponder, textField: searchField)
        }
        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Expected terminal search field to own first responder before drift"
        )

        let strayView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        installSearchResponderDriftForTesting(
            strayView,
            in: window,
            hostedView: terminalPanel.hostedView,
            searchField: searchField
        )
        defer { strayView.removeFromSuperview() }

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

#if DEBUG
        appDelegate.debugSetShortcutRoutingKeyRepairFirstResponderForTesting(strayView)
        defer { appDelegate.debugSetShortcutRoutingKeyRepairFirstResponderForTesting(nil) }

        var repairCount = 0
        var repairResponder: NSResponder?
        let previousRepairObserver = appDelegate.debugFocusedTerminalKeyRepairObserverForTesting
        appDelegate.debugFocusedTerminalKeyRepairObserverForTesting = { window, event, responder in
            previousRepairObserver?(window, event, responder)
            guard event.keyCode == 0 else { return }
            repairCount += 1
            repairResponder = responder
        }
        defer { appDelegate.debugFocusedTerminalKeyRepairObserverForTesting = previousRepairObserver }
#else
        throw XCTSkip("DEBUG-only simulated responder override is required for deterministic key-repair coverage")
#endif

        window.sendEvent(keyDown)
        waitUntil(timeout: 1.0) {
            firstResponderOwnsTextField(window.firstResponder, textField: searchField)
                && searchField.stringValue == "a"
        }

        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Typing should repair focus back to the terminal search field"
        )
        XCTAssertEqual(searchField.stringValue, "a", "Typing repair should preserve the first key in the search field")
#if DEBUG
        XCTAssertEqual(repairCount, 1, "window.sendEvent should run the focused terminal search repair path")
        XCTAssertTrue(repairResponder === strayView, "Repair should evaluate the simulated wrong same-window responder")
#endif
    }

    private func makeRegisteredShortcutRoutingWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    private func closeRegisteredShortcutRoutingWindow(_ window: NSWindow, id: UUID) {
        AppDelegate.shared?.unregisterMainWindowContextForTesting(windowId: id)
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func assertCloseShortcutTargetsFocusedWindowWhenEventWindowMetadataIsStale(
        actionName: String,
        modifiers: NSEvent.ModifierFlags,
        expectedAction: KeyboardShortcutSettings.Action,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return
        }

        let defaults = UserDefaults.standard
        let originalLastSurfaceCloseSetting = defaults.object(forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        let previousTabManager = appDelegate.tabManager
        defaults.set(true, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defer {
            appDelegate.tabManager = previousTabManager
            restoreDefaultsValue(
                originalLastSurfaceCloseSetting,
                forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey,
                defaults: defaults
            )
        }

        let originalWindowId = UUID()
        let focusedWindowId = UUID()
        let originalManager = TabManager(autoWelcomeIfNeeded: false)
        let focusedManager = TabManager(autoWelcomeIfNeeded: false)
        let originalWindow = makeRegisteredShortcutRoutingWindow(id: originalWindowId)
        let focusedWindow = makeRegisteredShortcutRoutingWindow(id: focusedWindowId)

        appDelegate.registerMainWindow(
            originalWindow,
            windowId: originalWindowId,
            tabManager: originalManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        appDelegate.registerMainWindow(
            focusedWindow,
            windowId: focusedWindowId,
            tabManager: focusedManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        defer {
            closeRegisteredShortcutRoutingWindow(originalWindow, id: originalWindowId)
            closeRegisteredShortcutRoutingWindow(focusedWindow, id: focusedWindowId)
        }

        let originalWorkspace = originalManager.addWorkspace(title: "original target", select: true, autoWelcomeIfNeeded: false)
        let focusedWorkspace = focusedManager.addWorkspace(title: "focused target", select: true, autoWelcomeIfNeeded: false)

        switch expectedAction {
        case .closeTab:
            guard let originalPanelId = originalWorkspace.focusedPanelId,
                  originalWorkspace.newTerminalSplit(from: originalPanelId, orientation: .horizontal) != nil,
                  let focusedPanelId = focusedWorkspace.focusedPanelId,
                  focusedWorkspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal) != nil else {
                XCTFail("Expected split panels for \(actionName)", file: file, line: line)
                return
            }
        case .closeWorkspace:
            originalManager.addWorkspace(title: "original survivor", select: false, autoWelcomeIfNeeded: false)
            focusedManager.addWorkspace(title: "focused survivor", select: false, autoWelcomeIfNeeded: false)
        default:
            XCTFail("Unexpected close shortcut action \(expectedAction)", file: file, line: line)
            return
        }

        originalWindow.orderFront(nil)
        focusedWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Model the observed bug: the user-visible focused window is the new window,
        // but the key event still carries the original window number.
        appDelegate.tabManager = originalManager

        let originalTabCountBefore = originalManager.tabs.count
        let focusedTabCountBefore = focusedManager.tabs.count
        let originalPanelCountBefore = originalWorkspace.panels.count
        let focusedPanelCountBefore = focusedWorkspace.panels.count

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: modifiers,
            keyCode: 13,
            windowNumber: originalWindow.windowNumber
        ) else {
            XCTFail("Failed to construct \(actionName) event", file: file, line: line)
            return
        }

        XCTAssertTrue(
            KeyboardShortcutSettings.shortcut(for: expectedAction).matches(event: event),
            "\(actionName) should match \(expectedAction)",
            file: file,
            line: line
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event), file: file, line: line)
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG", file: file, line: line)
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            originalManager.tabs.count,
            originalTabCountBefore,
            "\(actionName) must not close a workspace in the original window when another window is focused",
            file: file,
            line: line
        )

        switch expectedAction {
        case .closeTab:
            XCTAssertEqual(
                originalWorkspace.panels.count,
                originalPanelCountBefore,
                "\(actionName) must not close a panel in the original window when another window is focused",
                file: file,
                line: line
            )
            XCTAssertEqual(
                focusedManager.tabs.count,
                focusedTabCountBefore,
                "\(actionName) should keep the focused workspace open when closing one of multiple panels",
                file: file,
                line: line
            )
            XCTAssertEqual(
                focusedWorkspace.panels.count,
                focusedPanelCountBefore - 1,
                "\(actionName) should close the selected panel in the focused window",
                file: file,
                line: line
            )
        case .closeWorkspace:
            XCTAssertEqual(
                focusedManager.tabs.count,
                focusedTabCountBefore - 1,
                "\(actionName) should close the selected workspace in the focused window",
                file: file,
                line: line
            )
            XCTAssertFalse(
                focusedManager.tabs.contains { $0.id == focusedWorkspace.id },
                "\(actionName) should remove the selected workspace in the focused window",
                file: file,
                line: line
            )
        default:
            break
        }
    }

    @discardableResult
    private func waitForCondition(
        timeout: TimeInterval = 1.0,
        interval: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
        }
        return condition()
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NSEvent? {
        makeKeyEvent(
            type: .keyDown,
            key: key,
            modifiers: modifiers,
            keyCode: keyCode,
            windowNumber: windowNumber,
            isARepeat: isARepeat,
            timestamp: timestamp
        )
    }

    private func makeKeyDownEvent(
        shortcut: StoredShortcut,
        windowNumber: Int
    ) -> NSEvent? {
        guard !shortcut.isUnbound,
              !shortcut.hasChord,
              let keyCode = shortcut.firstStroke.resolvedKeyCode() else {
            return nil
        }
        return makeKeyDownEvent(
            key: shortcut.menuItemKeyEquivalent ?? shortcut.key,
            modifiers: shortcut.modifierFlags,
            keyCode: keyCode,
            windowNumber: windowNumber
        )
    }

    private func makeKeyEvent(
        type: NSEvent.EventType,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
    }

    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private func withPreservedGeneralPasteboard(_ body: () throws -> Void) throws {
        let pasteboard = NSPasteboard.general
        let snapshots = snapshotPasteboardItems(pasteboard)
        defer {
            restorePasteboardItems(snapshots, to: pasteboard)
        }
        try body()
    }

    private func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        pasteboard.pasteboardItems?.map { item in
            PasteboardItemSnapshot(
                representations: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                }
            )
        } ?? []
    }

    private func restorePasteboardItems(
        _ snapshots: [PasteboardItemSnapshot],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = snapshots.map { snapshot in
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private enum TextBoxSessionDraftPartSummary: Hashable {
        case text(String)
        case attachment(String)
    }

    private struct TextBoxSessionDraftSummary: Hashable {
        let isActive: Bool
        let parts: [TextBoxSessionDraftPartSummary]
    }

    private func installTextBoxSessionDraft(
        on terminalPanel: TerminalPanel,
        imageName: String,
        beforeText: String,
        afterText: String,
        isActive: Bool
    ) throws {
        let imageURL = try makeTemporaryPNGFile(named: imageName)
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let textView = makeRetainedTextBoxInputTextView()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.installDebugInlineFixture(attachment, beforeText: beforeText, afterText: afterText)

        terminalPanel.preserveTextBoxContentForUnmount(from: textView)
        terminalPanel.isTextBoxActive = isActive
    }

    private func restoredTextBoxDraftSummaries(in workspace: Workspace) -> [TextBoxSessionDraftSummary] {
        workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .compactMap { panel in
                guard let draft = panel.sessionTextBoxDraftSnapshot() else { return nil }
                return TextBoxSessionDraftSummary(
                    isActive: draft.isActive,
                    parts: textBoxSessionDraftPartSummaries(draft.parts)
                )
            }
    }

    private func textBoxSessionDraftPartSummaries(
        _ parts: [SessionTextBoxInputDraftPart]
    ) -> [TextBoxSessionDraftPartSummary] {
        parts.compactMap { part in
            switch part.kind {
            case .text:
                guard let text = part.text, !text.isEmpty else { return nil }
                return .text(text)
            case .attachment:
                guard let attachment = part.attachment else { return nil }
                return .attachment(attachment.displayName)
            }
        }
    }

    private func sessionWindowSnapshot(tabManager: TabManager, windowId: UUID? = nil) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            windowId: windowId,
            frame: nil,
            display: nil,
            tabManager: tabManager.sessionSnapshot(includeScrollback: false),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: SessionPersistencePolicy.defaultSidebarWidth
            )
        )
    }

    private func makeRetainedTextBoxInputTextView() -> TextBoxInputTextView {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        Self.retainedTextBoxRestoreViews.append(textView)
        return textView
    }

    private func makeTemporaryPNGFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-textbox-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url.standardizedFileURL
    }

    private func preparedSessionAttachmentSnapshot(
        _ attachment: TextBoxAttachment
    ) throws -> SessionTextBoxInputAttachmentSnapshot {
        _ = attachment.debugPrepareSessionDraftCopySynchronouslyForTesting()
        return SessionTextBoxInputAttachmentSnapshot(attachment)
    }

    private enum TextBoxSubmissionPartSummary: Equatable {
        case text(String)
        case attachment(String)
    }

    private func submissionPartSummaries(_ parts: [TextBoxSubmissionPart]) -> [TextBoxSubmissionPartSummary] {
        parts.map { part in
            switch part {
            case .text(let text):
                return .text(text)
            case .attachment(let attachment):
                return .attachment(attachment.submissionText)
            }
        }
    }

    private func expectedImageSubmission(before: String, url: URL, after: String) -> String {
        var result = "\(before)\(TextBoxAttachment.submissionText(forLocalFileURL: url))"
        if result.last?.isWhitespace != true,
           after.first?.isWhitespace != true {
            result += " "
        }
        result += after
        return result
    }

    private struct RenderedPixelBounds {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
        let rasterHeight: Int

        var midY: CGFloat {
            CGFloat(minY + maxY) / 2
        }

        var topPadding: Int { minY }

        var bottomPadding: Int { max(0, rasterHeight - 1 - maxY) }

        var verticalPaddingDelta: Int {
            abs(topPadding - bottomPadding)
        }

        func debugDescription() -> String {
            "(minY:\(minY), maxY:\(maxY), midY:\(midY), top:\(topPadding), bottom:\(bottomPadding))"
        }
    }

    private func makeRenderableTextBoxInput(width: CGFloat, height: CGFloat) -> TextBoxInputTextView {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.textColor = .white
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 30)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 1, height: height > 30 ? 4 : 5)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        Self.retainedTextBoxRenderScrollViews.append(scrollView)
        addTeardownBlock {
            Self.retainedTextBoxRenderScrollViews.removeAll { $0 === scrollView }
        }
        return textView
    }

    private func renderedTextScanRect(
        in textView: TextBoxInputTextView,
        characterRange: NSRange
    ) throws -> NSRect {
        let glyphFrame = try visibleGlyphFrame(in: textView, characterRange: characterRange)
        return NSRect(
            x: max(0, floor(glyphFrame.minX) - 2),
            y: max(0, floor(glyphFrame.minY) - 10),
            width: ceil(glyphFrame.width) + 4,
            height: ceil(glyphFrame.height) + 20
        )
    }

    private func renderedNonBackgroundPixelBounds(
        in textView: TextBoxInputTextView,
        scanRect: NSRect
    ) throws -> RenderedPixelBounds {
        let bitmap = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let scaleX = CGFloat(width) / max(1, textView.bounds.width)
        let scaleY = CGFloat(height) / max(1, textView.bounds.height)

        let minScanX = max(0, Int(floor(scanRect.minX * scaleX)))
        let minScanY = max(0, Int(floor(scanRect.minY * scaleY)))
        let maxScanX = min(width - 1, Int(ceil(scanRect.maxX * scaleX)))
        let maxScanY = min(height - 1, Int(ceil(scanRect.maxY * scaleY)))

        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min

        guard minScanX <= maxScanX, minScanY <= maxScanY else {
            XCTFail("Expected scan rect \(scanRect) inside text bounds \(textView.bounds)")
            return RenderedPixelBounds(minX: 0, minY: 0, maxX: 0, maxY: 0, rasterHeight: height)
        }

        for y in minScanY...maxScanY {
            for x in minScanX...maxScanX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let brightness = max(color.redComponent, color.greenComponent, color.blueComponent)
                guard brightness > 0.08 || color.alphaComponent > 0.08 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard minX != Int.max else {
            XCTFail("Expected rendered text pixels inside \(scanRect)")
            return RenderedPixelBounds(minX: 0, minY: 0, maxX: 0, maxY: 0, rasterHeight: height)
        }

        return RenderedPixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY, rasterHeight: height)
    }

    private func assertRenderedVerticalBoundsUnchanged(
        _ before: RenderedPixelBounds,
        _ after: RenderedPixelBounds,
        accuracy: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(CGFloat(after.minY), CGFloat(before.minY), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(CGFloat(after.maxY), CGFloat(before.maxY), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(after.midY, before.midY, accuracy: accuracy, file: file, line: line)
    }

    private func visibleGlyphFrame(
        in textView: TextBoxInputTextView,
        characterRange: NSRange
    ) throws -> NSRect {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
    }

    private func visibleAttachmentCellFrame(in textView: TextBoxInputTextView) throws -> NSRect {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        let attributed = textView.attributedString()
        let fullRange = NSRange(location: 0, length: attributed.length)
        var attachmentRange: NSRange?
        var attachmentCell: NSTextAttachmentCellProtocol?
        attributed.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, stop in
            guard let attachment = value as? NSTextAttachment,
                  let cell = attachment.attachmentCell else { return }
            attachmentRange = range
            attachmentCell = cell
            stop.pointee = true
        }

        let range = try XCTUnwrap(attachmentRange)
        let cell = try XCTUnwrap(attachmentCell)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let lineFragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let glyphPosition = layoutManager.location(forGlyphAt: glyphRange.location)
        return cell
            .cellFrame(
                for: textContainer,
                proposedLineFragment: lineFragment,
                glyphPosition: glyphPosition,
                characterIndex: range.location
            )
            .offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
    }

    private func baselineOffsetsForTextRuns(in textView: TextBoxInputTextView) -> [CGFloat] {
        let attributed = textView.attributedString()
        let fullRange = NSRange(location: 0, length: attributed.length)
        var offsets: [CGFloat] = []
        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, _, _ in
            guard attributes[.attachment] == nil else { return }
            if let value = attributes[.baselineOffset] as? CGFloat {
                offsets.append(value)
            } else if let number = attributes[.baselineOffset] as? NSNumber {
                offsets.append(CGFloat(truncating: number))
            } else {
                offsets.append(0)
            }
        }
        return Array(Set(offsets)).sorted()
    }

    private func writeFileURLs(
        _ fileURLs: [URL],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        pasteboard.declareTypes(
            [.fileURL, PasteboardFileURLReader.legacyFilenamesPboardType, .string],
            owner: nil
        )
        if let firstURL = fileURLs.first {
            pasteboard.setString(firstURL.absoluteString, forType: .fileURL)
        }
        pasteboard.setPropertyList(
            fileURLs.map(\.path),
            forType: PasteboardFileURLReader.legacyFilenamesPboardType
        )
        pasteboard.setString(
            TerminalImageTransferPlanner.insertedText(forFileURLs: fileURLs),
            forType: .string
        )
    }

    private func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut? = nil,
        _ body: () -> Void
    ) {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
            #if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
            #endif
        }
        KeyboardShortcutSettings.setShortcut(shortcut ?? action.defaultShortcut, for: action)
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
        #endif
        body()
    }

    private func makeCommandPaletteShortcutTestWindow() -> NSWindow {
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        return window
    }

    private func assertStaleCloseDefaultShortcutSuppressesMenuFallback(
        staleAction: KeyboardShortcutSettings.Action,
        replacementAction: KeyboardShortcutSettings.Action,
        replacementShortcut: StoredShortcut,
        remappedStaleShortcut: StoredShortcut,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return
        }
        guard let event = makeKeyDownEvent(shortcut: replacementShortcut, windowNumber: 0) else {
            XCTFail("Failed to construct reassigned close-default shortcut event", file: file, line: line)
            return
        }

        withTemporaryShortcut(action: staleAction, shortcut: remappedStaleShortcut) {
            withTemporaryShortcut(action: replacementAction, shortcut: replacementShortcut) {
                XCTAssertTrue(
                    appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                    "\(staleAction.rawValue) should suppress its stale default menu fallback after that key is reassigned",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest(
        _ openRequest: (_ appDelegate: AppDelegate, _ window: NSWindow) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window", file: file, line: line)
            return
        }

        openRequest(appDelegate, window)
        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let escapeKeyDown = makeKeyEvent(
            type: .keyDown,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ), let escapeKeyUp = makeKeyEvent(
            type: .keyUp,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape key events", file: file, line: line)
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyDown), file: file, line: line)
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG", file: file, line: line)
#endif

        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyUp),
            "Escape keyUp should be consumed after dismiss for command palette open requests",
            file: file,
            line: line
        )
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG", file: file, line: line)
#endif
    }

    func testBrowserFocusModeEscapeArmsDisarmsAndSecondEscapeExits() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        let baseTimestamp = ProcessInfo.processInfo.systemUptime
        guard let inactiveEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.01),
              let inactiveRepeatEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, isARepeat: true, timestamp: baseTimestamp + 0.015),
              let activeFirstEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.04),
              let activeRepeatEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, isARepeat: true, timestamp: baseTimestamp + 0.045),
              let activeSecondEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.05),
              let capsExitFirstEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [.capsLock], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.08),
              let capsExitSecondEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [.capsLock], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.09),
              let commandS = makeKeyDownEvent(key: "s", modifiers: [.command], keyCode: 1, windowNumber: harness.window.windowNumber) else {
            XCTFail("Failed to construct browser focus mode key events")
            return
        }

        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(inactiveEscape, webView: harness.webView, source: "unit.inactiveEscape"),
            .inactive
        )
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(inactiveRepeatEscape, webView: harness.webView, source: "unit.inactiveRepeatEscape"),
            .inactive
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.escape", focusWebView: false)
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(commandS, webView: harness.webView, source: "unit.commandS"),
            .forwardToWebView
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeFirstEscape, webView: harness.webView, source: "unit.firstEscapeAgain"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeRepeatEscape, webView: harness.webView, source: "unit.activeRepeatEscape"),
            .consume
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeFirstEscape, webView: harness.webView, source: "unit.firstEscapeAgain.duplicate"),
            .consume
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeSecondEscape, webView: harness.webView, source: "unit.secondEscape"),
            .consume
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.capsEscape", focusWebView: false)
        )
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(capsExitFirstEscape, webView: harness.webView, source: "unit.capsExitFirstEscape"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(capsExitSecondEscape, webView: harness.webView, source: "unit.capsExitSecondEscape"),
            .consume
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
    }

    func testBrowserFocusModeStaleExitArmRearmsOnNextEscape() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        let baseTimestamp = ProcessInfo.processInfo.systemUptime
        guard let firstEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.01),
              let secondEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 2.0),
              let thirdEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 2.1) else {
            XCTFail("Failed to construct browser focus mode timeout Escape events")
            return
        }

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.staleExitArm", focusWebView: false)
        )
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(firstEscape, webView: harness.webView, source: "unit.staleExitArm.first"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(secondEscape, webView: harness.webView, source: "unit.staleExitArm.rearm"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(thirdEscape, webView: harness.webView, source: "unit.staleExitArm.exit"),
            .consume
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
    }

    func testBrowserFocusModeClearsWhenWebViewLeavesInteractiveHost() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.staleHost", focusWebView: false)
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        harness.webView.removeFromSuperview()

        guard let commandS = makeKeyDownEvent(key: "s", modifiers: [.command], keyCode: 1, windowNumber: harness.window.windowNumber) else {
            XCTFail("Failed to construct Cmd+S event")
            return
        }

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(commandS, webView: harness.webView, source: "unit.staleHost"),
            .inactive
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
    }

    func testBrowserFocusModeCommandEquivalentSkipsAppMenuFallback() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.commandEquivalent", focusWebView: false)
        )

        let originalMainMenu = NSApp.mainMenu
        let probe = MenuActionProbe()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Find", action: #selector(MenuActionProbe.perform(_:)), keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.command]
        item.target = probe
        menu.addItem(item)
        let returnItem = NSMenuItem(title: "Run", action: #selector(MenuActionProbe.perform(_:)), keyEquivalent: "\r")
        returnItem.keyEquivalentModifierMask = [.command]
        returnItem.target = probe
        menu.addItem(returnItem)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = originalMainMenu }

        guard let commandF = makeKeyDownEvent(key: "f", modifiers: [.command], keyCode: 3, windowNumber: harness.window.windowNumber),
              let commandReturn = makeKeyDownEvent(key: "\r", modifiers: [.command], keyCode: 36, windowNumber: harness.window.windowNumber) else {
            XCTFail("Failed to construct browser focus mode command-equivalent events")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: commandF))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertTrue(harness.webView.performKeyEquivalent(with: commandF))
        XCTAssertEqual(probe.callCount, 0, "Focus mode must not replay unhandled page shortcuts into the app menu")
        XCTAssertTrue(harness.webView.performKeyEquivalent(with: commandReturn))
        XCTAssertEqual(probe.callCount, 0, "Focus mode must consume unhandled Cmd+Return instead of falling through to the app menu")
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
    }

    private func makeBrowserFocusModeHarness(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (windowId: UUID, window: NSWindow, panel: BrowserPanel, webView: CmuxWebView)? {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return nil
        }

        let windowId = appDelegate.createMainWindow()
        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserURL = URL(string: "data:text/html;base64,PGh0bWw+PGJvZHk+Zm9jdXM8L2JvZHk+PC9odG1sPg=="),
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, url: browserURL, preferSplitRight: true),
              let browserPanel = manager.selectedWorkspace?.browserPanel(for: browserPanelId) ?? workspace.browserPanel(for: browserPanelId),
              let webView = browserPanel.webView as? CmuxWebView else {
            closeWindow(withId: windowId)
            XCTFail("Expected attached browser focus mode harness", file: file, line: line)
            return nil
        }

        workspace.focusPanel(browserPanel.id)
        if webView.superview == nil {
            webView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(webView)
        }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(webView), file: file, line: line)
        return (windowId: windowId, window: window, panel: browserPanel, webView: webView)
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var stack: [NSView] = [hostedView]
        while let current = stack.popLast() {
            if let surfaceView = current as? GhosttyNSView {
                return surfaceView
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func findEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func firstResponderOwnsTextField(_ firstResponder: NSResponder?, textField: NSTextField) -> Bool {
        if firstResponder === textField {
            return true
        }
        if let editor = firstResponder as? NSTextView,
           editor.isFieldEditor,
           editor.delegate as? NSTextField === textField {
            return true
        }
        return false
    }

    private func mainWindowIds() -> Set<UUID> {
        Set(NSApp.windows.compactMap { window in
            guard let raw = window.identifier?.rawValue,
                  raw.hasPrefix("cmux.main.") else {
                return nil
            }
            return UUID(uuidString: String(raw.dropFirst("cmux.main.".count)))
        })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        let appDelegate = AppDelegate.shared
        let originalConfirmationHandler = appDelegate?.debugCloseMainWindowConfirmationHandler
        appDelegate?.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate?.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func closeTestWindow(_ window: NSWindow) {
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
    }

    private func waitFor(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func attachTestResponder(_ responder: NSView, to window: NSWindow) {
        (window.contentView?.superview ?? window.contentView)?.addSubview(responder)
    }

    private func restoreDefaultsValue(_ value: Any?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

private final class CommandPaletteMarkedTextFieldEditor: NSTextView {
    var hasMarkedTextForTesting = false

    override func hasMarkedText() -> Bool {
        hasMarkedTextForTesting
    }
}
