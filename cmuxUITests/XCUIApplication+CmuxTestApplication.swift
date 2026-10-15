import XCTest

extension XCUIApplication {
    static func cmuxTestApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment["CMUX_UI_TEST_PROCESS"] = "1"
        if let engine = uiTestBrowserEngine(from: ProcessInfo.processInfo.environment) {
            application.launchEnvironment["CMUX_BROWSER_ENGINE"] = engine
        }
        return application
    }

    /// The browser engine a test-e2e.yml run selected (`browser_engine` input,
    /// handed to the runner as `CMUX_UI_TEST_BROWSER_ENGINE`), so the same UI
    /// test class runs once per engine. Nil keeps the app's configured engine.
    static func uiTestBrowserEngine(from environment: [String: String]) -> String? {
        switch environment["CMUX_UI_TEST_BROWSER_ENGINE"]?.lowercased() {
        case "webkit": return "webkit"
        case "chromium": return "chromium"
        default: return nil
        }
    }
}
