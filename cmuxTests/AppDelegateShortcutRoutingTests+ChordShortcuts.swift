import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Chorded shortcut routing tests
extension AppDelegateShortcutRoutingTests {
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
              let contentView = window.contentView,
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

}
