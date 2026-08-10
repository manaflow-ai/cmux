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
        let permissionExpandID = "MobileAgentFeedExpand-macbook-00000000-0000-0000-0000-000000000101"
        let permissionExpand = app.buttons[permissionExpandID]
        XCTAssertEqual(app.buttons.matching(identifier: permissionExpandID).count, 1)
        makeHittable(permissionExpand, in: app)
        permissionExpand.tap()
        let denyID = "MobileAgentFeedPermission-deny-macbook-00000000-0000-0000-0000-000000000101"
        let deny = app.buttons[denyID]
        XCTAssertEqual(app.buttons.matching(identifier: denyID).count, 1)
        XCTAssertTrue(deny.waitForExistence(timeout: 3))
        XCTAssertTrue(deny.isHittable)
        deny.tap()
        XCTAssertTrue(permissionCard.waitForExistence(timeout: 3))
        let resolvedExpand = app.buttons[permissionExpandID]
        XCTAssertEqual(app.buttons.matching(identifier: permissionExpandID).count, 1)
        XCTAssertTrue(resolvedExpand.label.contains("Resolved: Deny"))
        XCTAssertFalse(app.descendants(matching: .any)["MobileAgentFeedPreviewAgentDestination"].exists)

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
        let expandID = "MobileAgentFeedExpand-\(suffix)"
        let expand = app.buttons[expandID]
        XCTAssertEqual(app.buttons.matching(identifier: expandID).count, 1)
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
        XCTAssertTrue(marker.value as? String == "2400/2000")
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
    func testAgentFeedJapaneseLocalizationAndAccessibilityLayout() throws {
        var app = launchFixture(scenario: "japanese", language: "ja", locale: "ja_JP")
        XCTAssertTrue(app.navigationBars["フィード"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.tabBars.buttons["フィード"].isSelected)
        XCTAssertTrue(app.staticTexts["入力が必要"].exists)
        XCTAssertTrue(app.staticTexts["Codexが権限をリクエストしています"].exists)
        XCTAssertTrue(app.buttons["エージェントを開く"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'japanese' OR label CONTAINS 'host='")).firstMatch.exists)
        app.terminate()

        app = launchFixture(scenario: "accessibility")
        let source = app.staticTexts["Codex"]
        let status = app.staticTexts["Needs input"]
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertTrue(status.exists)
        XCTAssertEqual(source.label, "Codex")
        XCTAssertEqual(status.label, "Needs input")
        let filter = app.descendants(matching: .any)["MobileAgentFeedFilter"]
        XCTAssertTrue(filter.exists)
        XCTAssertTrue(filter.isHittable)
        let suffix = "macbook-00000000-0000-0000-0000-000000000101"
        let expandID = "MobileAgentFeedExpand-\(suffix)"
        let expand = app.buttons[expandID]
        XCTAssertEqual(app.buttons.matching(identifier: expandID).count, 1)
        XCTAssertTrue(expand.exists)
        XCTAssertTrue(expand.isHittable)
        expand.tap()
        let denyID = "MobileAgentFeedPermission-deny-\(suffix)"
        let deny = app.buttons[denyID]
        XCTAssertEqual(app.buttons.matching(identifier: denyID).count, 1)
        XCTAssertTrue(deny.waitForExistence(timeout: 3))
        makeHittable(deny, in: app)
        deny.tap()
        let resolvedExpand = app.buttons[expandID]
        XCTAssertEqual(app.buttons.matching(identifier: expandID).count, 1)
        XCTAssertTrue(resolvedExpand.label.contains("Resolved: Deny"))
        XCTAssertFalse(app.descendants(matching: .any)["MobileAgentFeedPreviewAgentDestination"].exists)
        app.terminate()
    }

    @MainActor
    private func launchFixture(
        scenario: String = "mixed",
        language: String = "en",
        locale: String = "en_US"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
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
