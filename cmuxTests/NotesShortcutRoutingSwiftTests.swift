import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func testComment(_ message: @autoclosure () -> String) -> Comment? {
    let value = message()
    return value.isEmpty ? nil : Comment(rawValue: value)
}

private func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 == value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression(), testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTFail(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
}

/// New Note (Cmd+Ctrl+N) shortcut routing coverage for the Notes feature.
///
/// This test lives in its own Swift Testing suite (instead of the large
/// `AppDelegateShortcutRoutingTests` XCTest file) per the repo policy that new
/// non-UI test coverage uses Swift Testing. The setup/teardown blocks mirror
/// the shortcut-settings isolation performed by
/// `AppDelegateShortcutRoutingTests.setUpWithError()` / `tearDown()` so the
/// default binding is asserted against a clean, isolated settings state.
@MainActor
@Suite(.serialized)
struct NotesShortcutRoutingSwiftTests {
    @Test func testNewNoteShortcutDefaultsToCmdCtrlNAndRoutesToSharedConfiguredActionPath() {
        // Mirror AppDelegateShortcutRoutingTests.setUpWithError().
        AppDelegate.installWindowResponderSwizzlesForTesting()
        #if DEBUG
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugBeginShortcutRoutingFocusedWindowCaptureForTesting()
        #endif
        let actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        let savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-notes-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        defer {
            // Mirror AppDelegateShortcutRoutingTests.tearDown() for the state
            // this test can touch.
            #if DEBUG
            KeyboardShortcutRecorderActivity.resetForTesting()
            AppDelegate.shared?.debugEndShortcutRoutingFocusedWindowCaptureForTesting()
            KeyboardShortcutSettings.shortcutLookupObserver = nil
            #endif
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            AppDelegate.shared?.debugNewNoteBuiltInActionHandler = nil
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
        }

        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let previousNotes = defaults.object(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        defaults.set(false, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        defer {
            if let previousNotes {
                defaults.set(previousNotes, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            } else {
                defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            }
        }

        let cmdCtrlN = StoredShortcut(key: "n", command: true, shift: false, option: false, control: true)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newNote), cmdCtrlN)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.newNote.normalizedRecordedShortcutResult(cmdCtrlN),
            .accepted(cmdCtrlN),
            "Default New Note shortcut must not conflict with any other action"
        )
        XCTAssertTrue(
            KeyboardShortcutSettings.settingsVisibleActions.contains(.newNote),
            "New Note must be visible/editable in Settings → Keyboard Shortcuts"
        )

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        var newNoteCount = 0
        appDelegate.debugNewNoteBuiltInActionHandler = { newNoteCount += 1 }
        defer { appDelegate.debugNewNoteBuiltInActionHandler = nil }

        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command, .control],
            keyCode: 45, // kVK_ANSI_N
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+Ctrl+N should be consumed by the New Note shortcut"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertEqual(
            newNoteCount,
            1,
            "Cmd+Ctrl+N must route through the shared configured built-in action path"
        )
    }

    // MARK: - Helpers (copied from AppDelegateShortcutRoutingTests)

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

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
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
}
