import XCTest

final class InputStrategyLabUITests: XCTestCase {
    private let baselineMetricsId = "debug.strategy.baseline.metrics"
    private let baselineInputId = "debug.strategy.baseline"
    private let caretYWrapTolerance: Double = 3.0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testBaselineCaretDistanceStableAtLineFive() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        openSettings(app: app)
        openChatDebugMenu(app: app)
        openInputStrategyLab(app: app)

        let input = app.textViews[baselineInputId]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap()

        let metrics = app.staticTexts[baselineMetricsId]
        XCTAssertTrue(metrics.waitForExistence(timeout: 6))

        var distancesByLine: [Int: Double] = [:]
        for _ in 0..<8 {
            input.typeText("A\n")
            if let current = waitForStableMetrics(metricsElement: metrics, timeout: 3) {
                if (4...6).contains(current.lineCount) && distancesByLine[current.lineCount] == nil {
                    distancesByLine[current.lineCount] = current.distance
                }
            }
            if distancesByLine.count == 3 {
                break
            }
        }

        let dist4 = requireValue(distancesByLine[4], message: "Missing line 4 distance")
        let dist5 = requireValue(distancesByLine[5], message: "Missing line 5 distance")
        let dist6 = requireValue(distancesByLine[6], message: "Missing line 6 distance")

        let tolerance: Double = 1.0
        XCTAssertLessThanOrEqual(
            abs(dist5 - dist4),
            tolerance,
            "Expected line 5 caret distance to stay stable. line4=\(dist4) line5=\(dist5)"
        )
        XCTAssertLessThanOrEqual(
            abs(dist6 - dist4),
            tolerance,
            "Expected line 6 caret distance to stay stable. line4=\(dist4) line6=\(dist6)"
        )
    }

    func testCaretYStableWhenWrappingToSecondLine() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        openSettings(app: app)
        openChatDebugMenu(app: app)
        openInputStrategyLab(app: app)

        let input = app.textViews[baselineInputId]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap()

        let metrics = app.staticTexts[baselineMetricsId]
        XCTAssertTrue(metrics.waitForExistence(timeout: 6))

        input.typeText("the only way i could be happy")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let baselineMetrics = requireMetrics(
            metricsElement: metrics,
            timeout: 3,
            message: "Missing baseline metrics"
        )
        let baselineCaretY = requireValue(
            baselineMetrics.caretY,
            message: "Missing baseline caretY"
        )

        input.typeText(" hello")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let wrappedMetrics = requireMetrics(
            metricsElement: metrics,
            timeout: 3,
            message: "Missing wrapped metrics"
        )
        let wrappedCaretY = requireValue(
            wrappedMetrics.caretY,
            message: "Missing wrapped caretY"
        )

        XCTAssertGreaterThanOrEqual(
            wrappedCaretY,
            baselineCaretY - caretYWrapTolerance,
            "Expected caretY to stay near baseline after wrap. baseline=\(baselineCaretY) wrapped=\(wrappedCaretY)"
        )
    }

    private func ensureSignedIn(app: XCUIApplication) {
        let emailField = app.textFields["Email"]
        if emailField.waitForExistence(timeout: 2) {
            XCTFail("Sign-in screen visible. Ensure CMUX_UITEST_MOCK_DATA or auto-auth is configured.")
        }
    }

    private func waitForConversationList(app: XCUIApplication) {
        let navBar = app.navigationBars["Tasks"]
        if navBar.waitForExistence(timeout: 10) {
            return
        }
        let list = app.tables.element(boundBy: 0)
        _ = list.waitForExistence(timeout: 10)
    }

    private func openSettings(app: XCUIApplication) {
        let menuButtons = [
            app.buttons["conversation.menu"],
            app.buttons["ellipsis.circle"],
            app.buttons["More"],
        ]
        var didTapMenu = false
        for button in menuButtons where button.exists {
            button.tap()
            didTapMenu = true
            break
        }
        XCTAssertTrue(didTapMenu, "Expected to find menu button on conversation list")

        let settingsButton = app.buttons["Settings"]
        let settingsMenuItem = app.menuItems["Settings"]
        if settingsButton.waitForExistence(timeout: 2) {
            settingsButton.tap()
        } else {
            XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 2))
            settingsMenuItem.tap()
        }

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 6),
            "Expected Settings view to appear"
        )
    }

    private func openChatDebugMenu(app: XCUIApplication) {
        let debugEntry = app.staticTexts["Chat Keyboard Approaches"]
        XCTAssertTrue(debugEntry.waitForExistence(timeout: 4))
        debugEntry.tap()
        XCTAssertTrue(
            app.navigationBars["Chat Debug"].waitForExistence(timeout: 6),
            "Expected Chat Debug menu to appear"
        )
    }

    private func openInputStrategyLab(app: XCUIApplication) {
        let entry = app.staticTexts["Input Strategy Lab"]
        if !entry.exists {
            let list = app.tables.element(boundBy: 0)
            if list.exists {
                for _ in 0..<6 where !entry.exists {
                    list.swipeUp()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                }
            }
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 4))
        entry.tap()
        XCTAssertTrue(
            app.navigationBars["Input Strategy Lab"].waitForExistence(timeout: 6),
            "Expected Input Strategy Lab view to appear"
        )
    }

    private func waitForStableMetrics(metricsElement: XCUIElement, timeout: TimeInterval) -> StrategyMetrics? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: StrategyMetrics?
        var stableCount = 0
        while Date() < deadline {
            let label = metricsElement.label
            if let parsed = parseMetrics(label) {
                if let last = lastValue,
                   last.lineCount == parsed.lineCount,
                   abs(last.distance - parsed.distance) <= 0.1 {
                    stableCount += 1
                    if stableCount >= 2 {
                        return parsed
                    }
                } else {
                    stableCount = 0
                    lastValue = parsed
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return lastValue
    }

    private func requireMetrics(
        metricsElement: XCUIElement,
        timeout: TimeInterval,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> StrategyMetrics {
        guard let metrics = waitForStableMetrics(metricsElement: metricsElement, timeout: timeout) else {
            XCTFail(message, file: file, line: line)
            return StrategyMetrics(lineCount: 0, distance: 0, caretY: nil)
        }
        return metrics
    }

    private func parseMetrics(_ text: String) -> StrategyMetrics? {
        guard let lineCount = parseInt(after: "lines ", in: text),
              let distance = parseDouble(after: "dist ", in: text) else {
            return nil
        }
        let caretY = parseDouble(after: "caretY ", in: text)
        return StrategyMetrics(lineCount: lineCount, distance: distance, caretY: caretY)
    }

    private func parseInt(after prefix: String, in text: String) -> Int? {
        guard let token = token(after: prefix, in: text) else { return nil }
        return Int(token)
    }

    private func parseDouble(after prefix: String, in text: String) -> Double? {
        guard let token = token(after: prefix, in: text), token != "--" else { return nil }
        return Double(token)
    }

    private func token(after prefix: String, in text: String) -> String? {
        guard let range = text.range(of: prefix) else { return nil }
        let remainder = text[range.upperBound...]
        let token = remainder.split { $0 == " " || $0 == "|" }.first
        return token.map(String.init)
    }

    private func requireValue(_ value: Double?, message: String, file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard let value else {
            XCTFail(message, file: file, line: line)
            return 0
        }
        return value
    }
}

private struct StrategyMetrics {
    let lineCount: Int
    let distance: Double
    let caretY: Double?
}
