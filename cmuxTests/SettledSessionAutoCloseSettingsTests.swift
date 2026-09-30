import XCTest

final class SettledSessionAutoCloseSettingsTests: XCTestCase {
    func testSettledAutoCloseDefaultsOffAndSanitizesIdleHours() {
        let defaults = UserDefaults(suiteName: "SettledSessionAutoCloseSettingsTests")!
        defaults.removePersistentDomain(forName: "SettledSessionAutoCloseSettingsTests")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: "SettledSessionAutoCloseSettingsTests")
        }
        XCTAssertFalse(AgentHibernationSettings.settledAutoCloseEnabled(defaults: defaults))
        XCTAssertEqual(AgentHibernationSettings.settledAutoCloseIdleHours(defaults: defaults), 2)

        defaults.set(true, forKey: AgentHibernationSettings.settledAutoCloseEnabledKey)
        defaults.set(0, forKey: AgentHibernationSettings.settledAutoCloseIdleHoursKey)
        XCTAssertTrue(AgentHibernationSettings.settledAutoCloseEnabled(defaults: defaults))
        XCTAssertEqual(AgentHibernationSettings.settledAutoCloseIdleHours(defaults: defaults), 2)

        defaults.set(999, forKey: AgentHibernationSettings.settledAutoCloseIdleHoursKey)
        XCTAssertEqual(AgentHibernationSettings.settledAutoCloseIdleHours(defaults: defaults), 168)
    }
}
