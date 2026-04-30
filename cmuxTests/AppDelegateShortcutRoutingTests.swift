import XCTest

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
private final class GhosttyCommandEquivalentProbeView: GhosttyNSView {
    var afterMenuMissCallCount = 0
    var pasteCallCount = 0
    var pasteAsPlainTextCallCount = 0
    var performAfterMenuMissResult = true

    override func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        afterMenuMissCallCount += 1
        return performAfterMenuMissResult
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
    private var savedShortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var actionsWithPersistedShortcut: Set<KeyboardShortcutSettings.Action> = []
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

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

    override func setUp() {
        super.setUp()
        // Prevent a single hanging test from consuming the entire CI timeout budget.
        executionTimeAllowance = 30
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
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        AppDelegate.shared?.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        AppDelegate.shared?.debugCloseMainWindowConfirmationHandler = nil
        AppDelegate.shared?.debugCreateMainWindowSourceIsNativeFullScreenOverride = nil
        AppDelegate.shared?.dismissNotificationsPopoverIfShown()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        for action in KeyboardShortcutSettings.Action.allCases {
            if actionsWithPersistedShortcut.contains(action),
               let savedShortcut = savedShortcutsByAction[action] {
                KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
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

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
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
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "settings.json chord should dispatch the configured shortcut")
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

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

        secondWindow.makeKeyAndOrderFront(nil)
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
        firstWindow.makeKeyAndOrderFront(nil)
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

        secondWindow.makeKeyAndOrderFront(nil)
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
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

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

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstWorkspace = firstManager.selectedWorkspace,
              let secondWorkspace = secondManager.selectedWorkspace else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstSurfaceCount = firstWorkspace.panels.count
        let secondSurfaceCount = secondWorkspace.panels.count

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

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(firstWorkspace.panels.count, firstSurfaceCount, "Cmd+T must not create a surface in stale active window")
        XCTAssertEqual(secondWorkspace.panels.count, secondSurfaceCount + 1, "Cmd+T should create a surface in the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Shortcut routing should retarget active manager to event window")
    }

    func testCmdDRoutesSplitToEventWindowWhenKeyWindowIsDifferent() {
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
              let firstWindow = window(withId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstWorkspace = firstManager.selectedWorkspace,
              let secondWorkspace = secondManager.selectedWorkspace else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        firstWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let firstSurfaceCount = firstWorkspace.panels.count
        let secondSurfaceCount = secondWorkspace.panels.count

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

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(firstWorkspace.panels.count, firstSurfaceCount, "Cmd+D must not create a split in the stale key window")
        XCTAssertEqual(secondWorkspace.panels.count, secondSurfaceCount + 1, "Cmd+D should create a split in the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Split shortcut routing should keep the event window active")
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
        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }

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

        XCTAssertNil(self.window(withId: windowId), "Confirming Cmd+Ctrl+W should close the window")
    }

    // NOTE: This test is skipped in CI via -skip-testing in ci.yml because closing
    // the last Ghostty surface tears down the PTY/shell, which blocks indefinitely
    // on headless runners. The xcodebuild test host doesn't inherit CI env vars,
    // so XCTSkip can't detect CI from inside the test.
    func testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Auto-confirm window close to avoid a modal dialog that blocks the RunLoop.
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let targetWindow = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs[0].panels.count, 1)

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

