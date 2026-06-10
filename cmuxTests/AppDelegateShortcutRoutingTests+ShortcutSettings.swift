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

// MARK: - Shortcut settings and preferences window tests
extension AppDelegateShortcutRoutingTests {
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

}
