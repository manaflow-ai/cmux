import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateBareSpaceShortcutRoutingTests: XCTestCase {
    private var savedShortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var actionsWithPersistedShortcut: Set<KeyboardShortcutSettings.Action> = []
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    override func setUp() {
        super.setUp()
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

    func testBareSpaceShortcutDispatchesConfiguredAction() {
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
        let shortcut = StoredShortcut(key: "space", command: false, shift: false, option: false, control: false)

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let event = makeKeyDownEvent(key: " ", keyCode: 49, windowNumber: window.windowNumber) else {
                XCTFail("Failed to construct Space event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "Bare Space should dispatch when explicitly configured")
    }

    func testBareSpaceChordPrefixArmsConfiguredShortcut() {
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
            key: "space",
            command: false,
            shift: false,
            option: false,
            control: false,
            chordKey: "n"
        )

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(key: " ", keyCode: 49, windowNumber: window.windowNumber),
                  let actionEvent = makeKeyDownEvent(key: "n", keyCode: 45, windowNumber: window.windowNumber) else {
                XCTFail("Failed to construct Space chord events")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertEqual(manager.tabs.count, initialCount, "Bare Space prefix must not fire the action early")
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "Bare Space chord should dispatch on the second stroke")
    }

    func testCreateMainWindowIgnoresLegacyPersistedGeometryWhenNoSourceWindow() throws {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousShared }

        let defaults = UserDefaults.standard
        let persistedGeometryKey = AppDelegate.debugPersistedWindowGeometryDefaultsKey
        let previousPersistedGeometry = defaults.object(forKey: persistedGeometryKey)
        let primaryFrameAutosaveName = AppDelegate.debugPrimaryMainWindowFrameAutosaveName
        let primaryFrameAutosaveKey = appKitFrameAutosaveDefaultsKey(primaryFrameAutosaveName)
        let previousPrimaryFrameAutosave = defaults.object(forKey: primaryFrameAutosaveKey)
        NSWindow.removeFrame(usingName: primaryFrameAutosaveName)
        var windowId: UUID?
        defer {
            if let windowId {
                closeWindow(withId: windowId)
            }
            restoreDefaultsValue(
                previousPrimaryFrameAutosave,
                forKey: primaryFrameAutosaveKey,
                defaults: defaults
            )
            restoreDefaultsValue(
                previousPersistedGeometry,
                forKey: persistedGeometryKey,
                defaults: defaults
            )
        }

        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        let savedWidth = max(
            CGFloat(SessionPersistencePolicy.minimumWindowWidth),
            min(720, visibleFrame.width - 80)
        )
        let savedHeight = max(
            CGFloat(SessionPersistencePolicy.minimumWindowHeight),
            min(520, visibleFrame.height - 80)
        )
        let savedFrame = CGRect(
            x: visibleFrame.minX + 37,
            y: visibleFrame.minY + 43,
            width: savedWidth,
            height: savedHeight
        )
        let payload = AppDelegate.PersistedWindowGeometry(
            version: AppDelegate.persistedWindowGeometrySchemaVersion,
            frame: SessionRectSnapshot(savedFrame),
            display: SessionDisplaySnapshot(
                displayID: screen.cmuxDisplayID,
                frame: SessionRectSnapshot(screen.frame),
                visibleFrame: SessionRectSnapshot(screen.visibleFrame)
            )
        )
        defaults.set(try JSONEncoder().encode(payload), forKey: persistedGeometryKey)

        let createdWindowId = appDelegate.createMainWindow(shouldActivate: false, sourceWindow: nil)
        windowId = createdWindowId

        let window = try XCTUnwrap(window(withId: createdWindowId))
        XCTAssertFalse(window.frameAutosaveName.isEmpty)
        XCTAssertGreaterThan(
            abs(window.frame.minX - savedFrame.minX),
            1,
            "Legacy cmux lastWindowGeometry must not compete with AppKit frame autosave."
        )
        XCTAssertGreaterThan(
            abs(window.frame.minY - savedFrame.minY),
            1,
            "Legacy cmux lastWindowGeometry must not compete with AppKit frame autosave."
        )
    }

    func testCreateMainWindowRegistersAppKitFrameAutosaveNames() throws {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousShared }
        let defaults = UserDefaults.standard
        let primaryFrameAutosaveName = AppDelegate.debugPrimaryMainWindowFrameAutosaveName
        let primaryFrameAutosaveKey = appKitFrameAutosaveDefaultsKey(primaryFrameAutosaveName)
        let previousPrimaryFrameAutosave = defaults.object(forKey: primaryFrameAutosaveKey)
        NSWindow.removeFrame(usingName: primaryFrameAutosaveName)
        var secondaryFrameAutosaveName: NSWindow.FrameAutosaveName?

        let firstWindowId = appDelegate.createMainWindow(shouldActivate: false, sourceWindow: nil)
        let secondWindowId = appDelegate.createMainWindow(shouldActivate: false, sourceWindow: nil)
        defer {
            closeWindow(withId: secondWindowId)
            closeWindow(withId: firstWindowId)
            if let secondaryFrameAutosaveName {
                NSWindow.removeFrame(usingName: secondaryFrameAutosaveName)
            }
            restoreDefaultsValue(
                previousPrimaryFrameAutosave,
                forKey: primaryFrameAutosaveKey,
                defaults: defaults
            )
        }

        let firstWindow = try XCTUnwrap(window(withId: firstWindowId))
        let secondWindow = try XCTUnwrap(window(withId: secondWindowId))
        secondaryFrameAutosaveName = secondWindow.frameAutosaveName

        XCTAssertFalse(
            firstWindow.frameAutosaveName.isEmpty,
            "Main windows must opt in to AppKit frame autosave so macOS owns screen topology restoration."
        )
        XCTAssertFalse(
            secondWindow.frameAutosaveName.isEmpty,
            "Additional main windows also need autosave names so monitor wake restores do not fall back to cmux-only geometry."
        )
        XCTAssertNotEqual(
            firstWindow.frameAutosaveName,
            secondWindow.frameAutosaveName,
            "Each live main window needs a distinct AppKit frame autosave name."
        )
    }

    func testClosingSecondaryMainWindowRemovesEphemeralFrameAutosaveName() throws {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousShared }
        let defaults = UserDefaults.standard
        let primaryFrameAutosaveName = AppDelegate.debugPrimaryMainWindowFrameAutosaveName
        let primaryFrameAutosaveKey = appKitFrameAutosaveDefaultsKey(primaryFrameAutosaveName)
        let previousPrimaryFrameAutosave = defaults.object(forKey: primaryFrameAutosaveKey)
        NSWindow.removeFrame(usingName: primaryFrameAutosaveName)

        let firstWindowId = appDelegate.createMainWindow(shouldActivate: false, sourceWindow: nil)
        let secondWindowId = appDelegate.createMainWindow(shouldActivate: false, sourceWindow: nil)
        defer {
            closeWindow(withId: secondWindowId)
            closeWindow(withId: firstWindowId)
            restoreDefaultsValue(
                previousPrimaryFrameAutosave,
                forKey: primaryFrameAutosaveKey,
                defaults: defaults
            )
        }

        let secondWindow = try XCTUnwrap(window(withId: secondWindowId))
        let secondaryFrameAutosaveName = secondWindow.frameAutosaveName
        let secondaryFrameAutosaveKey = appKitFrameAutosaveDefaultsKey(secondaryFrameAutosaveName)
        let previousSecondaryFrameAutosave = defaults.object(forKey: secondaryFrameAutosaveKey)
        defer {
            restoreDefaultsValue(
                previousSecondaryFrameAutosave,
                forKey: secondaryFrameAutosaveKey,
                defaults: defaults
            )
        }

        XCTAssertFalse(secondaryFrameAutosaveName.isEmpty)
        XCTAssertNotEqual(secondaryFrameAutosaveName, primaryFrameAutosaveName)

        NSWindow.removeFrame(usingName: secondaryFrameAutosaveName)
        secondWindow.saveFrame(usingName: secondaryFrameAutosaveName)
        XCTAssertNotNil(defaults.object(forKey: secondaryFrameAutosaveKey))

        closeWindow(withId: secondWindowId)

        XCTAssertNil(
            defaults.object(forKey: secondaryFrameAutosaveKey),
            "UUID-scoped autosave names are per-window and must be removed when the window closes."
        )
    }

    private func makeKeyDownEvent(
        key: String,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut,
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
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
        body()
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

    private func restoreDefaultsValue(_ value: Any?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func appKitFrameAutosaveDefaultsKey(_ name: NSWindow.FrameAutosaveName) -> String {
        "NSWindow Frame \(name)"
    }
}
