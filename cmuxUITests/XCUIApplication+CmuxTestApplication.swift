import XCTest

extension XCUIApplication {
    static func cmuxTestApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment["CMUX_UI_TEST_PROCESS"] = "1"
        return application
    }
}
