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


// MARK: - Notification badge, pane flash, and menu bar preferences
extension NotificationDockBadgeTests {
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

    func testMenuBarOnlyPreferenceDefaultsToRegularActivationPolicy() {
        let suiteName = "MenuBarOnlySettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertFalse(MenuBarOnlySettings.isEnabled(defaults: defaults))
        XCTAssertEqual(MenuBarOnlySettings.activationPolicy(defaults: defaults), .regular)
        XCTAssertFalse(MenuBarOnlySettings.shouldShowMainWindowMenuItem(defaults: defaults))

        defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
        XCTAssertTrue(MenuBarOnlySettings.isEnabled(defaults: defaults))
        XCTAssertEqual(MenuBarOnlySettings.activationPolicy(defaults: defaults), .accessory)
        XCTAssertTrue(MenuBarOnlySettings.shouldShowMainWindowMenuItem(defaults: defaults))

        defaults.set(false, forKey: MenuBarOnlySettings.menuBarOnlyKey)
        XCTAssertFalse(MenuBarOnlySettings.isEnabled(defaults: defaults))
        XCTAssertEqual(MenuBarOnlySettings.activationPolicy(defaults: defaults), .regular)
        XCTAssertFalse(MenuBarOnlySettings.shouldShowMainWindowMenuItem(defaults: defaults))
    }

    func testMenuBarOnlyForcesMenuBarExtraVisible() {
        let suiteName = "MenuBarOnlyVisibilityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: MenuBarExtraSettings.showInMenuBarKey)
        XCTAssertFalse(MenuBarExtraSettings.shouldInstallMenuBarExtra(defaults: defaults))

        defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
        XCTAssertTrue(MenuBarExtraSettings.shouldInstallMenuBarExtra(defaults: defaults))

        defaults.set(false, forKey: MenuBarOnlySettings.menuBarOnlyKey)
        defaults.set(true, forKey: MenuBarExtraSettings.showInMenuBarKey)
        XCTAssertTrue(MenuBarExtraSettings.shouldInstallMenuBarExtra(defaults: defaults))
    }

}
