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

    func testCreateMainWindowUsesPersistedGeometryWhenNoSourceWindow() throws {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousShared }

        let defaults = UserDefaults.standard
        let persistedGeometryKey = AppDelegate.debugPersistedWindowGeometryDefaultsKey
        let previousPersistedGeometry = defaults.object(forKey: persistedGeometryKey)
        var windowId: UUID?
        defer {
            if let windowId {
                closeWindow(withId: windowId)
            }
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
            min(1_100, visibleFrame.width - 40)
        )
        let savedHeight = max(
            CGFloat(SessionPersistencePolicy.minimumWindowHeight),
            min(760, visibleFrame.height - 40)
        )
        let savedFrame = CGRect(
            x: visibleFrame.midX - savedWidth / 2,
            y: visibleFrame.midY - savedHeight / 2,
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
        XCTAssertEqual(window.frame.minX, savedFrame.minX, accuracy: 1)
        XCTAssertEqual(window.frame.minY, savedFrame.minY, accuracy: 1)
        XCTAssertEqual(window.frame.width, savedFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, savedFrame.height, accuracy: 1)
    }

    /// Closing a main window saves its size, and a later window with no source
    /// window opens at it. A test that left a 560 pt window behind gave every
    /// later test's window a 320 pt terminal area, too narrow for a split
    /// (#15488). XCTest runs these two in name order; the second must still
    /// split, because a test's saved geometry does not outlive it.
    func testWindowGeometryIsolation1ClosesNarrowWindow() throws {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousShared }

        let windowId = appDelegate.createMainWindow(shouldActivate: false, sourceWindow: nil)
        XCTAssertEqual(appDelegate.resizeMainWindow(windowId: windowId, width: 560, height: 420)?.width, 560)
        closeWindow(withId: windowId)

        XCTAssertNotNil(
            UserDefaults.standard.data(forKey: AppDelegate.debugPersistedWindowGeometryDefaultsKey),
            "closing the window saves its geometry for the next window"
        )
    }

    func testWindowGeometryIsolation2NextTestWindowStillSplits() throws {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousShared }

        let windowId = appDelegate.createMainWindow(shouldActivate: false, sourceWindow: nil)
        defer { closeWindow(withId: windowId) }
        let workspace = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId)?.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        XCTAssertNotNil(
            workspace.newTerminalSplit(from: panelId, orientation: .horizontal, focus: false),
            "a window opened at an earlier test's 560 pt size has no room for a split"
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
}
