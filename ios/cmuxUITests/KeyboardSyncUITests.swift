import XCTest

final class KeyboardSyncUITests: XCTestCase {
    private let defaultTolerance: CGFloat = 1.0
    private let interactiveAnchorTolerance: CGFloat = 2.5
    private let interactiveStepTolerance: CGFloat = 1.75
    private let uiTestConversationId = "uitest_conversation_claude"

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
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_MESSAGE_COUNT"] = "30"
        app.launchEnvironment["CMUX_UITEST_TRACK_MESSAGE_POS"] = "1"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = uiTestConversationId
        app.launchEnvironment["CMUX_UITEST_SCROLL_FRACTION"] = "0.5"
        app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD_INITIAL_OVERLAP"] = "0"
        app.launchEnvironment["CMUX_UITEST_DISABLE_SHORT_THREAD_PIN"] = "1"
        app.launch()

        waitForMessages(app: app)

        let pill = app.otherElements["chat.inputPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6))

        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        if snapClosed.waitForExistence(timeout: 1) {
            snapClosed.tap()
        } else {
            let stepDown = app.buttons["chat.fakeKeyboard.stepDown"]
            if stepDown.exists {
                for _ in 0..<12 {
                    stepDown.tap()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
                }
            }
        }
        waitForKeyboard(app: app, visible: false)
        waitForScrollSettle()
        let closedBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "interactive dismissal baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "interactive dismissal baseline"
        )
        openKeyboard(app: app, pill: pill)
        waitForKeyboard(app: app, visible: true)

        let stepDown = app.buttons["chat.fakeKeyboard.stepDown"]
        XCTAssertTrue(stepDown.waitForExistence(timeout: 4))
        let usesFakeKeyboard = stepDown.exists

        let basePillTop = pill.frame.minY
        let baseGaps = captureGaps(app: app, pill: pill)
        XCTAssertFalse(baseGaps.isEmpty, "No message gaps found before interactive dismissal")

        let baseFiltered = baseGaps.filter { $0.value >= 16 && $0.value <= 220 }
        let baseReference = baseFiltered.isEmpty ? baseGaps : baseFiltered

        var referenceGaps: [String: CGFloat] = usesFakeKeyboard ? baseReference : [:]
        var lastGaps: [String: CGFloat] = usesFakeKeyboard ? baseReference : [:]
        var hasReference = usesFakeKeyboard
        var sawPillMove = usesFakeKeyboard
        let dragSteps = 5

        for index in 0..<dragSteps {
            performInteractiveDismissDrag(app: app, endDy: 0.74)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))

            assertInputPillVisibleAndNotBelowBaseline(
                app: app,
                pill: pill,
                baseline: closedBaseline,
                context: "interactive dismissal step \(index)"
            )

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
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_MESSAGE_COUNT"] = "30"
        app.launchEnvironment["CMUX_UITEST_TRACK_MESSAGE_POS"] = "1"
        app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = uiTestConversationId
        app.launchEnvironment["CMUX_UITEST_DISABLE_SHORT_THREAD_PIN"] = "1"
        if let scrollFraction {
            app.launchEnvironment["CMUX_UITEST_SCROLL_FRACTION"] = String(scrollFraction)
        }
        app.launch()

        waitForMessages(app: app)

        let pill = app.otherElements["chat.inputPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6))

        waitForScrollSettle()
        let closedBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "keyboard sync closed"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "keyboard sync closed"
        )
        let baseGaps = captureGaps(app: app, pill: pill)
        XCTAssertFalse(baseGaps.isEmpty)

        openKeyboard(app: app, pill: pill)
        waitForKeyboard(app: app, visible: true)
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "keyboard sync open"
        )
        let openGaps = captureGaps(app: app, pill: pill)
        assertGapConsistency(
            reference: baseGaps,
            current: openGaps,
            context: "keyboard open",
            tolerance: defaultTolerance
        )

        dismissKeyboard(app: app)
        waitForKeyboard(app: app, visible: false)
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "keyboard sync closed after dismiss"
        )
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

    private func openKeyboard(app: XCUIApplication, pill: XCUIElement) {
        let stepUp = app.buttons["chat.fakeKeyboard.stepUp"]
        if stepUp.exists {
            for _ in 0..<12 {
                stepUp.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            }
            return
        }
        let input = app.textFields["chat.inputField"]
        if input.exists {
            input.tap()
        } else {
            pill.tap()
        }
    }

    private func waitForKeyboard(app: XCUIApplication, visible: Bool) {
        let stepDown = app.buttons["chat.fakeKeyboard.stepDown"]
        if stepDown.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            return
        }
        let keyboard = app.keyboards.element
        if visible {
            XCTAssertTrue(keyboard.waitForExistence(timeout: 4))
        } else {
            let predicate = NSPredicate(format: "exists == false")
            expectation(for: predicate, evaluatedWith: keyboard)
            waitForExpectations(timeout: 6)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func waitForMessages(app: XCUIApplication) {
        let marker = app.otherElements["chat.lastAssistantTextBottom"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if marker.frame.height > 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Last assistant marker never received a valid frame")
    }

    private func performInteractiveDismissDrag(
        app: XCUIApplication,
        endDy: CGFloat,
        pressDuration: TimeInterval = 0.05
    ) {
        let stepDown = app.buttons["chat.fakeKeyboard.stepDown"]
        if stepDown.exists {
            stepDown.tap()
            return
        }
        let keyboard = app.keyboards.element
        if keyboard.exists {
            let start = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            let end = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: min(0.95, endDy)))
            start.press(forDuration: pressDuration, thenDragTo: end)
            return
        }
        let window = app.windows.element(boundBy: 0)
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endDy))
        start.press(forDuration: pressDuration, thenDragTo: end)
    }

    private func captureGaps(app: XCUIApplication, pill: XCUIElement) -> [String: CGFloat] {
        let window = app.windows.firstMatch
        let windowFrame = window.exists ? window.frame : app.frame
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.")
        let messages = app.otherElements.matching(predicate)
        var gaps: [String: CGFloat] = [:]
        for index in 0..<messages.count {
            let message = messages.element(boundBy: index)
            let frame = message.frame
            if frame.height > 1,
               frame.width > 1,
               frame.intersects(windowFrame) {
                let gap = pill.frame.minY - frame.maxY
                gaps[message.identifier] = gap
            }
        }
        if !gaps.isEmpty {
            return gaps
        }
        let marker = app.otherElements["chat.lastAssistantTextBottom"]
        guard marker.exists else { return [:] }
        let gap = pill.frame.minY - marker.frame.maxY
        return ["lastAssistantText": gap]
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

    private func dismissKeyboard(app: XCUIApplication) {
        let stepDown = app.buttons["chat.fakeKeyboard.stepDown"]
        if stepDown.exists {
            for _ in 0..<12 {
                stepDown.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.06))
            }
            return
        }
        let keyboard = app.keyboards.element
        if keyboard.exists {
            let hide = keyboard.buttons["Hide keyboard"]
            if hide.exists {
                hide.tap()
                return
            }
            let dismiss = keyboard.buttons["Dismiss keyboard"]
            if dismiss.exists {
                dismiss.tap()
                return
            }
            let `return` = keyboard.buttons["Return"]
            if `return`.exists {
                `return`.tap()
                return
            }
        }
        let window = app.windows.element(boundBy: 0)
        let target = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        target.tap()
    }
}
