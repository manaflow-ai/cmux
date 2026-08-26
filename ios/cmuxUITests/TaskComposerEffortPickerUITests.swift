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
        app.launchEnvironment["CMUX_UITEST_TASK_MODEL_CATALOG_JSON"] = #"{"schemaVersion":1,"updatedAt":"2026-08-14T00:00:00Z","providers":{"claude":{"defaultModel":"claude-opus","models":[{"id":"claude-opus","label":"Claude Opus 4.8","efforts":[{"value":"low","label":"Low"},{"value":"medium","label":"Medium"},{"value":"high","label":"High"}],"defaultEffort":"medium"}]}}}"#
        app.launch()
        defer { app.terminate() }

        let scroller = app.scrollViews["MobileTaskComposerPillScroller"]
        XCTAssertTrue(scroller.waitForExistence(timeout: 8))

        let agent = scroller.buttons["MobileTaskComposerAgentPill"]
        let model = scroller.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(model.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(
            agent.frame.width,
            80,
            "The provider pill must retain enough width to show its label"
        )
        XCTAssertEqual(agent.value as? String, "Claude")
        XCTAssertGreaterThan(
            model.frame.width,
            100,
            "The model pill must retain enough width to show its selected model"
        )
        // XCUI reports the visible intersection of a scroll-view descendant,
        // so the model's frame can be narrower than its intrinsic pill while
        // the trailing portion waits offscreen. Its full selected value must
        // remain exposed, and the visible portion must not collapse to an icon.
        XCTAssertEqual(model.value as? String, "Claude Opus 4.8")
        model.tap()
        let modelChoice = app.buttons["Claude Opus 4.8"]
        XCTAssertTrue(modelChoice.waitForExistence(timeout: 3))
        modelChoice.tap()

        let effort = scroller.buttons["MobileTaskComposerEffortPill"]
        XCTAssertTrue(
            effort.waitForExistence(timeout: 3),
            "Effort must share the provider and model horizontal scroller"
        )
        XCTAssertEqual(effort.value as? String, "Medium")
        XCTAssertLessThan(model.frame.midX, effort.frame.midX)
        let effortMidXBeforeScroll = effort.frame.midX
        scroller.swipeLeft()
        XCTAssertLessThan(
            effort.frame.midX,
            effortMidXBeforeScroll,
            "Effort must move with the shared picker scroller"
        )

        effort.tap()
        for choice in ["Low", "Medium", "High"] {
            XCTAssertTrue(
                app.buttons[choice].waitForExistence(timeout: 3),
                "The selected model must expose its exact effort choice: \(choice)"
            )
        }
    }

    @MainActor
    func testDefaultModelUsesProviderDefaultEfforts() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
        ]
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_TASK_COMPOSER_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_TASK_MODEL_CATALOG_JSON"] = #"{"schemaVersion":1,"updatedAt":"2026-08-14T00:00:00Z","providers":{"claude":{"defaultModel":"claude-opus","models":[{"id":"claude-opus","label":"Claude Opus 4.8","efforts":[{"value":"low","label":"Low"},{"value":"medium","label":"Medium"},{"value":"high","label":"High"}],"defaultEffort":"medium"}]}}}"#
        app.launch()
        defer { app.terminate() }

        let scroller = app.scrollViews["MobileTaskComposerPillScroller"]
        XCTAssertTrue(scroller.waitForExistence(timeout: 8))
        let effort = scroller.buttons["MobileTaskComposerEffortPill"]
        XCTAssertTrue(
            effort.waitForExistence(timeout: 3),
            "Default model must expose efforts from the provider default model"
        )
        XCTAssertEqual(effort.value as? String, "Medium")

        effort.tap()
        for choice in ["Low", "Medium", "High"] {
            XCTAssertTrue(
                app.buttons[choice].waitForExistence(timeout: 3),
                "The provider default model must expose its exact effort choice: \(choice)"
            )
        }
    }
}
