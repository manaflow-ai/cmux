import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testRightSidebarHelpOmitsBetaModesUntilEnabled() throws {
        let cliPath = try bundledCLIPath()
        let bundleIdentifier = "com.cmuxterm.app.debug.cli.help.\(UUID().uuidString.lowercased())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: bundleIdentifier))
        defer { defaults.removePersistentDomain(forName: bundleIdentifier) }
        defaults.set(false, forKey: "rightSidebar.beta.notes.enabled")
        defaults.set(false, forKey: "rightSidebar.beta.feed.enabled")
        defaults.set(false, forKey: "rightSidebar.beta.dock.enabled")
        defaults.synchronize()

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_BUNDLE_ID"] = bundleIdentifier

        let disabledResult = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "--help"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(disabledResult.timedOut, disabledResult.stdout)
        XCTAssertEqual(disabledResult.status, 0, disabledResult.stdout)
        XCTAssertTrue(disabledResult.stdout.contains("set <files|find|vault|sessions>"), disabledResult.stdout)
        XCTAssertFalse(disabledResult.stdout.contains("notes"), disabledResult.stdout)
        XCTAssertFalse(disabledResult.stdout.contains("feed"), disabledResult.stdout)
        XCTAssertFalse(disabledResult.stdout.contains("dock"), disabledResult.stdout)

        let disabledTopLevelResult = runProcess(
            executablePath: cliPath,
            arguments: ["--help"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(disabledTopLevelResult.timedOut, disabledTopLevelResult.stdout)
        XCTAssertEqual(disabledTopLevelResult.status, 0, disabledTopLevelResult.stdout)
        XCTAssertTrue(
            disabledTopLevelResult.stdout.contains("right-sidebar <toggle|show|hide|focus|set|mode|files|find|vault|sessions>"),
            disabledTopLevelResult.stdout
        )
        XCTAssertFalse(disabledTopLevelResult.stdout.contains("note new ["), disabledTopLevelResult.stdout)

        for mode in ["notes", "feed", "dock"] {
            let disabledSetResult = runProcess(
                executablePath: cliPath,
                arguments: ["right-sidebar", "set", mode],
                environment: environment,
                timeout: 5
            )
            XCTAssertFalse(disabledSetResult.timedOut, disabledSetResult.stdout)
            XCTAssertNotEqual(disabledSetResult.status, 0, disabledSetResult.stdout)
            XCTAssertTrue(disabledSetResult.stdout.contains("Unknown right-sidebar mode '\(mode)'"), disabledSetResult.stdout)

            let disabledAliasResult = runProcess(
                executablePath: cliPath,
                arguments: ["right-sidebar", mode],
                environment: environment,
                timeout: 5
            )
            XCTAssertFalse(disabledAliasResult.timedOut, disabledAliasResult.stdout)
            XCTAssertNotEqual(disabledAliasResult.status, 0, disabledAliasResult.stdout)
            XCTAssertTrue(disabledAliasResult.stdout.contains("Unknown right-sidebar command '\(mode)'"), disabledAliasResult.stdout)
        }

        defaults.set(true, forKey: "rightSidebar.beta.notes.enabled")
        defaults.synchronize()

        let enabledResult = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "--help"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(enabledResult.timedOut, enabledResult.stdout)
        XCTAssertEqual(enabledResult.status, 0, enabledResult.stdout)
        XCTAssertTrue(enabledResult.stdout.contains("set <files|find|vault|sessions|notes>"), enabledResult.stdout)
        XCTAssertFalse(enabledResult.stdout.contains("feed"), enabledResult.stdout)
        XCTAssertFalse(enabledResult.stdout.contains("dock"), enabledResult.stdout)

        let enabledTopLevelResult = runProcess(
            executablePath: cliPath,
            arguments: ["--help"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(enabledTopLevelResult.timedOut, enabledTopLevelResult.stdout)
        XCTAssertEqual(enabledTopLevelResult.status, 0, enabledTopLevelResult.stdout)
        XCTAssertTrue(
            enabledTopLevelResult.stdout.contains("right-sidebar <toggle|show|hide|focus|set|mode|files|find|vault|sessions|notes>"),
            enabledTopLevelResult.stdout
        )
        XCTAssertTrue(enabledTopLevelResult.stdout.contains("note new ["), enabledTopLevelResult.stdout)
    }

}
