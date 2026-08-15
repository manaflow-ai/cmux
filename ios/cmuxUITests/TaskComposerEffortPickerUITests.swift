import XCTest

final class TaskComposerEffortPickerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEffortPickerFollowsModelPicker() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
        ]
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_TASK_COMPOSER_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_TASK_MODEL_CATALOG_JSON"] = #"{"schemaVersion":1,"updatedAt":"2026-08-14T00:00:00Z","providers":{"claude":{"defaultModel":"claude-opus","models":[{"id":"claude-opus","label":"Opus","efforts":[{"value":"medium","label":"Medium"}],"defaultEffort":"medium"}]}}}"#
        app.launch()
        defer { app.terminate() }

        let model = app.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(model.waitForExistence(timeout: 8))
        model.tap()
        let modelChoice = app.buttons["Opus"]
        XCTAssertTrue(modelChoice.waitForExistence(timeout: 3))
        modelChoice.tap()

        let effort = app.buttons["MobileTaskComposerEffortPill"]
        XCTAssertTrue(
            effort.waitForExistence(timeout: 3),
            "The native composer must show an effort picker after the model picker"
        )
        XCTAssertEqual(effort.value as? String, "Medium")
        XCTAssertLessThan(model.frame.midX, effort.frame.midX)
        XCTAssertLessThan(
            effort.frame.midX,
            app.buttons["MobileTaskComposerSubmitButton"].frame.midX
        )
    }
}
