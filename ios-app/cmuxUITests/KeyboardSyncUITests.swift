import XCTest

final class KeyboardSyncUITests: XCTestCase {
    private let defaultTolerance: CGFloat = 1.0
    private let interactiveAnchorTolerance: CGFloat = 2.5
    private let interactiveStepTolerance: CGFloat = 1.75
    private let longConversationName = "Claude"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testKeyboardSyncAtBottom() {
        runKeyboardSyncTest(scrollFraction: nil)
    }

    func testKeyboardSyncAtMiddle() {
        runKeyboardSyncTest(scrollFraction: 0.5)
    }

    func testKeyboardSyncAtTop() {
        runKeyboardSyncTest(scrollFraction: 0.0)
    }

    func testKeyboardInteractiveDismissalKeepsGap() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_SCROLL_FRACTION"] = "0.5"
        app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD_INITIAL_OVERLAP"] = "280"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: longConversationName)
        openConversation(app: app, name: longConversationName)
        waitForMessages(app: app)

        let pill = app.otherElements["chat.inputPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6))

        waitForScrollSettle()
        let stepDown = app.buttons["chat.fakeKeyboard.stepDown"]
        XCTAssertTrue(stepDown.waitForExistence(timeout: 4))

        let baseGaps = captureGaps(app: app, pill: pill)
        XCTAssertFalse(baseGaps.isEmpty, "No message gaps found before interactive dismissal")

        let baseFiltered = baseGaps.filter { $0.value >= 16 && $0.value <= 220 }
        let baseReference = baseFiltered.isEmpty ? baseGaps : baseFiltered

        var referenceGaps: [String: CGFloat] = [:]
        var lastGaps: [String: CGFloat] = [:]
        var hasReference = false
        let basePillTop = pill.frame.minY
        var sawPillMove = false
        let dragSteps = 5

        for index in 0..<dragSteps {
            performInteractiveDismissDrag(app: app, endDy: 0.74)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))

            if abs(pill.frame.minY - basePillTop) > 6 {
                sawPillMove = true
            }

            let dragGaps = captureGaps(app: app, pill: pill)
            let filteredCurrent = dragGaps.filter { $0.value >= 16 && $0.value <= 220 }
            let currentGaps = filteredCurrent.isEmpty ? dragGaps : filteredCurrent

