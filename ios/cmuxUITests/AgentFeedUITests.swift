import XCTest

final class AgentFeedUITests: XCTestCase {
    @MainActor
    func testAgentFeedPermissionResolutionAndExactNavigation() throws {
        let app = launchFixture()
        defer { app.terminate() }

        XCTAssertTrue(app.descendants(matching: .any)["MobileAgentFeed"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.tabBars.buttons["Feed"].isSelected)

        let permissionCard = app.descendants(matching: .any)[
            "MobileAgentFeedCard-macbook-00000000-0000-0000-0000-000000000101"
        ]
        XCTAssertTrue(permissionCard.waitForExistence(timeout: 3))
        let permissionExpand = app.buttons[
            "MobileAgentFeedExpand-macbook-00000000-0000-0000-0000-000000000101"
        ]
        makeHittable(permissionExpand, in: app)
        permissionExpand.tap()
        let allowOnce = app.buttons[
            "MobileAgentFeedPermission-once-macbook-00000000-0000-0000-0000-000000000101"
        ]
        XCTAssertTrue(allowOnce.waitForExistence(timeout: 3))
        allowOnce.tap()
        XCTAssertTrue(permissionCard.waitForNonExistence(timeout: 3))

        let planOpen = app.buttons[
            "MobileAgentFeedOpenAgent-mac-studio-00000000-0000-0000-0000-000000000102"
        ]
        XCTAssertTrue(planOpen.waitForExistence(timeout: 3))
        makeHittable(planOpen, in: app)
        planOpen.tap()
        let destination = app.descendants(matching: .any)["MobileAgentFeedPreviewAgentDestination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["MobileAgentFeed"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["Feed"].isSelected)
    }

    @MainActor
    func testAgentFeedMultiQuestionRequiresEveryAnswerAndSupportsOther() throws {
        let app = launchFixture()
        defer { app.terminate() }

        let suffix = "mac-3-00000000-0000-0000-0000-000000000103"
        let expand = app.buttons["MobileAgentFeedExpand-\(suffix)"]
        XCTAssertTrue(expand.waitForExistence(timeout: 8))
        makeHittable(expand, in: app)
        expand.tap()

        let submit = app.buttons["MobileAgentFeedQuestionSubmit-\(suffix)"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        XCTAssertFalse(submit.isEnabled)
        app.buttons["MobileAgentFeedQuestion-scope-iphone-\(suffix)"].tap()
        XCTAssertFalse(submit.isEnabled)
        let other = app.textFields["MobileAgentFeedQuestionOther-priority-\(suffix)"]
        XCTAssertTrue(other.waitForExistence(timeout: 3))
        other.tap()
        other.typeText("Oldest blocked request")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["MobileAgentFeedCard-\(suffix)"].waitForNonExistence(timeout: 3))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "agent-feed-multi-question-resolved"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAgentFeedDeterministicStressAndOfflineScenarios() throws {
        var app = launchFixture(scenario: "stress")
        var marker = app.descendants(matching: .any)["AgentFeedScenario-stress"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertTrue(marker.value as? String == "host events 2400, rendered items 2000")
        app.terminate()

        app = launchFixture(scenario: "offline")
        marker = app.descendants(matching: .any)["AgentFeedScenario-offline"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["MobileAgentFeedStatusOffline"].exists)
        let expand = app.buttons["MobileAgentFeedExpand-macbook-00000000-0000-0000-0000-000000000107"]
        makeHittable(expand, in: app)
        expand.tap()
        let action = app.buttons["MobileAgentFeedPermission-once-macbook-00000000-0000-0000-0000-000000000107"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertFalse(action.isEnabled)
        app.terminate()
    }

    @MainActor
    private func launchFixture(scenario: String = "mixed") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UITEST_AGENT_FEED_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_AGENT_FEED_SCENARIO"] = scenario
        app.launch()
        return app
    }

    @MainActor
    private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}
