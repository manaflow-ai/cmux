import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class UntrackedAgentSessionWarningSettingsTests: XCTestCase {
    func testDefaultsKeyAndNotificationOnFlip() throws {
        let suiteName = "cmux-untracked-agent-session-warning-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            UntrackedAgentSessionWarningSettings.warnUntrackedAgentSessionKey,
            "terminal.warnUntrackedAgentSession"
        )
        // Default is on (warn by default).
        XCTAssertTrue(UntrackedAgentSessionWarningSettings.isEnabled(defaults: defaults))

        let notificationCenter = NotificationCenter()
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: UntrackedAgentSessionWarningSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        UntrackedAgentSessionWarningSettings.setEnabled(
            false,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertFalse(UntrackedAgentSessionWarningSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(notificationCount, 1)

        // Setting the same value again does not re-notify.
        UntrackedAgentSessionWarningSettings.setEnabled(
            false,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(notificationCount, 1)

        // Reset restores the default (on) and notifies once.
        UntrackedAgentSessionWarningSettings.reset(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertTrue(UntrackedAgentSessionWarningSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(notificationCount, 2)
    }
}