            if !hasReference {
                if sawPillMove {
                    referenceGaps = currentGaps.isEmpty ? baseReference : currentGaps
                    lastGaps = referenceGaps
                    hasReference = true
                }
                continue
            }
            let commonKeys = Set(lastGaps.keys).intersection(currentGaps.keys)
            XCTAssertFalse(commonKeys.isEmpty, "No overlapping messages during interactive dismissal step \(index)")
            for key in commonKeys {
                guard let previousGap = lastGaps[key], let currentGap = currentGaps[key] else { continue }
                let totalDelta = abs(currentGap - (referenceGaps[key] ?? currentGap))
                XCTAssertLessThanOrEqual(
                    totalDelta,
                    interactiveAnchorTolerance,
                    "Gap drift too large for \(key) during interactive dismissal step \(index): \(totalDelta)"
                )
                assertAnchorStepSmoothness(
                    previousGap: previousGap,
                    currentGap: currentGap,
                    context: "interactive dismissal step \(index) for \(key)"
                )
            }
            referenceGaps = referenceGaps.filter { commonKeys.contains($0.key) }
            lastGaps = currentGaps.filter { commonKeys.contains($0.key) }
        }
        XCTAssertTrue(sawPillMove, "Input did not move during interactive dismissal")
        XCTAssertTrue(hasReference, "No anchor reference established during interactive dismissal")
    }

    private func runKeyboardSyncTest(scrollFraction: Double?) {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        if let scrollFraction {
            app.launchEnvironment["CMUX_UITEST_SCROLL_FRACTION"] = String(scrollFraction)
        }
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: longConversationName)
        openConversation(app: app, name: longConversationName)
        waitForMessages(app: app)

        let pill = app.otherElements["chat.inputPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6))

        waitForScrollSettle()
        let baseGaps = captureGaps(app: app, pill: pill)
        XCTAssertFalse(baseGaps.isEmpty)

        openKeyboard(app: app)
        waitForKeyboard(app: app, visible: true)
        let openGaps = captureGaps(app: app, pill: pill)
        assertGapConsistency(
            reference: baseGaps,
            current: openGaps,
            context: "keyboard open",
            tolerance: defaultTolerance
        )

        dismissKeyboard(app: app)
        waitForKeyboard(app: app, visible: false)
        let closedGaps = captureGaps(app: app, pill: pill)
        assertGapConsistency(
            reference: baseGaps,
            current: closedGaps,
            context: "keyboard closed",
            tolerance: defaultTolerance
        )
    }

    private func waitForScrollSettle() {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }

    private func openKeyboard(app: XCUIApplication) {
        let input = app.textFields["chat.inputField"]
        if input.exists {
            input.tap()
        } else {
            let pill = app.otherElements["chat.inputPill"]
            pill.tap()
        }
    }

    private func dismissKeyboard(app: XCUIApplication) {
        let scroll = locateScrollView(app: app)
        if scroll.exists {
            let target = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            target.tap()
        } else {
            app.tap()
        }
    }

    private func waitForKeyboard(app: XCUIApplication, visible: Bool) {
        let keyboard = app.keyboards.element
        if visible {
            XCTAssertTrue(keyboard.waitForExistence(timeout: 4))
        } else {
            let predicate = NSPredicate(format: "exists == false")
            expectation(for: predicate, evaluatedWith: keyboard)
            waitForExpectations(timeout: 4)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func openConversation(app: XCUIApplication, name: String) {
        let conversation = app.staticTexts[name]
        if !conversation.waitForExistence(timeout: 6) {
            ensureConversationVisible(app: app, name: name)
        }
        XCTAssertTrue(conversation.waitForExistence(timeout: 6))
        conversation.tap()
    }

    private func waitForMessages(app: XCUIApplication) {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.")
        let messages = app.otherElements.matching(predicate)
        let first = messages.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    private func ensureConversationVisible(app: XCUIApplication, name: String) {
        let list = app.tables.element(boundBy: 0)
        let conversation = app.staticTexts[name]
        let maxSwipes = 6
        var attempt = 0
        while attempt < maxSwipes && !conversation.exists {
            if list.exists {
                list.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            attempt += 1
        }
    }

    private func ensureSignedIn(app: XCUIApplication) {
        let emailField = app.textFields["Email"]
        guard emailField.waitForExistence(timeout: 2) else { return }
        emailField.tap()
        emailField.typeText("42")
        let continueButton = app.buttons["Continue"]
        if continueButton.exists {
            continueButton.tap()
        }
    }

    private func waitForConversationList(app: XCUIApplication) {
        let navBar = app.navigationBars["Tasks"]
        if navBar.waitForExistence(timeout: 10) {
            return
        }
        let list = app.tables.element(boundBy: 0)
        _ = list.waitForExistence(timeout: 6)
    }

    private func performInteractiveDismissDrag(app: XCUIApplication, endDy: CGFloat, pressDuration: TimeInterval = 0.05) {
        let keyboard = app.keyboards.element
        if keyboard.exists {
            let start = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            let end = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: min(0.95, endDy)))
            start.press(forDuration: pressDuration, thenDragTo: end)
            return
        }
        let scroll = locateScrollView(app: app)
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endDy))
        start.press(forDuration: pressDuration, thenDragTo: end)
    }

    private func captureGaps(app: XCUIApplication, pill: XCUIElement) -> [String: CGFloat] {
        let scroll = locateScrollView(app: app)
        let scrollFrame = scroll.exists ? scroll.frame : app.windows.element(boundBy: 0).frame
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.")
        let messages = app.otherElements.matching(predicate).allElementsBoundByIndex

        var gaps: [String: CGFloat] = [:]
        for message in messages where message.frame.intersects(scrollFrame) {
            let gap = pill.frame.minY - message.frame.maxY
            gaps[message.identifier] = gap
        }
        return gaps
    }

    private func assertGapConsistency(
        reference: [String: CGFloat],
        current: [String: CGFloat],
        context: String,
        tolerance: CGFloat
    ) {
        let commonKeys = Set(reference.keys).intersection(current.keys)
        XCTAssertFalse(commonKeys.isEmpty, "No common messages for \(context)")
        for key in commonKeys {
            guard let base = reference[key], let now = current[key] else { continue }
            let delta = abs(base - now)
            XCTAssertLessThanOrEqual(
                delta,
                tolerance,
                "Gap drift for \(key) during \(context): \(delta)"
            )
        }
    }

    private func assertAnchorStepSmoothness(
        previousGap: CGFloat,
        currentGap: CGFloat,
        context: String
    ) {
        let stepDelta = abs(currentGap - previousGap)
        XCTAssertLessThanOrEqual(
            stepDelta,
            interactiveStepTolerance,
            "Anchor jump too large during \(context): \(stepDelta)"
        )
    }

    private func locateScrollView(app: XCUIApplication) -> XCUIElement {
        let scroll = app.scrollViews["chat.scroll"]
        if scroll.exists {
            return scroll
        }
        return app.otherElements["chat.scroll"]
    }
}
