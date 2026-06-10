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

// MARK: - Keyboard layout and physical-key fallback tests
extension AppDelegateShortcutRoutingTests {
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

}
