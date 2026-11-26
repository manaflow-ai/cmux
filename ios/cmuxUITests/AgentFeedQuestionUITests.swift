import XCTest

final class AgentFeedQuestionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAgentFeedDecisionPreviewAnswersAndScrolls() {
        let app = launchPreview()
        defer { app.terminate() }

        let questionRow = app.descendants(matching: .any)["MobileAgentFeedRow-question-preview"]
        XCTAssertTrue(questionRow.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["MobileAgentFeedRow-empty-assistant"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["MobileAgentFeedRow-empty-stop"].exists)

        capture(app, "01-pending-feed")
        app.buttons["MobileAgentFeedQuestionAnswer"].tap()
        let submit = app.buttons["MobileAgentFeedQuestionSubmit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        capture(app, "02-unanswered-sheet")
        let production = app.buttons["MobileAgentFeedQuestionOption-deploy-production"]
        production.tap()
        capture(app, "03-single-selection")

        let build = app.buttons["MobileAgentFeedQuestionOption-events-build"]
        let deploy = app.buttons["MobileAgentFeedQuestionOption-events-deploy"]
        for _ in 0..<5 where !deploy.isHittable { app.swipeUp() }
        build.tap()
        deploy.tap()
        XCTAssertTrue(build.isSelected)
        XCTAssertTrue(deploy.isSelected)
        XCTAssertGreaterThanOrEqual(deploy.frame.minY - build.frame.maxY, 6)
        XCTAssertTrue(submit.isEnabled)
        let selectedProof = XCTAttachment(screenshot: app.screenshot())
        selectedProof.name = "feed-separated-multi-select-choices"
        selectedProof.lifetime = .keepAlways
        add(selectedProof)

        let customAnswer = app.descendants(matching: .any)["MobileAgentFeedQuestionText-events"]
        for _ in 0..<5 where !customAnswer.isHittable { app.swipeUp() }
        customAnswer.tap()
        dismissKeyboardTutorial(in: app)
        XCTAssertTrue(app.buttons["MobileAgentFeedQuestionOther-events"].isSelected)
        XCTAssertFalse(build.isSelected)
        XCTAssertFalse(deploy.isSelected)
        XCTAssertFalse(submit.isEnabled)
        customAnswer.typeText("Only failure notifications")
        XCTAssertTrue(submit.isEnabled)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        assertAnswerCardClearsKeyboard(in: app, questionID: "events")
        capture(app, "05-custom-answer-focused")

        for _ in 0..<5 where !build.isHittable { app.swipeDown() }
        build.tap()
        XCTAssertFalse(app.buttons["MobileAgentFeedQuestionOther-events"].isSelected)
        XCTAssertTrue(build.isSelected)
        let customChoice = app.buttons["MobileAgentFeedQuestionOther-events"]
        for _ in 0..<5 where !customChoice.isHittable { app.swipeUp() }
        customChoice.tap()
        XCTAssertEqual(customAnswer.value as? String, "Only failure notifications")
        XCTAssertFalse(build.isSelected)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let answered = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Only failure notifications")
        ).firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 3))
        XCTAssertFalse(submit.exists)
        capture(app, "07-submitted-feed")

        let allow = app.buttons["MobileAgentFeedPermissionAllow"]
        let always = app.buttons["MobileAgentFeedPermissionAlways"]
        let more = app.buttons["MobileAgentFeedPermissionMore"]
        for _ in 0..<10 where !allow.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        XCTAssertTrue(always.exists)
        XCTAssertTrue(more.exists)
        XCTAssertTrue(more.isHittable)
        XCTAssertEqual(allow.frame.width, more.frame.width, accuracy: 6)
        XCTAssertEqual(allow.frame.height, more.frame.height, accuracy: 6)
        allow.tap()
        XCTAssertTrue(app.staticTexts["Allowed once"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["MobileAgentFeedDecisionResult"].exists)

        for _ in 0..<8 { app.swipeDown() }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "feed-decision-controls-and-scroll"
        proof.lifetime = .keepAlways
        add(proof)
    }

    @MainActor
    func testAgentFeedCustomAnswerGrowsToFourLines() {
        let app = launchPreview()
        defer { app.terminate() }
        let answer = app.buttons["MobileAgentFeedQuestionAnswer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        answer.tap()
        let field = app.descendants(matching: .any)["MobileAgentFeedQuestionText-deploy"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let singleLineHeight = field.frame.height
        app.buttons["MobileAgentFeedQuestionOther-deploy"].tap()
        dismissKeyboardTutorial(in: app)
        field.typeText("Deploy to staging first.\nRun the smoke tests.\nCheck error rates.\nRoll out gradually.")
        let expanded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in field.frame.height > singleLineHeight * 2 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed)
        let fourLineHeight = field.frame.height
        field.typeText("\nKeep monitoring.\nPause if errors rise.")
        XCTAssertEqual(field.frame.height, fourLineHeight, accuracy: 2)
        XCTAssertTrue((field.value as? String)?.contains("Pause if errors rise.") == true)
        capture(app, "feed-custom-answer-four-line-scroll-limit")
        assertAnswerCardClearsKeyboard(in: app, questionID: "deploy")
    }

    @MainActor
    func testSingleQuestionUsesSingularCount() {
        let app = launchPreview(environment: ["CMUX_UITEST_FEED_QUESTION_MARKDOWN_PREVIEW": "1"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["MobileAgentFeedQuestionAnswer"].waitForExistence(timeout: 10))
        capture(app, "single-question-count")
        XCTAssertTrue(app.staticTexts["1 question"].exists)
        XCTAssertFalse(app.staticTexts["1 questions"].exists)
    }

    @MainActor
    func testQuestionMarkdownRendersInline() {
        let app = launchPreview(environment: ["CMUX_UITEST_FEED_QUESTION_MARKDOWN_PREVIEW": "1"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["MobileAgentFeedQuestionAnswer"].waitForExistence(timeout: 10))
        let prompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Where should")).firstMatch
        XCTAssertFalse(prompt.label.contains("**"), "The Feed preview must render emphasis")
        app.buttons["MobileAgentFeedQuestionAnswer"].tap()
        let production = app.buttons["MobileAgentFeedQuestionOption-deploy-production"]
        XCTAssertTrue(production.waitForExistence(timeout: 5))
        XCTAssertFalse(production.label.contains("**"))
        XCTAssertFalse(production.label.contains("`"))
        let sheetPrompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Where should")).firstMatch
        XCTAssertFalse(sheetPrompt.label.contains("**"))
        production.tap()
        capture(app, "08-markdown-ready-to-submit")
    }

    @MainActor
    func testQuestionSelectionsInLightAppearance() {
        let app = launchPreview(environment: ["CMUX_UITEST_FEED_DECISION_PREVIEW_LIGHT": "1"])
        defer { app.terminate() }
        let answer = app.buttons["MobileAgentFeedQuestionAnswer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        capture(app, "09-light-feed")
        answer.tap()
        app.buttons["MobileAgentFeedQuestionOption-deploy-staging"].tap()
        let build = app.buttons["MobileAgentFeedQuestionOption-events-build"]
        let deploy = app.buttons["MobileAgentFeedQuestionOption-events-deploy"]
        for _ in 0..<5 where !deploy.isHittable { app.swipeUp() }
        build.tap()
        deploy.tap()
        XCTAssertTrue(build.isSelected)
        XCTAssertTrue(deploy.isSelected)
        XCTAssertTrue(app.buttons["MobileAgentFeedQuestionSubmit"].isEnabled)
        capture(app, "10-light-multi-select")
    }

    @MainActor
    private func launchPreview(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_FEED_DECISION_PREVIEW"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    @MainActor
    private func assertAnswerCardClearsKeyboard(in app: XCUIApplication, questionID: String) {
        let card = app.otherElements["MobileAgentFeedQuestionCard-\(questionID)"]
        let keyboard = app.keyboards.firstMatch
        let predictions = app.otherElements["Typing Predictions"].firstMatch
        let clearsKeyboard = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let keyboardTop = predictions.exists && !predictions.frame.isEmpty
                    ? min(keyboard.frame.minY, predictions.frame.minY)
                    : keyboard.frame.minY
                return card.frame.maxY <= keyboardTop - 8
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [clearsKeyboard], timeout: 3)
        let predictionFrame = predictions.exists ? "\(predictions.frame)" : "none"
        let geometry = XCTAttachment(string:
            "card: \(card.frame), keyboard: \(keyboard.frame), predictions: \(predictionFrame)"
        )
        geometry.name = "custom-answer-keyboard-clearance-\(questionID)"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertEqual(result, .completed, "The entire custom answer must clear the prediction bar")
    }

    @MainActor
    private func dismissKeyboardTutorial(in app: XCUIApplication) {
        // A fresh simulator can cover the field with the system's slide-to-type
        // tutorial. This preview has no app-owned Continue button.
        let tutorialContinue = app.buttons["Continue"].firstMatch
        if tutorialContinue.waitForExistence(timeout: 2) {
            tutorialContinue.tap()
            XCTAssertTrue(tutorialContinue.waitForNonExistence(timeout: 3))
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.otherElements["NotificationShortLookView"]
        if banner.exists {
            banner.swipeUp()
            XCTAssertTrue(banner.waitForNonExistence(timeout: 3))
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
