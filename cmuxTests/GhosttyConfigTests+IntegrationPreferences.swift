@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Agent integration and telemetry preferences
extension GhosttyConfigTests {
    func testClaudeCodeIntegrationDefaultsToEnabledWhenUnset() {
        let suiteName = "cmux.tests.claude-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertTrue(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))
    }

    func testClaudeCodeIntegrationRespectsStoredPreference() {
        let suiteName = "cmux.tests.claude-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertTrue(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))

        defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertFalse(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))
    }

    func testKiroIntegrationDefaultsToEnabledWithStandardNotificationsWhenUnset() {
        let suiteName = "cmux.tests.kiro-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: KiroIntegrationSettings.hooksEnabledKey)
        defaults.removeObject(forKey: KiroIntegrationSettings.notificationLevelKey)
        XCTAssertTrue(KiroIntegrationSettings.hooksEnabled(defaults: defaults))
        XCTAssertEqual(KiroIntegrationSettings.notificationLevel(defaults: defaults), .standard)
    }

    func testKiroIntegrationRespectsStoredPreferenceAndNotificationLevel() {
        let suiteName = "cmux.tests.kiro-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: KiroIntegrationSettings.hooksEnabledKey)
        defaults.set(KiroIntegrationSettings.NotificationLevel.verbose.rawValue, forKey: KiroIntegrationSettings.notificationLevelKey)
        XCTAssertFalse(KiroIntegrationSettings.hooksEnabled(defaults: defaults))
        XCTAssertEqual(KiroIntegrationSettings.notificationLevel(defaults: defaults), .verbose)

        defaults.set("unsupported", forKey: KiroIntegrationSettings.notificationLevelKey)
        XCTAssertEqual(KiroIntegrationSettings.notificationLevel(defaults: defaults), .standard)
    }

    func testSubagentNotificationSuppressionDefaultsToEnabledWhenUnset() {
        let suiteName = "cmux.tests.subagent-notifications.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
        XCTAssertTrue(AgentSubagentNotificationSettings.suppressNotifications(defaults: defaults))
    }

    func testSubagentNotificationSuppressionRespectsStoredPreference() {
        let suiteName = "cmux.tests.subagent-notifications.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
        XCTAssertTrue(AgentSubagentNotificationSettings.suppressNotifications(defaults: defaults))

        defaults.set(false, forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
        XCTAssertFalse(AgentSubagentNotificationSettings.suppressNotifications(defaults: defaults))
    }

    func testTelemetryDefaultsToEnabledWhenUnset() {
        let suiteName = "cmux.tests.telemetry.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: TelemetrySettings.sendAnonymousTelemetryKey)
        XCTAssertTrue(TelemetrySettings.isEnabled(defaults: defaults))
    }

    func testTelemetryRespectsStoredPreference() {
        let suiteName = "cmux.tests.telemetry.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: TelemetrySettings.sendAnonymousTelemetryKey)
        XCTAssertTrue(TelemetrySettings.isEnabled(defaults: defaults))

        defaults.set(false, forKey: TelemetrySettings.sendAnonymousTelemetryKey)
        XCTAssertFalse(TelemetrySettings.isEnabled(defaults: defaults))
    }

}
