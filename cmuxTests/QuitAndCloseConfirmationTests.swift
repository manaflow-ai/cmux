import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Sparkle
import CmuxUpdater

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Quit warning and last-surface-close confirmation settings
final class LastSurfaceCloseShortcutSettingsTests: XCTestCase {
    func testDefaultClosesWorkspace() {
        let suiteName = "LastSurfaceCloseShortcutSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(LastSurfaceCloseShortcutSettings.closesWorkspace(defaults: defaults))
    }

    func testStoredTrueClosesWorkspace() {
        let suiteName = "LastSurfaceCloseShortcutSettingsTests.Enabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: LastSurfaceCloseShortcutSettings.key)
        XCTAssertTrue(LastSurfaceCloseShortcutSettings.closesWorkspace(defaults: defaults))
    }

    func testStoredFalseKeepsWorkspaceOpen() {
        let suiteName = "LastSurfaceCloseShortcutSettingsTests.Disabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: LastSurfaceCloseShortcutSettings.key)
        XCTAssertFalse(LastSurfaceCloseShortcutSettings.closesWorkspace(defaults: defaults))
    }
}

final class QuitWarningSettingsTests: XCTestCase {
    func testDefaultWarnBeforeQuitIsEnabledWhenUnset() {
        let suiteName = "QuitWarningSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: QuitWarningSettings.warnBeforeQuitKey)

        XCTAssertTrue(QuitWarningSettings.isEnabled(defaults: defaults))
    }

    func testStoredPreferenceOverridesDefault() {
        let suiteName = "QuitWarningSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertFalse(QuitWarningSettings.isEnabled(defaults: defaults))

        defaults.set(true, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertTrue(QuitWarningSettings.isEnabled(defaults: defaults))
    }

    func testShouldShowConfirmationFollowsEnabledPreference() {
        let suiteName = "QuitWarningSettingsTests.ShouldShow.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertTrue(
            QuitWarningSettings.shouldShowConfirmation(
                isQuitWarningConfirmed: false,
                hasDirtyWorkspaces: true,
                buildFlavor: .stable,
                defaults: defaults
            )
        )

        XCTAssertFalse(
            QuitWarningSettings.shouldShowConfirmation(
                isQuitWarningConfirmed: true,
                hasDirtyWorkspaces: true,
                buildFlavor: .stable,
                defaults: defaults
            )
        )

        defaults.set(false, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertFalse(
            QuitWarningSettings.shouldShowConfirmation(
                isQuitWarningConfirmed: false,
                hasDirtyWorkspaces: true,
                buildFlavor: .stable,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            QuitWarningSettings.shouldShowConfirmation(
                isQuitWarningConfirmed: true,
                hasDirtyWorkspaces: true,
                buildFlavor: .stable,
                defaults: defaults
            )
        )
    }

    func testSetEnabledWritesConfirmQuitAndLegacyFallback() {
        let suiteName = "QuitWarningSettingsTests.SetEnabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        QuitWarningSettings.setEnabled(false, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: QuitWarningSettings.confirmQuitKey), QuitConfirmationMode.never.rawValue)
        XCTAssertEqual(defaults.object(forKey: QuitWarningSettings.warnBeforeQuitKey) as? Bool, false)
        XCTAssertEqual(QuitWarningSettings.confirmQuitMode(defaults: defaults), .never)

        QuitWarningSettings.setEnabled(true, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: QuitWarningSettings.confirmQuitKey), QuitConfirmationMode.always.rawValue)
        XCTAssertEqual(defaults.object(forKey: QuitWarningSettings.warnBeforeQuitKey) as? Bool, true)
        XCTAssertEqual(QuitWarningSettings.confirmQuitMode(defaults: defaults), .always)
    }
}

final class QuitConfirmationPolicyTests: XCTestCase {
    func testDevAlwaysSkipsQuitConfirmation() {
        withIsolatedDefaults { defaults in
            defaults.set(QuitConfirmationMode.always.rawValue, forKey: QuitWarningSettings.confirmQuitKey)
            XCTAssertFalse(
                QuitWarningSettings.shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    buildFlavor: .dev,
                    defaults: defaults
                )
            )

            defaults.set(QuitConfirmationMode.dirtyOnly.rawValue, forKey: QuitWarningSettings.confirmQuitKey)
            XCTAssertFalse(
                QuitWarningSettings.shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    buildFlavor: .dev,
                    defaults: defaults
                )
            )
        }
    }

    func testStableHonorsConfirmQuitModes() {
        withIsolatedDefaults { defaults in
            defaults.set(QuitConfirmationMode.always.rawValue, forKey: QuitWarningSettings.confirmQuitKey)
            XCTAssertTrue(
                QuitWarningSettings.shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: false,
                    buildFlavor: .stable,
                    defaults: defaults
                )
            )

            defaults.set(QuitConfirmationMode.dirtyOnly.rawValue, forKey: QuitWarningSettings.confirmQuitKey)
            XCTAssertFalse(
                QuitWarningSettings.shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: false,
                    buildFlavor: .stable,
                    defaults: defaults
                )
            )
            XCTAssertTrue(
                QuitWarningSettings.shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    buildFlavor: .stable,
                    defaults: defaults
                )
            )

            defaults.set(QuitConfirmationMode.never.rawValue, forKey: QuitWarningSettings.confirmQuitKey)
            XCTAssertFalse(
                QuitWarningSettings.shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    buildFlavor: .stable,
                    defaults: defaults
                )
            )
        }
    }

    func testNightlyHonorsConfirmQuitModes() {
        withIsolatedDefaults { defaults in
            defaults.set(QuitConfirmationMode.dirtyOnly.rawValue, forKey: QuitWarningSettings.confirmQuitKey)
            XCTAssertFalse(
                QuitWarningSettings.shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: false,
                    buildFlavor: .nightly,
                    defaults: defaults
                )
            )
            XCTAssertTrue(
                QuitWarningSettings.shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    buildFlavor: .nightly,
                    defaults: defaults
                )
            )
        }
    }

    func testLegacyWarnBeforeQuitMapsWhenConfirmQuitUnset() {
        withIsolatedDefaults { defaults in
            defaults.set(false, forKey: QuitWarningSettings.warnBeforeQuitKey)
            XCTAssertEqual(QuitWarningSettings.confirmQuitMode(defaults: defaults), .never)

            defaults.set(true, forKey: QuitWarningSettings.warnBeforeQuitKey)
            XCTAssertEqual(QuitWarningSettings.confirmQuitMode(defaults: defaults), .always)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "QuitConfirmationPolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}