        XCTAssertNil(
            self.window(withId: windowId),
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
        auxiliaryWindow.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        auxiliaryWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        defer {
            if auxiliaryWindow.isVisible {
                auxiliaryWindow.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
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

        guard let newWorkspaceId = appDelegate.addWorkspaceInPreferredMainWindow(debugSource: "test.issue2737") else {
            XCTFail("Expected workspace creation to route to the test window")
            return
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        guard let newWorkspace = manager.tabs.first(where: { $0.id == newWorkspaceId }) else {
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

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

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

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

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

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
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

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .triggerFlash,
            shortcut: StoredShortcut(key: "/", command: true, shift: true, option: false, control: false)
        ) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "?",
                charactersIgnoringModifiers: "?",
                isARepeat: false,
                keyCode: 44 // kVK_ANSI_Slash
            ) else {
                XCTFail("Failed to construct Cmd+Shift+/ event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
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

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(action: .nextSurface) {
            // Non-US layouts can report "*" (or other symbols) for kVK_ANSI_RightBracket with Shift.
            // Shortcut matching should still allow Cmd+Shift+] via keyCode fallback.
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
                XCTFail("Failed to construct non-US Cmd+Shift+] event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdPhysicalOWithDvorakCharactersTriggersRenameTabShortcut() {
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

    func testCmdShiftRRequestsRenameWorkspaceInCommandPalette() {
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

    func testCmdShiftERequestsEditWorkspaceDescriptionInCommandPalette() {
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

        let renameWorkspaceExpectation = expectation(description: "Rename workspace notification should not fire for Cmd+Shift+E")
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
            modifiers: [.command, .shift],
            keyCode: 14, // kVK_ANSI_E
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+E event")
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

        let dismissExpectation = expectation(description: "Expected command palette toggle notification for Escape dismiss")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
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
            forName: .commandPaletteToggleRequested,
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
            forName: .commandPaletteToggleRequested,
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
            forName: .commandPaletteToggleRequested,
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
            forName: .commandPaletteToggleRequested,
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

        window.makeKeyAndOrderFront(nil)
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
            forName: .commandPaletteToggleRequested,
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
            forName: .commandPaletteToggleRequested,
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
            forName: .commandPaletteToggleRequested,
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

    // MARK: - Non-Latin keyboard layout shortcut tests

    func testBrowserFirstFindShortcutRoutingRecognizesBrowserLocalFindCommandFamily() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-g", [.command], "g", 5),
            ("cmd-shift-g", [.command, .shift], "g", 5),
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

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window context")
            return
        }

        let surfaceCountBefore = workspace.panels.count

        // Simulate non-Latin layout where layout translation also fails (returns nil).
        // The ANSI keyCode fallback should still match the physical T key.
        appDelegate.shortcutLayoutCharacterProvider = { _, _ in nil }
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
            characters: "",
            charactersIgnoringModifiers: "е", // Cyrillic е — non-ASCII
            isARepeat: false,
            keyCode: 17 // kVK_ANSI_T
        ) else {
            XCTFail("Failed to construct non-Latin Cmd+T event with failed layout translation")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event), "Cmd+T should fall back to keyCode with non-Latin layout")
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(workspace.panels.count, surfaceCountBefore + 1, "Cmd+T keyCode fallback should create a new surface")
    }

    func testWindowSendEventRepairsLostFirstResponderForFocusedTerminalTyping() {
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

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before repair test"
        )

        XCTAssertTrue(window.makeFirstResponder(nil), "Expected test to clear the window first responder")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before repaired typing"
        )
        XCTAssertTrue(window.firstResponder == nil || window.firstResponder is NSWindow, "Expected a broken key-routing responder")

#if DEBUG
        var forwardedKeyDownCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 0 else { return }
            forwardedKeyDownCount += 1
        }
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Typing should repair first responder back to the focused terminal surface"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Typing repair should restore the Ghostty surface view as first responder")
#if DEBUG
        // forwardedKeyDownCount is only observable through the DEBUG-only
        // GhosttyNSView.debugGhosttySurfaceKeyEventObserver seam; the first-
        // responder assertions above act as the Release-build proxy.
        XCTAssertGreaterThan(forwardedKeyDownCount, 0, "Typing repair should forward the keyDown into Ghostty")
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

    func testWindowSendEventRepairsVisibleSameWindowResponderDriftForFocusedTerminalTyping() {
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
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before repair test"
        )

        XCTAssertTrue(window.makeFirstResponder(strayView), "Expected test to install a visible wrong first responder")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before repaired typing"
        )
        XCTAssertTrue(window.firstResponder === strayView, "Expected a visible same-window responder drift")

#if DEBUG
        var forwardedKeyDownCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 0 else { return }
            forwardedKeyDownCount += 1
        }
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Typing should repair first responder back to the focused terminal surface"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Typing repair should restore the Ghostty surface view as first responder")
#if DEBUG
        XCTAssertGreaterThan(forwardedKeyDownCount, 0, "Typing repair should forward the keyDown into Ghostty")
#endif
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
        contentView.addSubview(sidebarResponder)
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
        contentView.addSubview(sidebarResponder)
        defer { sidebarResponder.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(window.makeFirstResponder(sidebarResponder), "Expected right sidebar responder to take focus")
        appDelegate.fileExplorerState?.mode = .feed
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .feed, in: window)
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
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
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
        XCTAssertEqual(appDelegate.fileExplorerState?.mode, .feed)
        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Cmd+F from a non-file right sidebar mode should not refocus the terminal responder"
        )
    }

    func testWindowSendEventRepairsFocusedTerminalSearchTypingAfterResponderDrift() {
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let searchState = TerminalSurface.SearchState(needle: "")
        terminalPanel.surface.searchState = searchState
        terminalPanel.hostedView.setSearchOverlay(searchState: searchState)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let searchField = findEditableTextField(in: terminalPanel.hostedView) else {
            XCTFail("Expected mounted terminal search field")
            return
        }

        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Expected terminal search field to own first responder before drift"
        )

        XCTAssertTrue(window.makeFirstResponder(nil), "Expected test to clear the window first responder")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Expected terminal search field to lose first responder before repaired typing"
        )

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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Typing should repair focus back to the terminal search field"
        )
        XCTAssertEqual(searchField.stringValue, "a", "Typing repair should preserve the first key in the search field")
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false
    ) -> NSEvent? {
        makeKeyEvent(
            type: .keyDown,
            key: key,
            modifiers: modifiers,
            keyCode: keyCode,
            windowNumber: windowNumber,
            isARepeat: isARepeat
        )
    }

    private func makeKeyEvent(
        type: NSEvent.EventType,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: isARepeat,
            keyCode: keyCode
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
        }
        KeyboardShortcutSettings.setShortcut(shortcut ?? action.defaultShortcut, for: action)
        body()
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
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
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
