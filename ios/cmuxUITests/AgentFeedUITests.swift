import XCTest

final class AgentFeedUITests: XCTestCase {
    @MainActor
    func testAgentFeedPermissionResolutionAndExactNavigation() throws {
        var app = launchFixture(scenario: "permission")
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
        let denyID = "MobileAgentFeedPermission-deny-macbook-00000000-0000-0000-0000-000000000101"
        let deny = app.buttons[denyID]
        XCTAssertEqual(app.buttons.matching(identifier: denyID).count, 1)
        XCTAssertTrue(deny.waitForExistence(timeout: 3))
        XCTAssertTrue(deny.isHittable)
        deny.tap()
        waitForExistence(permissionCard, expected: false)
        app.buttons["All Activity"].tap()
        XCTAssertTrue(permissionCard.waitForExistence(timeout: 3))
        let resolvedExpand = app.buttons[permissionExpandID]
        XCTAssertEqual(app.buttons.matching(identifier: permissionExpandID).count, 1)
        XCTAssertTrue(resolvedExpand.label.contains("Resolved: Deny"))
        XCTAssertFalse(app.buttons[denyID].exists)
        XCTAssertFalse(app.descendants(matching: .any)["MobileAgentFeedPreviewAgentDestination"].exists)

        app.terminate()
        app = launchFixture(scenario: "exact-navigation")
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
        let app = launchFixture(scenario: "questions")
        defer { app.terminate() }

        let suffix = "mac-3-00000000-0000-0000-0000-000000000103"
        let expandID = "MobileAgentFeedExpand-\(suffix)"
        let expand = app.buttons[expandID]
        XCTAssertEqual(app.buttons.matching(identifier: expandID).count, 1)
        XCTAssertTrue(expand.waitForExistence(timeout: 8))

        let submit = app.buttons["MobileAgentFeedQuestionSubmit-\(suffix)"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        waitForEnabled(submit, expected: false)
        app.buttons["MobileAgentFeedQuestion-scope-iphone-\(suffix)"].tap()
        waitForEnabled(submit, expected: false)
        let other = app.textFields["MobileAgentFeedQuestionOther-priority-\(suffix)"]
        XCTAssertTrue(other.waitForExistence(timeout: 3))
        other.tap()
        other.typeText("Oldest blocked request")
        waitForEnabled(submit, expected: true)
        submit.tap()
        waitForExistence(expand, expected: false)
        app.buttons["All Activity"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        let resolved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Resolved"),
            object: expand
        )
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 5), .completed)
        XCTAssertFalse(submit.exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "agent-feed-multi-question-resolved"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAgentFeedBurstPublishesRealFrameAndVisibilityMetrics() throws {
        let app = launchFixture(scenario: "new-activity")
        defer { app.terminate() }

        let metrics = app.descendants(matching: .any)["AgentFeedPerformanceMetrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 8))
        let inject = app.buttons["AgentFeedFixtureInjectNewActivity"]
        XCTAssertTrue(inject.exists)
        XCTAssertTrue(inject.isHittable)
        inject.tap()
        let complete = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "state=complete"),
            object: metrics
        )
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 20), .completed)
        let value = try XCTUnwrap(metrics.value as? String)
        print("AgentFeedPerformanceMetrics: \(value)")
        let fields: [String: String] = metricFields(value)
        let frames: Int = try XCTUnwrap(fields["frames"].flatMap { Int($0) }, value)
        let frameP95: Double = try XCTUnwrap(fields["frame_p95_ms"].flatMap { Double($0) }, value)
        let frameStalls: Int = try XCTUnwrap(fields["frame_ge250"].flatMap { Int($0) }, value)
        let visibility: Int = try XCTUnwrap(fields["visibility"].flatMap { Int($0) }, value)
        let visibilityP95: Double = try XCTUnwrap(fields["visibility_p95_ms"].flatMap { Double($0) }, value)
        let visibilityStalls: Int = try XCTUnwrap(fields["visibility_ge250"].flatMap { Int($0) }, value)

        XCTAssertGreaterThanOrEqual(frames, 60, value)
        XCTAssertEqual(visibility, 1, value)
        XCTAssertLessThanOrEqual(frameP95, 33, value)
        XCTAssertLessThanOrEqual(visibilityP95, 250, value)
        XCTAssertEqual(frameStalls, 0, value)
        XCTAssertEqual(visibilityStalls, 0, value)
    }

    @MainActor
    func testAgentFeedBurstPreservesOffTopViewportAndOffersJumpToNewest() throws {
        let app = launchFixture(scenario: "new-activity")
        defer { app.terminate() }

        let list = app.descendants(matching: .any)["MobileAgentFeedList"]
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        list.swipeUp()
        list.swipeUp()
        list.swipeUp()
        let newestID = "MobileAgentFeedExpand-mac-4-00000000-0000-0000-0000-000000000999"
        XCTAssertFalse(app.buttons[newestID].exists)

        let inject = app.buttons["AgentFeedFixtureInjectNewActivity"]
        XCTAssertTrue(inject.exists)
        inject.tap()
        let newActivity = app.buttons["MobileAgentFeedNewActivity"]
        XCTAssertTrue(newActivity.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons[newestID].exists)

        newActivity.tap()
        XCTAssertTrue(app.buttons[newestID].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAgentFeedDeterministicStressAndOfflineScenarios() throws {
        var app = launchFixture(scenario: "stress")
        var marker = app.descendants(matching: .any)["AgentFeedScenario-stress"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertEqual(marker.value as? String, "2400/300")
        for retainedCount in [600, 900, 1_200, 1_500, 1_800, 2_000] {
            let loadOlder = app.buttons["AgentFeedFixtureLoadOlder"]
            XCTAssertTrue(loadOlder.waitForExistence(timeout: 3))
            XCTAssertTrue(loadOlder.isHittable)
            loadOlder.tap()
            let pageLoaded = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "2400/\(retainedCount)"),
                object: marker
            )
            XCTAssertEqual(XCTWaiter.wait(for: [pageLoaded], timeout: 5), .completed)
        }
        XCTAssertFalse(app.buttons["AgentFeedFixtureLoadOlder"].exists)
        app.terminate()

        app = launchFixture(scenario: "offline")
        marker = app.descendants(matching: .any)["AgentFeedScenario-offline"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["MobileAgentFeedStatusOffline"].exists)
        let offlineLoadOlder = app.buttons["MobileAgentFeedLoadOlder"]
        XCTAssertTrue(offlineLoadOlder.exists)
        XCTAssertFalse(offlineLoadOlder.isEnabled)
        let expand = app.buttons["MobileAgentFeedExpand-macbook-00000000-0000-0000-0000-000000000107"]
        makeHittable(expand, in: app)
        let action = app.buttons["MobileAgentFeedPermission-once-macbook-00000000-0000-0000-0000-000000000107"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertFalse(action.isEnabled)
        app.terminate()

        app = launchFixture(scenario: "capability-gap")
        XCTAssertTrue(app.descendants(matching: .any)["MobileAgentFeedStatusUpdateMac"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["MobileAgentFeedLoadOlder"].exists)
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
        let japaneseExpand = app.buttons[
            "MobileAgentFeedExpand-macbook-00000000-0000-0000-0000-000000000111"
        ]
        XCTAssertTrue(japaneseExpand.label.contains("ワークスペースID: workspace-1"))
        XCTAssertTrue(japaneseExpand.label.contains("サーフェスID: surface-111"))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'japanese' OR label CONTAINS 'host='")).firstMatch.exists)
        app.terminate()

        app = launchFixture(scenario: "accessibility")
        let source = app.staticTexts["Codex"].firstMatch
        let status = app.staticTexts["Needs input"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertTrue(status.exists)
        XCTAssertEqual(source.label, "Codex")
        XCTAssertEqual(status.label, "Needs input")
        let filter = app.descendants(matching: .any)["MobileAgentFeedFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3))
        XCTAssertTrue(filter.isHittable)
        let suffix = "macbook-00000000-0000-0000-0000-000000000101"
        let expandID = "MobileAgentFeedExpand-\(suffix)"
        let expand = app.buttons[expandID]
        XCTAssertEqual(app.buttons.matching(identifier: expandID).count, 1)
        XCTAssertTrue(expand.exists)
        XCTAssertTrue(expand.isHittable)
        XCTAssertTrue(expand.label.contains("Workspace ID: workspace-1"))
        XCTAssertTrue(expand.label.contains("Surface ID: surface-101"))
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

        app = launchFixture(scenario: "malformed")
        let unavailable = app.buttons[
            "MobileAgentFeedExpand-macbook-00000000-0000-0000-0000-000000000109"
        ]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 8))
        XCTAssertTrue(unavailable.label.contains("Workspace ID: Unavailable"))
        XCTAssertTrue(unavailable.label.contains("Surface ID: Unavailable"))
        XCTAssertTrue(app.staticTexts["Agent location unavailable"].exists)
        app.terminate()
    }

    @MainActor
    func testAgentFeedFiveDesignsKeepNotificationsSeparateAndActionsInline() throws {
        for design in ["timeline", "cards", "compact", "conversation", "commandCenter"] {
            let app = launchFixture(scenario: "permission", design: design)
            XCTAssertTrue(
                app.descendants(matching: .any)["MobileAgentFeedDesign-\(design)"]
                    .waitForExistence(timeout: 8),
                design
            )
            XCTAssertTrue(app.tabBars.buttons["Feed"].isSelected, design)
            XCTAssertTrue(app.tabBars.buttons["Notifications"].exists, design)
            let inlineAction = app.buttons[
                "MobileAgentFeedPermission-deny-macbook-00000000-0000-0000-0000-000000000101"
            ]
            XCTAssertTrue(inlineAction.waitForExistence(timeout: 3), design)
            makeHittable(inlineAction, in: app)

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "agent-feed-design-\(design)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testAgentFeedPlanAndCompletedTurnCanBeAnsweredInline() throws {
        var app = launchFixture(scenario: "plan")
        let planSuffix = "mac-studio-00000000-0000-0000-0000-000000000102"
        let feedback = app.textFields["MobileAgentFeedPlanFeedback-\(planSuffix)"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 8))
        makeHittable(feedback, in: app)
        feedback.tap()
        feedback.typeText("Cover the reconnect case")
        let manual = app.buttons["MobileAgentFeedPlan-manual-\(planSuffix)"]
        makeHittable(manual, in: app)
        manual.tap()
        let planExpand = app.buttons["MobileAgentFeedExpand-\(planSuffix)"]
        waitForExistence(planExpand, expected: false)
        app.buttons["All Activity"].tap()
        XCTAssertTrue(planExpand.waitForExistence(timeout: 3))
        XCTAssertTrue(planExpand.label.contains("Resolved"))
        XCTAssertFalse(feedback.exists)
        app.terminate()

        app = launchFixture(scenario: "reply")
        let replySuffix = "mac-4-00000000-0000-0000-0000-000000000104"
        let composer = app.textFields["MobileAgentFeedReplyComposer-\(replySuffix)"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Needs input"].exists)
        composer.tap()
        composer.typeText("Please continue with the focused tests")
        let send = app.buttons["MobileAgentFeedReplySubmit-\(replySuffix)"]
        makeHittable(send, in: app)
        send.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["MobileAgentFeedSending-\(replySuffix)"]
                .waitForExistence(timeout: 3)
        )
        app.terminate()
    }

    @MainActor
    private func launchFixture(
        scenario: String = "mixed",
        language: String = "en",
        locale: String = "en_US",
        design: String = "timeline"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            "-cmux.labs.agentFeedDesign", design,
            "--agent-feed-scenario", scenario,
        ]
        app.launchEnvironment["CMUX_UITEST_AGENT_FEED_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_AGENT_FEED_SCENARIO"] = scenario
        app.launch()
        return app
    }

    @MainActor
    private func makeHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) {
        for _ in 0..<attempts where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func waitForEnabled(
        _ element: XCUIElement,
        expected: Bool,
        timeout: TimeInterval = 3
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == %@", NSNumber(value: expected)),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func waitForExistence(
        _ element: XCUIElement,
        expected: Bool,
        timeout: TimeInterval = 3
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == %@", NSNumber(value: expected)),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func metricFields(_ marker: String) -> [String: String] {
        var fields: [String: String] = [:]
        for component in marker.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            fields[String(pair[0])] = String(pair[1])
        }
        return fields
    }
}
