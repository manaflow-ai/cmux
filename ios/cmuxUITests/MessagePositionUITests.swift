import XCTest

final class MessagePositionUITests: XCTestCase {
    private let yTolerance: CGFloat = 1.5
    private let gapTolerance: CGFloat = 2.5
    private let openOverlapMinDelta: CGFloat = 120
    private let minExpandedPillHeight: CGFloat = 56
    private let frameStabilityTolerance: CGFloat = 0.5
    private let frameSampleInterval: TimeInterval = 0.016
    private let quickReturnTimeout: TimeInterval = 0.6
    private let jankDownwardTolerance: CGFloat = 1.0
    private let topThresholdRatio: CGFloat = 0.75
    private let jankConversationId = "ts79xr7rr98pbr98rb6vssta75800802"
    private let tinyConversationId = "ts78emy26kmwvaj753cqxeb7ah807rd0"
    private let morphConversationId = "ts7bx1k6fg8swft6edw4ykjg3s805hpj"
    private let e2bConversationId = "ts76s01mxqf2wayhv2hcxx76cd80447d"
    private let toolCallSheetConversationId = "ts_toolcall_sheet_long"
    private let toolCallSheetToolCallId = "toolcall_sheet_1"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLastAssistantMessageBottomStableAfterKeyboardCycle() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = "uitest_conversation_claude"
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_MESSAGE_COUNT"] = "90"
        app.launchEnvironment["CMUX_UITEST_ENDS_WITH_USER"] = "1"
        app.launchEnvironment["CMUX_UITEST_SCROLL_FRACTION"] = "1"
        app.launchEnvironment["CMUX_UITEST_TRACK_MESSAGE_POS"] = "1"
        app.launchEnvironment["CMUX_UITEST_BAR_Y_OFFSET"] = "34"
        app.launchEnvironment["CMUX_UITEST_INPUT_TEXT"] = "Line 1\\nLine 2\\nLine 3"
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        }
        app.launch()

        waitForMessages(app: app)

        let marker = app.otherElements["chat.lastAssistantTextBottom"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        let pill = waitForInputPill(app: app)
        let insetMarker = app.otherElements["chat.bottomInsetValue"]
        XCTAssertTrue(insetMarker.waitForExistence(timeout: 8))
        let overlapMarker = app.otherElements["chat.keyboardOverlapValue"]
        XCTAssertTrue(overlapMarker.waitForExistence(timeout: 8))
        waitForScrollSettle()

        let focusButton = app.buttons["chat.keyboard.focus"]
        XCTAssertTrue(focusButton.waitForExistence(timeout: 4))
        let dismissButton = app.buttons["chat.keyboard.dismiss"]
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 4))
        let pillHeightMarker = app.otherElements["chat.pillHeightValue"]
        XCTAssertTrue(pillHeightMarker.waitForExistence(timeout: 4))

        _ = waitForNumericValueAtLeast(
            element: pillHeightMarker,
            minimum: minExpandedPillHeight,
            timeout: 6
        )
        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        let usesFakeKeyboard = snapOpen.waitForExistence(timeout: 1)
            && snapClosed.waitForExistence(timeout: 1)

        if usesFakeKeyboard {
            snapClosed.tap()
        } else {
            dismissButton.tap()
        }

        let baselineOverlap = waitForStableNumericValue(
            element: overlapMarker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )
        let baselineY = waitForStableBottomY(
            element: marker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )
        let baselinePillTop = waitForStableMinY(
            element: pill,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )
        let baselineGap = baselinePillTop - baselineY
        let baselineInset = waitForStableNumericValue(
            element: insetMarker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedInputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "keyboard closed"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedInputBaseline,
            context: "keyboard closed"
        )

        if usesFakeKeyboard {
            snapOpen.tap()
        } else {
            focusButton.tap()
        }
        var openOverlap = waitForNumericValueAtLeast(
            element: overlapMarker,
            minimum: baselineOverlap + openOverlapMinDelta,
            timeout: 8
        )
        if openOverlap < baselineOverlap + openOverlapMinDelta, snapOpen.exists {
            snapOpen.tap()
            openOverlap = waitForNumericValueAtLeast(
                element: overlapMarker,
                minimum: baselineOverlap + openOverlapMinDelta,
                timeout: 6
            )
        }
        XCTAssertGreaterThanOrEqual(
            openOverlap,
            baselineOverlap + openOverlapMinDelta,
            "Keyboard overlap never reached the open threshold: overlap=\(openOverlap) baseline=\(baselineOverlap)"
        )
        let openPillTop = waitForStableMinY(
            element: pill,
            timeout: 2,
            tolerance: 0.5,
            stableSamples: 3
        )
        let openY = waitForStableBottomY(
            element: marker,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let openGap = openPillTop - openY
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedInputBaseline,
            context: "keyboard open"
        )

        if usesFakeKeyboard {
            snapClosed.tap()
        } else {
            dismissButton.tap()
        }
        var closedOverlap = waitForNumericValueNear(
            element: overlapMarker,
            target: baselineOverlap,
            tolerance: 6,
            timeout: 8
        )
        if abs(closedOverlap - baselineOverlap) > 6, snapClosed.exists {
            snapClosed.tap()
            closedOverlap = waitForNumericValueNear(
                element: overlapMarker,
                target: baselineOverlap,
                tolerance: 6,
                timeout: 6
            )
        }
        XCTAssertLessThanOrEqual(
            abs(closedOverlap - baselineOverlap),
            6,
            "Keyboard overlap never returned to closed target: overlap=\(closedOverlap) baseline=\(baselineOverlap)"
        )

        let closedPillTop = waitForPillReturn(
            element: pill,
            baseline: baselinePillTop,
            tolerance: yTolerance,
            timeout: 12
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedInputBaseline,
            context: "keyboard closed after cycle"
        )
        let closedY = waitForStableBottomY(
            element: marker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedGap = closedPillTop - closedY
        let closedInset = waitForStableNumericValue(
            element: insetMarker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )

        let openGapDelta = abs(openGap - baselineGap)
        XCTAssertLessThanOrEqual(
            openGapDelta,
            gapTolerance,
            "Gap changed after keyboard open: baseline=\(baselineGap) open=\(openGap) delta=\(openGapDelta)"
        )
        let delta = abs(closedY - baselineY)
        XCTAssertLessThanOrEqual(
            delta,
            yTolerance,
            "Last assistant message moved after keyboard cycle: baseline=\(baselineY) closed=\(closedY) delta=\(delta)"
        )
        let pillDelta = abs(closedPillTop - baselinePillTop)
        XCTAssertLessThanOrEqual(
            pillDelta,
            yTolerance,
            "Input pill top moved after keyboard cycle: baseline=\(baselinePillTop) closed=\(closedPillTop) delta=\(pillDelta)"
        )
        let gapDelta = abs(closedGap - baselineGap)
        XCTAssertLessThanOrEqual(
            gapDelta,
            gapTolerance,
            "Gap changed after keyboard cycle: baseline=\(baselineGap) closed=\(closedGap) delta=\(gapDelta)"
        )
        let insetDelta = abs(closedInset - baselineInset)
        XCTAssertLessThanOrEqual(
            insetDelta,
            yTolerance,
            "Bottom inset changed after keyboard cycle: baseline=\(baselineInset) closed=\(closedInset) delta=\(insetDelta)"
        )
    }

    func testShortThreadMessagesDoNotShiftDuringKeyboardAnimation() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = "uitest_conversation_claude"
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_MESSAGE_COUNT"] = "2"
        app.launchEnvironment["CMUX_UITEST_ENDS_WITH_USER"] = "0"
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        }
        app.launch()

        waitForMessages(app: app)

        let userMessage = messageElement(app: app, fullId: "chat.message.uitest_msg_claude_1")
        XCTAssertTrue(userMessage.waitForExistence(timeout: 6))
        let assistantMessage = messageElement(app: app, fullId: "chat.message.uitest_msg_claude_2")
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 6))

        waitForScrollSettle()

        let pill = waitForInputPill(app: app)
        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        if snapClosed.waitForExistence(timeout: 1) {
            snapClosed.tap()
        }
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "short thread baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "short thread baseline"
        )

        let baselineUserY = waitForStableMinY(
            element: userMessage,
            timeout: 3,
            tolerance: 0.25,
            stableSamples: 3
        )
        let baselineAssistantY = waitForStableMinY(
            element: assistantMessage,
            timeout: 3,
            tolerance: 0.25,
            stableSamples: 3
        )

        let stepUp = app.buttons["chat.fakeKeyboard.stepUp"]
        let stepDown = app.buttons["chat.fakeKeyboard.stepDown"]
        let usesFakeKeyboard = stepUp.waitForExistence(timeout: 1)
            && stepDown.waitForExistence(timeout: 1)

        if usesFakeKeyboard {
            performKeyboardSteps(
                button: stepUp,
                steps: 12,
                sampleDuration: 0.35,
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                baselineUserY: baselineUserY,
                baselineAssistantY: baselineAssistantY,
                context: "opening keyboard"
            )
            assertInputPillVisibleAndNotBelowBaseline(
                app: app,
                pill: pill,
                baseline: inputBaseline,
                context: "short thread keyboard open"
            )

            performKeyboardSteps(
                button: stepDown,
                steps: 12,
                sampleDuration: 0.35,
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                baselineUserY: baselineUserY,
                baselineAssistantY: baselineAssistantY,
                context: "closing keyboard"
            )
            assertInputPillVisibleAndNotBelowBaseline(
                app: app,
                pill: pill,
                baseline: inputBaseline,
                context: "short thread keyboard closed"
            )
        } else {
            focusKeyboard(app: app)
            assertMessagePositionsStable(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                baselineUserY: baselineUserY,
                baselineAssistantY: baselineAssistantY,
                duration: 0.8,
                context: "system keyboard opening"
            )
            assertInputPillVisibleAndNotBelowBaseline(
                app: app,
                pill: pill,
                baseline: inputBaseline,
                context: "short thread keyboard open"
            )
            dismissKeyboard(app: app)
            assertMessagePositionsStable(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                baselineUserY: baselineUserY,
                baselineAssistantY: baselineAssistantY,
                duration: 0.8,
                context: "system keyboard closing"
            )
            assertInputPillVisibleAndNotBelowBaseline(
                app: app,
                pill: pill,
                baseline: inputBaseline,
                context: "short thread keyboard closed"
            )
        }
    }

    func testTinyConversationMessagesStayFixedWhenKeyboardOpens() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = tinyConversationId
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        }
        app.launch()

        waitForMessages(app: app)

        let userMessage = messageElement(app: app, fullId: "chat.message.\(tinyConversationId)_user")
        XCTAssertTrue(userMessage.waitForExistence(timeout: 6))
        let assistantMessage = messageElement(app: app, fullId: "chat.message.\(tinyConversationId)_assistant")
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 6))

        let pill = waitForInputPill(app: app)
        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        if snapClosed.waitForExistence(timeout: 1) {
            snapClosed.tap()
        }
        waitForScrollSettle()

        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "tiny thread baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "tiny thread baseline"
        )

        let baselineUserY = waitForStableMinY(
            element: userMessage,
            timeout: 3,
            tolerance: 0.25,
            stableSamples: 3
        )
        let baselineAssistantY = waitForStableMinY(
            element: assistantMessage,
            timeout: 3,
            tolerance: 0.25,
            stableSamples: 3
        )

        let overlapMarker = app.otherElements["chat.keyboardOverlapValue"]
        XCTAssertTrue(overlapMarker.waitForExistence(timeout: 4))
        let baselineOverlap = waitForStableNumericValue(
            element: overlapMarker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )

        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        if snapOpen.waitForExistence(timeout: 1) {
            snapOpen.tap()
        } else {
            focusKeyboard(app: app)
        }
        let openOverlap = waitForNumericValueAtLeast(
            element: overlapMarker,
            minimum: baselineOverlap + openOverlapMinDelta,
            timeout: 6
        )
        XCTAssertGreaterThanOrEqual(
            openOverlap,
            baselineOverlap + openOverlapMinDelta,
            "Keyboard overlap never reached the open threshold: overlap=\(openOverlap) baseline=\(baselineOverlap)"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "tiny thread keyboard open"
        )
        assertMessagePositionsStable(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            baselineUserY: baselineUserY,
            baselineAssistantY: baselineAssistantY,
            duration: 0.8,
            context: "tiny thread keyboard open"
        )
    }

    func testSingleUserMessageStartsNearTop() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = "uitest_conversation_claude"
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_MESSAGE_COUNT"] = "1"
        app.launchEnvironment["CMUX_UITEST_ENDS_WITH_USER"] = "1"
        app.launch()

        waitForMessages(app: app)

        let messages = messageElements(app: app)
        XCTAssertEqual(messages.count, 1)
        let message = messageElement(app: app, fullId: "chat.message.uitest_msg_claude_1")
        XCTAssertTrue(message.waitForExistence(timeout: 6))
        waitForScrollSettle()
        let pill = waitForInputPill(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "single message baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "single message baseline"
        )

        let scrollView = locateScrollView(app: app)
        XCTAssertTrue(scrollView.waitForExistence(timeout: 6))
        let scrollFrame = scrollView.frame
        let threshold = scrollFrame.minY + scrollFrame.height * topThresholdRatio
        let messageMinY = message.frame.minY
        XCTAssertLessThanOrEqual(
            messageMinY,
            threshold,
            "Single message should start near the top of the viewport: minY=\(messageMinY) threshold=\(threshold)"
        )
    }

    func testLongThreadAutoScrollsToBottomAndKeepsGapOnKeyboardOpen() {
        let app = XCUIApplication()
        let messageCount = 40
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = "uitest_conversation_claude"
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_MESSAGE_COUNT"] = String(messageCount)
        app.launchEnvironment["CMUX_UITEST_TRACK_MESSAGE_POS"] = "1"
        app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        app.launch()

        waitForMessages(app: app)

        let lastMessage = messageElement(app: app, fullId: "chat.message.uitest_msg_claude_\(messageCount)")
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 6))
        let pill = waitForInputPill(app: app)
        waitForScrollSettle()

        let closedPillTop = waitForStableMinY(
            element: pill,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedLastMaxY = waitForStableBottomY(
            element: lastMessage,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedGap = closedPillTop - closedLastMaxY
        XCTAssertGreaterThanOrEqual(
            closedGap,
            0,
            "Expected last message to be above the input at launch: gap=\(closedGap)"
        )
        XCTAssertLessThanOrEqual(
            closedGap,
            40,
            "Expected auto-scroll to bottom for long threads: gap=\(closedGap)"
        )

        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        if snapOpen.waitForExistence(timeout: 1) {
            snapOpen.tap()
        } else {
            focusKeyboard(app: app)
        }
        let overlapMarker = app.otherElements["chat.keyboardOverlapValue"]
        XCTAssertTrue(overlapMarker.waitForExistence(timeout: 4))
        _ = waitForNumericValueAtLeast(
            element: overlapMarker,
            minimum: openOverlapMinDelta,
            timeout: 6
        )

        let openPillTop = waitForStableMinY(
            element: pill,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let openLastMaxY = waitForStableBottomY(
            element: lastMessage,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let openGap = openPillTop - openLastMaxY
        XCTAssertGreaterThanOrEqual(
            openGap,
            0,
            "Expected last message to stay above the keyboard: gap=\(openGap)"
        )
        XCTAssertLessThanOrEqual(
            abs(openGap - closedGap),
            gapTolerance,
            "Expected bottom gap to stay stable for long threads: closed=\(closedGap) open=\(openGap)"
        )
    }

    func testLongThreadAutoScrollsToBottomWithUnderreportedContentSize() {
        let app = XCUIApplication()
        let messageCount = 60
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = "uitest_conversation_claude"
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_MESSAGE_COUNT"] = String(messageCount)
        app.launchEnvironment["CMUX_UITEST_LONG_MESSAGE_LINES"] = "12"
        app.launchEnvironment["CMUX_UITEST_UNDEREPORT_CONTENT_SIZE"] = "1"
        app.launch()

        waitForMessages(app: app)

        let lastMessage = messageElement(app: app, fullId: "chat.message.uitest_msg_claude_\(messageCount)")
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 6))
        let pill = waitForInputPill(app: app)
        waitForScrollSettle()

        let closedPillTop = waitForStableMinY(
            element: pill,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedLastMaxY = waitForStableBottomY(
            element: lastMessage,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedGap = closedPillTop - closedLastMaxY
        XCTAssertGreaterThanOrEqual(
            closedGap,
            0,
            "Expected last message above the input at launch: gap=\(closedGap)"
        )
        XCTAssertLessThanOrEqual(
            closedGap,
            40,
            "Expected auto-scroll to bottom even with underreported content size: gap=\(closedGap)"
        )
    }

    func testMorphConversationAutoScrollsToBottom() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = morphConversationId
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        }
        app.launch()

        waitForMessages(app: app)

        let lastMessage = messageElement(
            app: app,
            fullId: "chat.message.\(morphConversationId)_assistant"
        )
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 6))
        let pill = waitForInputPill(app: app)
        waitForScrollSettle()

        let closedPillTop = waitForStableMinY(
            element: pill,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedLastMaxY = waitForStableBottomY(
            element: lastMessage,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedGap = closedPillTop - closedLastMaxY
        XCTAssertGreaterThanOrEqual(
            closedGap,
            0,
            "Expected last message above the input at launch: gap=\(closedGap)"
        )
        XCTAssertLessThanOrEqual(
            closedGap,
            40,
            "Expected auto-scroll to bottom for the morph snapshot conversation: gap=\(closedGap)"
        )
    }

    func testE2bConversationAutoScrollsToBottom() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = e2bConversationId
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launch()

        waitForMessages(app: app)

        let lastMessage = messageElement(
            app: app,
            fullId: "chat.message.\(e2bConversationId)_assistant"
        )
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 6))
        let pill = waitForInputPill(app: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let closedPillTop = waitForStableMinY(
            element: pill,
            timeout: 0.6,
            tolerance: 0.5,
            stableSamples: 2
        )
        let closedLastMaxY = waitForStableBottomY(
            element: lastMessage,
            timeout: 0.6,
            tolerance: 0.5,
            stableSamples: 2
        )
        let closedGap = closedPillTop - closedLastMaxY
        XCTAssertGreaterThanOrEqual(
            closedGap,
            0,
            "Expected last message above the input at launch: gap=\(closedGap)"
        )
        XCTAssertLessThanOrEqual(
            closedGap,
            40,
            "Expected auto-scroll to bottom for the e2b snapshot conversation: gap=\(closedGap)"
        )
    }

    func testToolCallSheetDismissKeepsInputPinned() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = toolCallSheetConversationId
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        }
        app.launch()

        waitForMessages(app: app)

        let scrollView = locateScrollView(app: app)
        XCTAssertTrue(scrollView.waitForExistence(timeout: 6))
        let fitsMarker = app.otherElements["chat.contentFitsValue"]
        if fitsMarker.waitForExistence(timeout: 4) {
            let fitsValue = readNumericValue(from: fitsMarker)
            XCTAssertLessThan(
                fitsValue,
                0.5,
                "Expected conversation to require scrolling (fits=\(fitsValue))"
            )
        }

        let toolCallButton = app.buttons["chat.toolCall.\(toolCallSheetToolCallId)"]
        XCTAssertTrue(toolCallButton.waitForExistence(timeout: 6))

        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        let usesFakeKeyboard = snapOpen.waitForExistence(timeout: 1)
            && snapClosed.waitForExistence(timeout: 1)
        if usesFakeKeyboard {
            snapOpen.tap()
        } else {
            focusKeyboard(app: app)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let pill = waitForInputPill(app: app)
        let baseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "tool call sheet baseline open"
        )

        if toolCallButton.isHittable {
            toolCallButton.tap()
        } else {
            scrollView.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            toolCallButton.tap()
        }

        let toolTitle = app.staticTexts["Tool"]
        XCTAssertTrue(toolTitle.waitForExistence(timeout: 4))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let dismissedPredicate = NSPredicate(format: "exists == false")
        let dismissedExpectation = XCTNSPredicateExpectation(predicate: dismissedPredicate, object: toolTitle)
        _ = XCTWaiter.wait(for: [dismissedExpectation], timeout: 4)
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: baseline,
            context: "tool call sheet dismissed",
            duration: 0.8
        )
    }

    func testToolCallSheetKeepsKeyboardClosedWhenClosed() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = toolCallSheetConversationId
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        }
        app.launch()

        waitForMessages(app: app)

        let overlapMarker = app.otherElements["chat.keyboardOverlapValue"]
        XCTAssertTrue(overlapMarker.waitForExistence(timeout: 6))
        let toolCallButton = app.buttons["chat.toolCall.\(toolCallSheetToolCallId)"]
        XCTAssertTrue(toolCallButton.waitForExistence(timeout: 6))

        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        let usesFakeKeyboard = snapOpen.waitForExistence(timeout: 1)
            && snapClosed.waitForExistence(timeout: 1)
        if usesFakeKeyboard {
            snapClosed.tap()
        } else {
            dismissKeyboard(app: app)
        }
        waitForScrollSettle()

        let pill = waitForInputPill(app: app)
        let closedBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "tool call keyboard closed"
        )
        let baselineOverlap = waitForStableNumericValue(
            element: overlapMarker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )
        let baselinePillTop = waitForStableMinY(
            element: pill,
            timeout: 2,
            tolerance: 0.5,
            stableSamples: 2
        )

        let scrollView = locateScrollView(app: app)
        if toolCallButton.isHittable {
            toolCallButton.tap()
        } else {
            scrollView.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            toolCallButton.tap()
        }

        let toolTitle = app.staticTexts["Tool"]
        XCTAssertTrue(toolTitle.waitForExistence(timeout: 4))
        let openOverlap = waitForNumericValueNear(
            element: overlapMarker,
            target: baselineOverlap,
            tolerance: 6,
            timeout: 4
        )
        XCTAssertLessThanOrEqual(
            abs(openOverlap - baselineOverlap),
            6,
            "Keyboard opened after tool call sheet presented: overlap=\(openOverlap) baseline=\(baselineOverlap)"
        )
        let openPillTop = waitForStableMinY(
            element: pill,
            timeout: 2,
            tolerance: 0.5,
            stableSamples: 2
        )
        XCTAssertLessThanOrEqual(
            abs(openPillTop - baselinePillTop),
            yTolerance,
            "Input pill moved while keyboard should remain closed: baseline=\(baselinePillTop) open=\(openPillTop)"
        )

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let dismissedPredicate = NSPredicate(format: "exists == false")
        let dismissedExpectation = XCTNSPredicateExpectation(predicate: dismissedPredicate, object: toolTitle)
        _ = XCTWaiter.wait(for: [dismissedExpectation], timeout: 4)

        let closedOverlap = waitForNumericValueNear(
            element: overlapMarker,
            target: baselineOverlap,
            tolerance: 6,
            timeout: 4
        )
        XCTAssertLessThanOrEqual(
            abs(closedOverlap - baselineOverlap),
            6,
            "Keyboard opened after tool call sheet dismiss: overlap=\(closedOverlap) baseline=\(baselineOverlap)"
        )
        let closedPillTop = waitForStableMinY(
            element: pill,
            timeout: 2,
            tolerance: 0.5,
            stableSamples: 2
        )
        XCTAssertLessThanOrEqual(
            abs(closedPillTop - baselinePillTop),
            yTolerance,
            "Input pill shifted after tool call sheet dismiss: baseline=\(baselinePillTop) closed=\(closedPillTop)"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "tool call sheet dismiss keyboard closed"
        )
    }

    func testToolCallSheetRestoresKeyboardAfterDismiss() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = toolCallSheetConversationId
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        }
        app.launch()

        waitForMessages(app: app)

        let overlapMarker = app.otherElements["chat.keyboardOverlapValue"]
        XCTAssertTrue(overlapMarker.waitForExistence(timeout: 6))
        let toolCallButton = app.buttons["chat.toolCall.\(toolCallSheetToolCallId)"]
        XCTAssertTrue(toolCallButton.waitForExistence(timeout: 6))

        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        let usesFakeKeyboard = snapOpen.waitForExistence(timeout: 1)
            && snapClosed.waitForExistence(timeout: 1)
        if usesFakeKeyboard {
            snapClosed.tap()
        } else {
            dismissKeyboard(app: app)
        }
        waitForScrollSettle()

        let pill = waitForInputPill(app: app)
        let closedBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "tool call keyboard closed baseline"
        )
        let baselineOverlap = waitForStableNumericValue(
            element: overlapMarker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )
        let baselinePillTop = waitForStableMinY(
            element: pill,
            timeout: 2,
            tolerance: 0.5,
            stableSamples: 2
        )

        if usesFakeKeyboard {
            snapOpen.tap()
        } else {
            focusKeyboard(app: app)
        }
        var openOverlap = waitForNumericValueAtLeast(
            element: overlapMarker,
            minimum: baselineOverlap + openOverlapMinDelta,
            timeout: 6
        )
        if openOverlap < baselineOverlap + openOverlapMinDelta, snapOpen.exists {
            snapOpen.tap()
            openOverlap = waitForNumericValueAtLeast(
                element: overlapMarker,
                minimum: baselineOverlap + openOverlapMinDelta,
                timeout: 4
            )
        }
        XCTAssertGreaterThanOrEqual(
            openOverlap,
            baselineOverlap + openOverlapMinDelta,
            "Keyboard did not open before tool call sheet: overlap=\(openOverlap) baseline=\(baselineOverlap)"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "tool call keyboard open baseline"
        )

        let scrollView = locateScrollView(app: app)
        if toolCallButton.isHittable {
            toolCallButton.tap()
        } else {
            scrollView.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            toolCallButton.tap()
        }

        let toolTitle = app.staticTexts["Tool"]
        XCTAssertTrue(toolTitle.waitForExistence(timeout: 4))
        let closedOverlap = waitForNumericValueNear(
            element: overlapMarker,
            target: baselineOverlap,
            tolerance: 6,
            timeout: 6
        )
        XCTAssertLessThanOrEqual(
            abs(closedOverlap - baselineOverlap),
            6,
            "Keyboard did not close after tool call sheet opened: overlap=\(closedOverlap) baseline=\(baselineOverlap)"
        )
        let closedPillTop = waitForPillReturn(
            element: pill,
            baseline: baselinePillTop,
            tolerance: yTolerance,
            timeout: 6
        )
        XCTAssertLessThanOrEqual(
            abs(closedPillTop - baselinePillTop),
            yTolerance,
            "Input pill did not return to bottom when keyboard closed: baseline=\(baselinePillTop) closed=\(closedPillTop)"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "tool call keyboard closed while sheet open"
        )

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let dismissedPredicate = NSPredicate(format: "exists == false")
        let dismissedExpectation = XCTNSPredicateExpectation(predicate: dismissedPredicate, object: toolTitle)
        _ = XCTWaiter.wait(for: [dismissedExpectation], timeout: 4)

        let reopenedOverlap = waitForNumericValueAtLeast(
            element: overlapMarker,
            minimum: baselineOverlap + openOverlapMinDelta,
            timeout: 8
        )
        XCTAssertGreaterThanOrEqual(
            reopenedOverlap,
            baselineOverlap + openOverlapMinDelta,
            "Keyboard did not reopen after tool call sheet dismiss: overlap=\(reopenedOverlap) baseline=\(baselineOverlap)"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "tool call keyboard restored after dismiss"
        )
    }

    func testToolCallSheetClosesKeyboardReturnsInputQuickly() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = toolCallSheetConversationId
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        }
        app.launch()

        waitForMessages(app: app)

        let overlapMarker = app.otherElements["chat.keyboardOverlapValue"]
        XCTAssertTrue(overlapMarker.waitForExistence(timeout: 6))
        let toolCallButton = app.buttons["chat.toolCall.\(toolCallSheetToolCallId)"]
        XCTAssertTrue(toolCallButton.waitForExistence(timeout: 6))
        let pill = waitForInputPill(app: app)
        let scrollView = locateScrollView(app: app)

        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        let usesFakeKeyboard = snapOpen.waitForExistence(timeout: 1)
            && snapClosed.waitForExistence(timeout: 1)

        if usesFakeKeyboard {
            snapClosed.tap()
        } else {
            dismissKeyboard(app: app)
        }
        waitForScrollSettle()

        let baselineOverlap = waitForStableNumericValue(
            element: overlapMarker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 2
        )
        let baselinePillTop = waitForStableMinY(
            element: pill,
            timeout: 2,
            tolerance: 0.5,
            stableSamples: 2
        )
        let closedBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "tool call quick return baseline"
        )

        if usesFakeKeyboard {
            snapOpen.tap()
        } else {
            focusKeyboard(app: app)
        }
        _ = waitForNumericValueAtLeast(
            element: overlapMarker,
            minimum: baselineOverlap + openOverlapMinDelta,
            timeout: 6
        )

        if toolCallButton.isHittable {
            toolCallButton.tap()
        } else {
            scrollView.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            toolCallButton.tap()
        }

        let toolTitle = app.staticTexts["Tool"]
        XCTAssertTrue(toolTitle.waitForExistence(timeout: 4))

        let closedWhileSheet = waitForPillReturn(
            element: pill,
            baseline: baselinePillTop,
            tolerance: yTolerance,
            timeout: quickReturnTimeout
        )
        XCTAssertLessThanOrEqual(
            abs(closedWhileSheet - baselinePillTop),
            yTolerance,
            "Input pill did not return to bottom quickly after tool call sheet closed the keyboard."
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "tool call sheet open keyboard closed",
            duration: quickReturnTimeout
        )
        _ = waitForNumericValueNear(
            element: overlapMarker,
            target: baselineOverlap,
            tolerance: 6,
            timeout: 4
        )

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let dismissedPredicate = NSPredicate(format: "exists == false")
        let dismissedExpectation = XCTNSPredicateExpectation(predicate: dismissedPredicate, object: toolTitle)
        _ = XCTWaiter.wait(for: [dismissedExpectation], timeout: 4)

        let reopenedOverlap = waitForNumericValueAtLeast(
            element: overlapMarker,
            minimum: baselineOverlap + openOverlapMinDelta,
            timeout: 8
        )
        XCTAssertGreaterThanOrEqual(
            reopenedOverlap,
            baselineOverlap + openOverlapMinDelta,
            "Keyboard did not reopen after tool call sheet dismiss: overlap=\(reopenedOverlap) baseline=\(baselineOverlap)"
        )

        if usesFakeKeyboard {
            snapClosed.tap()
        } else {
            dismissKeyboard(app: app)
        }

        let closedAfterDismiss = waitForPillReturn(
            element: pill,
            baseline: baselinePillTop,
            tolerance: yTolerance,
            timeout: quickReturnTimeout
        )
        XCTAssertLessThanOrEqual(
            abs(closedAfterDismiss - baselinePillTop),
            yTolerance,
            "Input pill did not return to bottom quickly after keyboard dismiss."
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedBaseline,
            context: "tool call sheet after keyboard dismiss",
            duration: quickReturnTimeout
        )
    }

    func testShortThreadShiftsAboveKeyboardWhenNoScroll() {
        let app = XCUIApplication()
        let messageCount = 4
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = "uitest_conversation_claude"
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_MESSAGE_COUNT"] = String(messageCount)
        app.launchEnvironment["CMUX_UITEST_LONG_MESSAGE_LINES"] = "6"
        app.launchEnvironment["CMUX_UITEST_TRACK_MESSAGE_POS"] = "1"
        app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        app.launch()

        waitForMessages(app: app)

        let fitsMarker = app.otherElements["chat.contentFitsValue"]
        XCTAssertTrue(fitsMarker.waitForExistence(timeout: 6))
        let fitsValue = readNumericValue(from: fitsMarker)
        XCTAssertGreaterThanOrEqual(
            fitsValue,
            0.5,
            "Expected content to fit without scrolling (value=\(fitsValue))"
        )

        let lastMessage = messageElement(app: app, fullId: "chat.message.uitest_msg_claude_\(messageCount)")
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 6))
        let pill = waitForInputPill(app: app)
        waitForScrollSettle()

        let closedPillTop = waitForStableMinY(
            element: pill,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedLastMaxY = waitForStableBottomY(
            element: lastMessage,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let closedGap = closedPillTop - closedLastMaxY
        XCTAssertGreaterThanOrEqual(
            closedGap,
            0,
            "Expected last message above the input: gap=\(closedGap)"
        )
        XCTAssertLessThanOrEqual(
            closedGap,
            120,
            "Expected the last message near the input in the no-scroll case: gap=\(closedGap)"
        )

        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        if snapOpen.waitForExistence(timeout: 1) {
            snapOpen.tap()
        } else {
            focusKeyboard(app: app)
        }
        let overlapMarker = app.otherElements["chat.keyboardOverlapValue"]
        XCTAssertTrue(overlapMarker.waitForExistence(timeout: 4))
        _ = waitForNumericValueAtLeast(
            element: overlapMarker,
            minimum: openOverlapMinDelta,
            timeout: 6
        )

        let openPillTop = waitForStableMinY(
            element: pill,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let openLastMaxY = waitForStableBottomY(
            element: lastMessage,
            timeout: 3,
            tolerance: 0.5,
            stableSamples: 3
        )
        let openGap = openPillTop - openLastMaxY
        XCTAssertGreaterThanOrEqual(
            openGap,
            0,
            "Expected last message to stay above the keyboard: gap=\(openGap)"
        )
        XCTAssertLessThanOrEqual(
            abs(openGap - closedGap),
            gapTolerance,
            "Expected bottom gap to stay stable when the keyboard opens: closed=\(closedGap) open=\(openGap)"
        )
    }

    func testJankConversationMessageYLogging() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = jankConversationId
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD"] = "1"
        }
        app.launch()

        waitForMessages(app: app)

        let pill = waitForInputPill(app: app)
        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        let usesFakeKeyboard = snapOpen.waitForExistence(timeout: 1)
            && snapClosed.waitForExistence(timeout: 1)
        if usesFakeKeyboard {
            snapClosed.tap()
        } else {
            dismissKeyboard(app: app)
        }
        waitForScrollSettle()
        let closedInputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "jank logging closed"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedInputBaseline,
            context: "jank logging closed"
        )

        let baseline = snapshotMessageFrames(app: app, label: "baseline")
        XCTAssertGreaterThanOrEqual(baseline.count, 2)

        if usesFakeKeyboard {
            snapOpen.tap()
        } else {
            focusKeyboard(app: app)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedInputBaseline,
            context: "jank logging open"
        )
        _ = snapshotMessageFrames(app: app, label: "keyboard_open")

        if usesFakeKeyboard {
            snapClosed.tap()
        } else {
            dismissKeyboard(app: app)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedInputBaseline,
            context: "jank logging closed after cycle"
        )
        let closed = snapshotMessageFrames(app: app, label: "keyboard_closed")
        assertSnapshotDrift(
            baseline: baseline,
            current: closed,
            context: "after_keyboard_cycle",
            tolerance: yTolerance
        )
    }

    func testNoDownwardJumpDuringKeyboardOpen() {
        let app = XCUIApplication()
        let userMessageId = "\(jankConversationId)_user"
        let assistantMessageId = "\(jankConversationId)_assistant"
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_ID"] = jankConversationId
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_TRACK_MESSAGE_POS"] = "1"
        app.launchEnvironment["CMUX_UITEST_JANK_MONITOR"] = "1"
        app.launchEnvironment["CMUX_UITEST_JANK_MESSAGE_IDS"] =
            "\(userMessageId),\(assistantMessageId)"
        app.launchEnvironment["CMUX_UITEST_JANK_LOG_EVERY"] = "15"
        app.launchEnvironment["CMUX_UITEST_JANK_WINDOW_SECONDS"] = "5.0"
        app.launchEnvironment["CMUX_UITEST_INPUT_TEXT"] = "Line 1\\nLine 2\\nLine 3"
        app.launchEnvironment["CMUX_UITEST_ALLOW_ANIMATIONS"] = "1"
        app.launch()

        waitForMessages(app: app)

        let pill = waitForInputPill(app: app)
        let userMessage = messageElement(app: app, fullId: "chat.message.\(userMessageId)")
        XCTAssertTrue(userMessage.waitForExistence(timeout: 6))
        let assistantMessage = messageElement(app: app, fullId: "chat.message.\(assistantMessageId)")
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 6))
        var userBody = app.descendants(matching: .any)
            .matching(identifier: "chat.messageBody.\(userMessageId)")
            .firstMatch
        if !userBody.exists {
            userBody = userMessage
        }
        var assistantBody = app.descendants(matching: .any)
            .matching(identifier: "chat.messageBody.\(assistantMessageId)")
            .firstMatch
        if !assistantBody.exists {
            assistantBody = assistantMessage
        }
        let overlapMarker = app.otherElements["chat.keyboardOverlapValue"]
        XCTAssertTrue(overlapMarker.waitForExistence(timeout: 6))
        let maxDownMarker = app.otherElements["chat.jank.maxDownwardDelta"]
        XCTAssertTrue(maxDownMarker.waitForExistence(timeout: 6))
        let maxSourceMarker = app.otherElements["chat.jank.maxDownwardSource"]
        XCTAssertTrue(maxSourceMarker.waitForExistence(timeout: 6))
        let jankStart = app.buttons["chat.jank.start"]
        XCTAssertTrue(jankStart.waitForExistence(timeout: 6))
        let snapOpen = app.buttons["chat.fakeKeyboard.snapOpen"]
        let snapClosed = app.buttons["chat.fakeKeyboard.snapClosed"]
        let usesFakeKeyboard = snapOpen.waitForExistence(timeout: 1)
            && snapClosed.waitForExistence(timeout: 1)

        if usesFakeKeyboard {
            snapClosed.tap()
        } else {
            dismissKeyboard(app: app)
        }
        waitForScrollSettle()
        let closedInputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "jank open baseline closed"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedInputBaseline,
            context: "jank open baseline closed"
        )
        let baselineOverlap = waitForStableNumericValue(
            element: overlapMarker,
            timeout: 4,
            tolerance: 0.5,
            stableSamples: 3
        )

        if jankStart.isHittable {
            jankStart.tap()
        } else {
            jankStart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        if usesFakeKeyboard {
            snapOpen.tap()
        } else {
            focusKeyboard(app: app)
            let openOverlap = waitForNumericValueAtLeast(
                element: overlapMarker,
                minimum: baselineOverlap + openOverlapMinDelta,
                timeout: 6
            )
            XCTAssertGreaterThanOrEqual(
                openOverlap,
                baselineOverlap + openOverlapMinDelta,
                "Keyboard overlap never reached the open threshold: overlap=\(openOverlap) baseline=\(baselineOverlap). Disable the Simulator hardware keyboard or enable CMUX_UITEST_FAKE_KEYBOARD."
            )
        }
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: closedInputBaseline,
            context: "jank open baseline open"
        )
        let driftValues = maxDownwardDriftAfterMin(
            elements: [userBody, assistantBody],
            duration: 1.6
        )

        let maxDownward = readNumericValue(from: maxDownMarker)
        let maxSource = readStringValue(from: maxSourceMarker)
        let userJump = driftValues.first ?? 0
        let assistantJump = driftValues.dropFirst().first ?? 0
        let maxFrameJump = max(userJump, assistantJump)
        let maxObserved = max(maxDownward, maxFrameJump)
        print("LOG jank_max_downward=\(maxDownward) source=\(maxSource) userJump=\(userJump) assistantJump=\(assistantJump)")
        XCTAssertLessThanOrEqual(
            maxObserved,
            jankDownwardTolerance,
            "Message jump exceeded \(jankDownwardTolerance)px during keyboard open (max=\(maxObserved))"
        )
    }

    private func waitForScrollSettle() {
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
    }

    private func maxDownwardDriftAfterMin(
        elements: [XCUIElement],
        duration: TimeInterval
    ) -> [CGFloat] {
        let deadline = Date().addingTimeInterval(duration)
        var minYs = elements.map { $0.frame.minY }
        var maxDown = Array(repeating: CGFloat(0), count: elements.count)
        while Date() < deadline {
            for (index, element) in elements.enumerated() {
                let currentY = element.frame.minY
                if currentY < minYs[index] {
                    minYs[index] = currentY
                } else {
                    let delta = currentY - minYs[index]
                    if delta > maxDown[index] {
                        maxDown[index] = delta
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(frameSampleInterval))
        }
        return maxDown
    }

    private struct MessageFrameSnapshot {
        let id: String
        let minY: CGFloat
        let maxY: CGFloat
    }

    private func snapshotMessageFrames(app: XCUIApplication, label: String) -> [MessageFrameSnapshot] {
        let elements = messageElements(app: app)
        let snapshots = elements.map { element in
            let minY = waitForStableMinY(
                element: element,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let maxY = waitForStableBottomY(
                element: element,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            return MessageFrameSnapshot(id: element.identifier, minY: minY, maxY: maxY)
        }.sorted { $0.minY < $1.minY }

        for snapshot in snapshots {
            print("LOG \(label) id=\(snapshot.id) minY=\(snapshot.minY) maxY=\(snapshot.maxY)")
        }

        return snapshots
    }

    private func assertSnapshotDrift(
        baseline: [MessageFrameSnapshot],
        current: [MessageFrameSnapshot],
        context: String,
        tolerance: CGFloat
    ) {
        let baselineById = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        var missingIds: [String] = []
        for snapshot in current {
            guard let baselineSnapshot = baselineById[snapshot.id] else {
                missingIds.append(snapshot.id)
                continue
            }
            let minDelta = abs(snapshot.minY - baselineSnapshot.minY)
            let maxDelta = abs(snapshot.maxY - baselineSnapshot.maxY)
            print(
                "LOG \(context) id=\(snapshot.id) minDelta=\(minDelta) maxDelta=\(maxDelta)"
            )
            XCTAssertLessThanOrEqual(
                minDelta,
                tolerance,
                "Message minY drifted for \(snapshot.id) in \(context): baseline=\(baselineSnapshot.minY) current=\(snapshot.minY)"
            )
            XCTAssertLessThanOrEqual(
                maxDelta,
                tolerance,
                "Message maxY drifted for \(snapshot.id) in \(context): baseline=\(baselineSnapshot.maxY) current=\(snapshot.maxY)"
            )
        }
        if !missingIds.isEmpty {
            XCTFail("Missing baseline snapshots for ids: \(missingIds.joined(separator: ", "))")
        }
    }

    private func waitForStableBottomY(
        element: XCUIElement,
        timeout: TimeInterval,
        tolerance: CGFloat,
        stableSamples: Int
    ) -> CGFloat {
        return waitForStableValue(timeout: timeout, tolerance: tolerance, stableSamples: stableSamples) {
            element.frame.maxY
        }
    }

    private func waitForStableMinY(
        element: XCUIElement,
        timeout: TimeInterval,
        tolerance: CGFloat,
        stableSamples: Int
    ) -> CGFloat {
        return waitForStableValue(timeout: timeout, tolerance: tolerance, stableSamples: stableSamples) {
            element.frame.minY
        }
    }

    private func waitForPillReturn(
        element: XCUIElement,
        baseline: CGFloat,
        tolerance: CGFloat,
        timeout: TimeInterval
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = element.frame.minY
            if abs(current - baseline) <= tolerance {
                return waitForStableMinY(
                    element: element,
                    timeout: 2,
                    tolerance: 0.5,
                    stableSamples: 3
                )
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.frame.minY
    }
    private func waitForStableValue(
        timeout: TimeInterval,
        tolerance: CGFloat,
        stableSamples: Int,
        readValue: () -> CGFloat
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue = readValue()
        var stableCount = 0
        while Date() < deadline {
            let currentValue = readValue()
            if currentValue > 1, abs(currentValue - lastValue) <= tolerance {
                stableCount += 1
                if stableCount >= stableSamples {
                    return currentValue
                }
            } else {
                stableCount = 0
                lastValue = currentValue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return readValue()
    }

    private func waitForStableNumericValue(
        element: XCUIElement,
        timeout: TimeInterval,
        tolerance: CGFloat,
        stableSamples: Int
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue = readNumericValue(from: element)
        var stableCount = 0
        while Date() < deadline {
            let currentValue = readNumericValue(from: element)
            if currentValue > 0, abs(currentValue - lastValue) <= tolerance {
                stableCount += 1
                if stableCount >= stableSamples {
                    return currentValue
                }
            } else {
                stableCount = 0
                lastValue = currentValue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return readNumericValue(from: element)
    }

    private func waitForNumericValueNear(
        element: XCUIElement,
        target: CGFloat,
        tolerance: CGFloat,
        timeout: TimeInterval
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let currentValue = readNumericValue(from: element)
            if abs(currentValue - target) <= tolerance {
                return currentValue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return readNumericValue(from: element)
    }

    private func waitForNumericValueAtLeast(
        element: XCUIElement,
        minimum: CGFloat,
        timeout: TimeInterval
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let currentValue = readNumericValue(from: element)
            if currentValue >= minimum {
                return currentValue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return readNumericValue(from: element)
    }
    private func readNumericValue(from element: XCUIElement) -> CGFloat {
        if let value = element.value as? String, let numeric = Double(value) {
            return CGFloat(numeric)
        }
        if let number = element.value as? NSNumber {
            return CGFloat(truncating: number)
        }
        return element.frame.height
    }

    private func readStringValue(from element: XCUIElement) -> String {
        if let value = element.value as? String {
            return value
        }
        if let number = element.value as? NSNumber {
            return number.stringValue
        }
        return element.label
    }

    private func performKeyboardSteps(
        button: XCUIElement,
        steps: Int,
        sampleDuration: TimeInterval,
        userMessage: XCUIElement,
        assistantMessage: XCUIElement,
        baselineUserY: CGFloat,
        baselineAssistantY: CGFloat,
        context: String
    ) {
        for index in 0..<steps {
            button.tap()
            assertMessagePositionsStable(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                baselineUserY: baselineUserY,
                baselineAssistantY: baselineAssistantY,
                duration: sampleDuration,
                context: "\(context) step \(index + 1)"
            )
        }
    }

    private func assertMessagePositionsStable(
        userMessage: XCUIElement,
        assistantMessage: XCUIElement,
        baselineUserY: CGFloat,
        baselineAssistantY: CGFloat,
        duration: TimeInterval,
        context: String
    ) {
        let deadline = Date().addingTimeInterval(duration)
        var sampleIndex = 0
        while Date() < deadline {
            let userY = userMessage.frame.minY
            let assistantY = assistantMessage.frame.minY
            let userDelta = abs(userY - baselineUserY)
            let assistantDelta = abs(assistantY - baselineAssistantY)
            XCTAssertLessThanOrEqual(
                userDelta,
                frameStabilityTolerance,
                "User message moved during \(context) sample \(sampleIndex): baseline=\(baselineUserY) now=\(userY) delta=\(userDelta)"
            )
            XCTAssertLessThanOrEqual(
                assistantDelta,
                frameStabilityTolerance,
                "Assistant message moved during \(context) sample \(sampleIndex): baseline=\(baselineAssistantY) now=\(assistantY) delta=\(assistantDelta)"
            )
            sampleIndex += 1
            RunLoop.current.run(until: Date().addingTimeInterval(frameSampleInterval))
        }
    }

    private func focusKeyboard(app: XCUIApplication) {
        let textView = app.textViews["chat.inputField"]
        let textField = app.textFields["chat.inputField"]
        let pill = app.otherElements["chat.inputPill"]
        if textView.exists {
            if textView.isHittable {
                textView.tap()
            } else {
                textView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            return
        }
        if textField.exists {
            if textField.isHittable {
                textField.tap()
            } else {
                textField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            return
        }
        if pill.exists {
            pill.tap()
            return
        }
        let focusButton = app.buttons["chat.keyboard.focus"]
        if focusButton.exists {
            focusButton.tap()
            return
        }
        app.tap()
    }

    private func dismissKeyboard(app: XCUIApplication) {
        let dismissButton = app.buttons["chat.keyboard.dismiss"]
        if dismissButton.exists {
            dismissButton.tap()
            return
        }
        let keyboard = app.keyboards.element
        if keyboard.exists {
            let hide = keyboard.buttons["Hide keyboard"]
            if hide.exists {
                hide.tap()
            } else {
                let dismiss = keyboard.buttons["Dismiss keyboard"]
                if dismiss.exists {
                    dismiss.tap()
                } else {
                    let `return` = keyboard.buttons["Return"]
                    if `return`.exists {
                        `return`.tap()
                    } else {
                        app.tap()
                    }
                }
            }
        } else {
            app.tap()
        }
    }

    private func waitForMessages(app: XCUIApplication) {
        let first = messageQuery(app: app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    private func waitForInputPill(app: XCUIApplication) -> XCUIElement {
        let framePill = app.otherElements["chat.inputPillFrame"]
        if framePill.waitForExistence(timeout: 6) {
            return framePill
        }
        let pill = app.otherElements["chat.inputPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6))
        return pill
    }

    private func messageElement(app: XCUIApplication, fullId: String) -> XCUIElement {
        let matches = messageQuery(app: app).matching(identifier: fullId).allElementsBoundByIndex
        if let best = bestMessageMatch(from: matches) {
            return best
        }
        let scroll = app.scrollViews["chat.scroll"]
        if scroll.exists {
            return scroll.descendants(matching: .any).matching(identifier: fullId).firstMatch
        }
        return app.descendants(matching: .any).matching(identifier: fullId).firstMatch
    }

    private func messageElements(app: XCUIApplication) -> [XCUIElement] {
        return uniqueMessageElements(from: messageQuery(app: app).allElementsBoundByIndex)
    }

    private func locateScrollView(app: XCUIApplication) -> XCUIElement {
        let scroll = app.scrollViews["chat.scroll"]
        if scroll.exists {
            return scroll
        }
        return app.otherElements["chat.scroll"]
    }

    private func messageQuery(app: XCUIApplication) -> XCUIElementQuery {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.")
        let scroll = app.scrollViews["chat.scroll"]
        if scroll.exists {
            return scroll.descendants(matching: .any).matching(predicate)
        }
        return app.descendants(matching: .any).matching(predicate)
    }

    private func bestMessageMatch(from elements: [XCUIElement]) -> XCUIElement? {
        guard let first = elements.first else {
            return nil
        }
        var best = first
        var bestHeight = first.frame.height
        for element in elements.dropFirst() {
            let height = element.frame.height
            if height > bestHeight {
                best = element
                bestHeight = height
            }
        }
        return best
    }

    private func uniqueMessageElements(from elements: [XCUIElement]) -> [XCUIElement] {
        var bestById: [String: XCUIElement] = [:]
        var bestHeightById: [String: CGFloat] = [:]
        var orderedIds: [String] = []
        for element in elements {
            let identifier = element.identifier
            if identifier.isEmpty {
                continue
            }
            let height = element.frame.height
            if let existingHeight = bestHeightById[identifier] {
                if height > existingHeight {
                    bestById[identifier] = element
                    bestHeightById[identifier] = height
                }
            } else {
                bestById[identifier] = element
                bestHeightById[identifier] = height
                orderedIds.append(identifier)
            }
        }
        return orderedIds.compactMap { bestById[$0] }
    }

}
