import XCTest

extension XCUIApplication {
    static func cmuxTestApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment["CMUX_UI_TEST_PROCESS"] = "1"
        return application
    }

    /// Launches a socket-driven test app without treating a headless runner's
    /// background activation as a launch failure.
    ///
    /// XCUITest can report a failure from `launch()` after the process starts
    /// successfully but remains in `.runningBackground`. Socket-driven suites
    /// can continue in that state, so record that one runner limitation as an
    /// expected failure while still failing if no app process is running.
    func launchAllowingHeadlessBackgroundActivation() {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            guard issue.type == .assertionFailure || issue.type == .system else { return false }

            let description = [
                issue.compactDescription,
                issue.detailedDescription ?? "",
                issue.associatedError?.localizedDescription ?? "",
            ].joined(separator: "\n")

            return description.contains("Failed to activate application") &&
                description.contains("Running Background")
        }
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            launch()
        }

        guard state == .runningForeground || state == .runningBackground else {
            XCTFail("App failed to start. state=\(state.rawValue)")
            return
        }
    }
}
