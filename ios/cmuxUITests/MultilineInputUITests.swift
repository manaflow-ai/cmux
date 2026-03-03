import XCTest

final class MultilineInputUITests: XCTestCase {
    private let conversationName = "Claude"
    private let centerTolerance: CGFloat = 3.5
    private let maxPillHeight: CGFloat = 120
    private let minHeightGrowth: CGFloat = 18
    private let minReturnGrowth: CGFloat = 12
    private let bottomEdgeTolerance: CGFloat = 0.5
    private let frameTolerance: CGFloat = 3.5
    private let caretCenterTolerance: CGFloat = 3.5
    private let caretShiftTolerance: CGFloat = 2
    private let keyboardTolerance: CGFloat = 1.5
    private let caretBottomTolerance: CGFloat = 0.5
    private let caretYTolerance: CGFloat = 0.25
    private let caretViewportTolerance: CGFloat = 0.25
    private let caretDriftRangeTolerance: CGFloat = 0.75
    private let caretVisibilityTolerance: CGFloat = 1.5

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testInputCentersPlaceholderAndSingleLineText() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)

        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "placeholder baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "placeholder baseline"
        )

        assertInputCenterAligned(app: app, pill: pill, input: input, context: "placeholder")

        let placeholder = app.staticTexts["Message"]
        typeText(app: app, input: input, text: "H")
        XCTAssertFalse(
            placeholder.waitForExistence(timeout: 0.4),
            "Expected placeholder to hide after first character"
        )
        typeText(app: app, input: input, text: "ello")
        let sendButton = app.buttons["chat.sendButton"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 2),
            "Expected send button to appear after typing"
        )
        assertInputCenterAligned(app: app, pill: pill, input: input, context: "single-line text")
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "single-line text"
        )
    }

    func testCaretStaysCenteredAfterFirstCharacter() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)
        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "caret centered baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "caret centered baseline"
        )

        let caret = waitForInputCaret(app: app)
        let baselinePillFrame = waitForStableElementFrame(element: pill, timeout: 2)
        let baselineCaretFrame = waitForCaretFrameNearPill(
            caret: caret,
            pillFrame: baselinePillFrame,
            timeout: 2
        )
        let baselineDelta = abs(baselineCaretFrame.midY - baselinePillFrame.midY)
        XCTAssertLessThanOrEqual(
            baselineDelta,
            caretCenterTolerance,
            "Expected caret centered when empty, delta=\(baselineDelta) caret=\(baselineCaretFrame) pill=\(baselinePillFrame)"
        )

        typeText(app: app, input: input, text: "H")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let typedPillFrame = waitForStableElementFrame(element: pill, timeout: 2)
        let typedCaretFrame = waitForCaretFrameNearPill(
            caret: caret,
            pillFrame: typedPillFrame,
            timeout: 2
        )
        let typedDelta = abs(typedCaretFrame.midY - typedPillFrame.midY)
        XCTAssertLessThanOrEqual(
            typedDelta,
            caretCenterTolerance,
            "Expected caret centered after first character, delta=\(typedDelta) caret=\(typedCaretFrame) pill=\(typedPillFrame)"
        )

        let shiftDelta = abs(typedCaretFrame.midY - baselineCaretFrame.midY)
        XCTAssertLessThanOrEqual(
            shiftDelta,
            caretShiftTolerance,
            "Expected caret to stay vertically centered after first character, delta=\(shiftDelta) baseline=\(baselineCaretFrame) typed=\(typedCaretFrame)"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "caret centered after typing"
        )
    }

    func testInputExpandsForMultilineText() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)

        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)

        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "multiline expand baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "multiline expand baseline"
        )
        let baselinePillHeight = waitForStablePillHeight(app: app, pill: pill, timeout: 2)
        let baselineInputHeight = waitForStableInputFrame(app: app, input: input, timeout: 2).height

        setMultilineText(
            app: app,
            pill: pill,
            input: input,
            text: "Line 1\nLine 2\nLine 3"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let expandedPillHeight = waitForPillHeightIncrease(
            app: app,
            pill: pill,
            baseline: baselinePillHeight,
            minGrowth: minHeightGrowth,
            timeout: 2
        )
        let expandedInputHeight = waitForHeightIncrease(
            element: input,
            baseline: baselineInputHeight,
            minGrowth: minHeightGrowth,
            timeout: 2
        )
        waitForInputWithinPill(pill: pill, input: input, app: app, timeout: 2)

        XCTAssertGreaterThanOrEqual(
            expandedPillHeight,
            baselinePillHeight + minHeightGrowth,
            "Expected pill to grow for multiline input"
        )
        XCTAssertGreaterThanOrEqual(
            expandedInputHeight,
            baselineInputHeight + minHeightGrowth,
            "Expected input field to grow for multiline input"
        )
        XCTAssertLessThanOrEqual(
            expandedPillHeight,
            maxPillHeight + 4,
            "Pill height should respect max height"
        )

        let pillFrame = pill.frame
        let inputFrame = input.frame
        XCTAssertGreaterThanOrEqual(
            inputFrame.minY,
            pillFrame.minY - frameTolerance,
            "Input text should stay within pill bounds (top)"
        )
        XCTAssertLessThanOrEqual(
            inputFrame.maxY,
            pillFrame.maxY + frameTolerance,
            "Input text should stay within pill bounds (bottom)"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "multiline expand"
        )
    }

    func testInputWrapsAfterAppendingHello() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launchEnvironment["CMUX_UITEST_RAW_CARET"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)
        let input = waitForInputField(app: app)
        let caret = waitForInputCaret(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)

        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "wrap baseline"
        )
        let baselinePillHeight = waitForStablePillHeight(app: app, pill: pill, timeout: 2)
        let baselineInputHeight = waitForStableInputFrame(app: app, input: input, timeout: 2).height

        typeText(app: app, input: input, text: "the only way i could be happy")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let singleLinePillHeight = waitForStablePillHeight(app: app, pill: pill, timeout: 2)
        let singleLineInputHeight = waitForStableInputFrame(app: app, input: input, timeout: 2).height
        XCTAssertLessThanOrEqual(
            singleLinePillHeight,
            baselinePillHeight + frameTolerance,
            "Expected pill to remain single-line before wrapping"
        )
        XCTAssertLessThanOrEqual(
            singleLineInputHeight,
            baselineInputHeight + frameTolerance,
            "Expected input to remain single-line before wrapping"
        )

        typeText(app: app, input: input, text: " hello")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let expandedPillHeight = waitForPillHeightIncrease(
            app: app,
            pill: pill,
            baseline: baselinePillHeight,
            minGrowth: minReturnGrowth,
            timeout: 2
        )
        let expandedInputHeight = waitForHeightIncrease(
            element: input,
            baseline: baselineInputHeight,
            minGrowth: minReturnGrowth,
            timeout: 2
        )
        assertCaretVisibleInInput(
            app: app,
            caret: caret,
            pill: pill,
            input: input,
            context: "wrap after hello"
        )
        XCTAssertGreaterThanOrEqual(
            expandedPillHeight,
            baselinePillHeight + minReturnGrowth,
            "Expected pill to grow after wrapping text"
        )
        XCTAssertGreaterThanOrEqual(
            expandedInputHeight,
            baselineInputHeight + minReturnGrowth,
            "Expected input to grow after wrapping text"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "wrap after hello"
        )
    }

    func testPillExpandsForReturnsOnlyAndShowsSend() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)

        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "returns expand baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "returns expand baseline"
        )

        let baselinePillHeight = pill.frame.height
        let baselineInputHeight = input.frame.height

        typeText(app: app, input: input, text: "\n\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let sendButton = app.buttons["chat.sendButton"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 2),
            "Expected send button to appear for whitespace input"
        )

        let placeholder = app.staticTexts["Message"]
        XCTAssertFalse(
            placeholder.exists,
            "Expected placeholder to hide when whitespace is entered"
        )

        let expandedPillHeight = waitForHeightIncrease(
            element: pill,
            baseline: baselinePillHeight,
            minGrowth: minReturnGrowth,
            timeout: 2
        )
        let expandedInputHeight = waitForHeightIncrease(
            element: input,
            baseline: baselineInputHeight,
            minGrowth: minReturnGrowth,
            timeout: 2
        )

        XCTAssertGreaterThan(
            expandedPillHeight,
            baselinePillHeight + minReturnGrowth,
            "Expected pill to grow for return-only input"
        )
        XCTAssertGreaterThan(
            expandedInputHeight,
            baselineInputHeight + minReturnGrowth,
            "Expected input field to grow for return-only input"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "returns expand"
        )

        clearInput(app: app, input: input)
        typeText(app: app, input: input, text: "   ")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 2),
            "Expected send button to appear for space-only input"
        )
        XCTAssertFalse(
            placeholder.exists,
            "Expected placeholder to hide when spaces are entered"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "returns expand after spaces"
        )
    }

    func testPillBottomEdgeStaysFixedWhenGrowing() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)
        let bottomEdge = waitForInputPillBottomEdge(app: app)

        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "pill bottom grows baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "pill bottom grows baseline"
        )

        let baselineBottom = waitForStablePillBottom(
            bottomEdge: bottomEdge,
            pill: pill,
            tolerance: bottomEdgeTolerance,
            stableSamples: 3,
            timeout: 2
        )
        let baselineKeyboardMinY = app.keyboards.firstMatch.frame.minY
        let baselineHeight = waitForStableElementFrame(element: pill, timeout: 2).height
        let baselineKeyboardGap = baselineKeyboardMinY - baselineBottom

        let metrics = typeTextStepwiseAndMeasure(
            app: app,
            input: input,
            pill: pill,
            bottomEdge: bottomEdge,
            baselineBottom: baselineBottom,
            baselineKeyboardMinY: baselineKeyboardMinY,
            baselineKeyboardGap: baselineKeyboardGap,
            text: "\n\n\n",
            perStepDuration: 0.32
        )
        XCTAssertGreaterThan(
            metrics.maxHeight,
            baselineHeight + minReturnGrowth,
            "Expected pill to grow while typing returns"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxKeyboardShift,
            keyboardTolerance,
            "Keyboard should stay fixed while typing returns (keyboard shift \(metrics.maxKeyboardShift))"
        )
        XCTAssertGreaterThan(
            metrics.stableKeyboardSamples,
            0,
            "Expected to observe stable keyboard samples while typing returns"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxDeviationWithStableKeyboard,
            bottomEdgeTolerance,
            "Pill bottom should stay fixed while growing with a stable keyboard (max deviation \(metrics.maxDeviationWithStableKeyboard))"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxKeyboardGapDeviation,
            bottomEdgeTolerance,
            "Pill bottom should stay fixed relative to the keyboard while growing (gap deviation \(metrics.maxKeyboardGapDeviation))"
        )
        assertPillBottomStableAfterTyping(
            app: app,
            pill: pill,
            bottomEdge: bottomEdge,
            baselineBottom: baselineBottom,
            baselineKeyboardMinY: baselineKeyboardMinY,
            baselineKeyboardGap: baselineKeyboardGap,
            duration: 0.5,
            context: "after return-only growth"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "pill bottom grows after typing"
        )
    }

    func testPillBottomEdgeStaysFixedWhenGrowingWithText() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)
        let bottomEdge = waitForInputPillBottomEdge(app: app)

        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "pill bottom text baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "pill bottom text baseline"
        )

        let baselineBottom = waitForStablePillBottom(
            bottomEdge: bottomEdge,
            pill: pill,
            tolerance: bottomEdgeTolerance,
            stableSamples: 3,
            timeout: 2
        )
        let baselineKeyboardMinY = app.keyboards.firstMatch.frame.minY
        let baselineHeight = pill.frame.height
        let baselineKeyboardGap = baselineKeyboardMinY - baselineBottom

        let metrics = typeTextStepwiseAndMeasure(
            app: app,
            input: input,
            pill: pill,
            bottomEdge: bottomEdge,
            baselineBottom: baselineBottom,
            baselineKeyboardMinY: baselineKeyboardMinY,
            baselineKeyboardGap: baselineKeyboardGap,
            text: "Line 1\nLine 2\nLine 3",
            perStepDuration: 0.2
        )

        XCTAssertGreaterThan(
            metrics.maxHeight,
            baselineHeight + minReturnGrowth,
            "Expected pill to grow while typing multiline text"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxKeyboardShift,
            keyboardTolerance,
            "Keyboard should stay fixed while typing multiline text (keyboard shift \(metrics.maxKeyboardShift))"
        )
        XCTAssertGreaterThan(
            metrics.stableKeyboardSamples,
            0,
            "Expected to observe stable keyboard samples while typing multiline text"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxDeviationWithStableKeyboard,
            bottomEdgeTolerance,
            "Pill bottom should stay fixed while growing with text and a stable keyboard (max deviation \(metrics.maxDeviationWithStableKeyboard))"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxKeyboardGapDeviation,
            bottomEdgeTolerance,
            "Pill bottom should stay fixed relative to the keyboard while growing with text (gap deviation \(metrics.maxKeyboardGapDeviation))"
        )
        assertPillBottomStableAfterTyping(
            app: app,
            pill: pill,
            bottomEdge: bottomEdge,
            baselineBottom: baselineBottom,
            baselineKeyboardMinY: baselineKeyboardMinY,
            baselineKeyboardGap: baselineKeyboardGap,
            duration: 0.5,
            context: "after multiline growth"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "pill bottom text after typing"
        )
    }

    func testPillBottomEdgeStaysFixedAtTwoLines() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)
        let bottomEdge = waitForInputPillBottomEdge(app: app)

        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "pill bottom two lines baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "pill bottom two lines baseline"
        )

        let baselineBottom = waitForStablePillBottom(
            bottomEdge: bottomEdge,
            pill: pill,
            tolerance: bottomEdgeTolerance,
            stableSamples: 3,
            timeout: 2
        )
        let baselineKeyboardMinY = app.keyboards.firstMatch.frame.minY
        let baselineKeyboardGap = baselineKeyboardMinY - baselineBottom

        let metrics = typeTextStepwiseAndMeasure(
            app: app,
            input: input,
            pill: pill,
            bottomEdge: bottomEdge,
            baselineBottom: baselineBottom,
            baselineKeyboardMinY: baselineKeyboardMinY,
            baselineKeyboardGap: baselineKeyboardGap,
            text: "\n",
            perStepDuration: 0.32
        )

        XCTAssertLessThanOrEqual(
            metrics.maxKeyboardShift,
            keyboardTolerance,
            "Keyboard should stay fixed while typing a single return (keyboard shift \(metrics.maxKeyboardShift))"
        )
        XCTAssertGreaterThan(
            metrics.stableKeyboardSamples,
            0,
            "Expected to observe stable keyboard samples while typing a single return"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxDeviationWithStableKeyboard,
            bottomEdgeTolerance,
            "Pill bottom should stay fixed when growing to two lines (max deviation \(metrics.maxDeviationWithStableKeyboard), gap deviation \(metrics.maxKeyboardGapDeviation), keyboard shift \(metrics.maxKeyboardShift))"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxKeyboardGapDeviation,
            bottomEdgeTolerance,
            "Pill bottom should stay fixed relative to the keyboard when growing to two lines (gap deviation \(metrics.maxKeyboardGapDeviation))"
        )
        assertPillBottomStableAfterTyping(
            app: app,
            pill: pill,
            bottomEdge: bottomEdge,
            baselineBottom: baselineBottom,
            baselineKeyboardMinY: baselineKeyboardMinY,
            baselineKeyboardGap: baselineKeyboardGap,
            duration: 0.4,
            context: "after two-line growth"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "pill bottom two lines after typing"
        )
    }

    func testCaretDistanceToBottomStaysFixedThroughReturns() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)
        let bottomEdge = waitForInputPillBottomEdge(app: app)
        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "caret distance baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "caret distance baseline"
        )

        let caret = waitForInputCaret(app: app)
        typeText(app: app, input: input, text: "A")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let baselineDistance = waitForStableCaretDistanceToBottom(
            caret: caret,
            bottomEdge: bottomEdge,
            timeout: 2,
            tolerance: 0.5,
            stableSamples: 3
        )
        let baselineCaretMaxY = waitForStableCaretMaxY(
            caret: caret,
            timeout: 2,
            tolerance: 0.5,
            stableSamples: 3
        )
        let baselineViewportBottom = waitForStableViewportBottom(
            app: app,
            timeout: 2,
            tolerance: 0.5,
            stableSamples: 3
        )
        let baselineCaretToViewportBottom = baselineViewportBottom - baselineCaretMaxY

        var minCaretMaxY = baselineCaretMaxY
        var maxCaretMaxY = baselineCaretMaxY
        var minCaretToViewportBottom = baselineCaretToViewportBottom
        var maxCaretToViewportBottom = baselineCaretToViewportBottom

        for index in 1...20 {
            let preReturnDistance = waitForStableCaretDistanceToBottom(
                caret: caret,
                bottomEdge: bottomEdge,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let preReturnMaxY = waitForStableCaretMaxY(
                caret: caret,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let preReturnViewportBottom = waitForStableViewportBottom(
                app: app,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let preReturnCaretToViewportBottom = preReturnViewportBottom - preReturnMaxY
            minCaretMaxY = min(minCaretMaxY, preReturnMaxY)
            maxCaretMaxY = max(maxCaretMaxY, preReturnMaxY)
            minCaretToViewportBottom = min(minCaretToViewportBottom, preReturnCaretToViewportBottom)
            maxCaretToViewportBottom = max(maxCaretToViewportBottom, preReturnCaretToViewportBottom)
            XCTAssertLessThanOrEqual(
                abs(preReturnDistance - baselineDistance),
                caretBottomTolerance,
                "Caret distance drifted before return \(index): baseline=\(baselineDistance) current=\(preReturnDistance)"
            )
            XCTAssertLessThanOrEqual(
                abs(preReturnMaxY - baselineCaretMaxY),
                caretYTolerance,
                "Caret maxY drifted before return \(index): baseline=\(baselineCaretMaxY) current=\(preReturnMaxY)"
            )
            XCTAssertLessThanOrEqual(
                abs(preReturnCaretToViewportBottom - baselineCaretToViewportBottom),
                caretViewportTolerance,
                "Caret distance to viewport bottom drifted before return \(index): baseline=\(baselineCaretToViewportBottom) current=\(preReturnCaretToViewportBottom)"
            )
            typeText(app: app, input: input, text: "\nA")
            let cursorDistance = waitForStableCaretDistanceToBottom(
                caret: caret,
                bottomEdge: bottomEdge,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let cursorMaxY = waitForStableCaretMaxY(
                caret: caret,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let cursorViewportBottom = waitForStableViewportBottom(
                app: app,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let cursorCaretToViewportBottom = cursorViewportBottom - cursorMaxY
            minCaretMaxY = min(minCaretMaxY, cursorMaxY)
            maxCaretMaxY = max(maxCaretMaxY, cursorMaxY)
            minCaretToViewportBottom = min(minCaretToViewportBottom, cursorCaretToViewportBottom)
            maxCaretToViewportBottom = max(maxCaretToViewportBottom, cursorCaretToViewportBottom)
            XCTAssertLessThanOrEqual(
                abs(cursorDistance - baselineDistance),
                caretBottomTolerance,
                "Caret distance to bottom drifted on return \(index): baseline=\(baselineDistance) current=\(cursorDistance)"
            )
            XCTAssertLessThanOrEqual(
                abs(cursorMaxY - baselineCaretMaxY),
                caretYTolerance,
                "Caret maxY drifted on return \(index): baseline=\(baselineCaretMaxY) current=\(cursorMaxY)"
            )
            XCTAssertLessThanOrEqual(
                abs(cursorCaretToViewportBottom - baselineCaretToViewportBottom),
                caretViewportTolerance,
                "Caret distance to viewport bottom drifted on return \(index): baseline=\(baselineCaretToViewportBottom) current=\(cursorCaretToViewportBottom)"
            )

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let typingIndicatorDistance = waitForStableCaretDistanceToBottom(
                caret: caret,
                bottomEdge: bottomEdge,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let typingIndicatorMaxY = waitForStableCaretMaxY(
                caret: caret,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let typingIndicatorViewportBottom = waitForStableViewportBottom(
                app: app,
                timeout: 2,
                tolerance: 0.5,
                stableSamples: 3
            )
            let typingIndicatorCaretToViewportBottom = typingIndicatorViewportBottom - typingIndicatorMaxY
            minCaretMaxY = min(minCaretMaxY, typingIndicatorMaxY)
            maxCaretMaxY = max(maxCaretMaxY, typingIndicatorMaxY)
            minCaretToViewportBottom = min(minCaretToViewportBottom, typingIndicatorCaretToViewportBottom)
            maxCaretToViewportBottom = max(maxCaretToViewportBottom, typingIndicatorCaretToViewportBottom)
            XCTAssertLessThanOrEqual(
                abs(typingIndicatorDistance - baselineDistance),
                caretBottomTolerance,
                "Typing indicator caret drifted on return \(index): baseline=\(baselineDistance) current=\(typingIndicatorDistance)"
            )
            XCTAssertLessThanOrEqual(
                abs(typingIndicatorMaxY - baselineCaretMaxY),
                caretYTolerance,
                "Typing indicator caret maxY drifted on return \(index): baseline=\(baselineCaretMaxY) current=\(typingIndicatorMaxY)"
            )
            XCTAssertLessThanOrEqual(
                abs(typingIndicatorCaretToViewportBottom - baselineCaretToViewportBottom),
                caretViewportTolerance,
                "Typing indicator caret distance to viewport bottom drifted on return \(index): baseline=\(baselineCaretToViewportBottom) current=\(typingIndicatorCaretToViewportBottom)"
            )
        }

        let caretMaxYRange = maxCaretMaxY - minCaretMaxY
        let caretViewportRange = maxCaretToViewportBottom - minCaretToViewportBottom
        XCTAssertLessThanOrEqual(
            caretMaxYRange,
            caretDriftRangeTolerance,
            "Caret maxY drift range exceeded tolerance: range=\(caretMaxYRange) min=\(minCaretMaxY) max=\(maxCaretMaxY)"
        )
        XCTAssertLessThanOrEqual(
            caretViewportRange,
            caretDriftRangeTolerance,
            "Caret-to-viewport-bottom drift range exceeded tolerance: range=\(caretViewportRange) min=\(minCaretToViewportBottom) max=\(maxCaretToViewportBottom)"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "caret distance after returns"
        )
    }

    func testKeyboardDoesNotJumpOnReturnAndBackspace() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)
        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "keyboard jump baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "keyboard jump baseline"
        )

        let baselineKeyboardMinY = app.keyboards.firstMatch.frame.minY
        typeText(app: app, input: input, text: "\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        typeText(app: app, input: input, text: XCUIKeyboardKey.delete.rawValue)

        let keyboardShift = sampleKeyboardShift(
            app: app,
            baselineKeyboardMinY: baselineKeyboardMinY,
            duration: 0.5
        )
        XCTAssertLessThanOrEqual(
            keyboardShift,
            keyboardTolerance,
            "Keyboard should remain stable after return + backspace (shift \(keyboardShift))"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "keyboard jump after return"
        )
    }

    func testPlaceholderResetsAfterMultiline() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] = "1"
        app.launchEnvironment["CMUX_UITEST_DIRECT_CHAT"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: conversationName)
        openConversation(app: app, name: conversationName)

        let pill = waitForInputPill(app: app)

        let input = waitForInputField(app: app)
        focusInput(app: app, pill: pill, input: input)
        clearInput(app: app, input: input)
        waitForKeyboard(app: app)
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: pill,
            context: "placeholder reset baseline"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "placeholder reset baseline"
        )

        assertInputCenterAligned(app: app, pill: pill, input: input, context: "placeholder baseline")
        let baselinePillHeight = pill.frame.height
        let baselineInputHeight = input.frame.height

        setMultilineText(
            app: app,
            pill: pill,
            input: input,
            text: "Line 1\nLine 2\nLine 3"
        )
        _ = waitForHeightIncrease(
            element: pill,
            baseline: baselinePillHeight,
            minGrowth: minHeightGrowth,
            timeout: 2
        )
        _ = waitForHeightIncrease(
            element: input,
            baseline: baselineInputHeight,
            minGrowth: minHeightGrowth,
            timeout: 2
        )

        clearInput(app: app, input: input)
        let reducedPillHeight = waitForHeightDecrease(
            element: pill,
            baseline: baselinePillHeight,
            maxGrowth: frameTolerance,
            timeout: 3
        )
        let reducedInputHeight = waitForHeightDecrease(
            element: input,
            baseline: baselineInputHeight,
            maxGrowth: frameTolerance,
            timeout: 3
        )
        waitForInputWithinPill(pill: pill, input: input, app: app, timeout: 2)
        XCTAssertLessThanOrEqual(
            reducedPillHeight,
            baselinePillHeight + frameTolerance,
            "Expected pill height to return to single-line baseline"
        )
        XCTAssertLessThanOrEqual(
            reducedInputHeight,
            baselineInputHeight + frameTolerance,
            "Expected input height to return to single-line baseline"
        )
        assertInputCenterAligned(app: app, pill: pill, input: input, context: "placeholder after multiline")
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: pill,
            baseline: inputBaseline,
            context: "placeholder reset after multiline"
        )
    }

    private func assertInputCenterAligned(
        app: XCUIApplication,
        pill: XCUIElement,
        input: XCUIElement,
        context: String
    ) {
        waitForInputWithinPill(pill: pill, input: input, app: app, timeout: 2)
        let pillFrame = waitForStableElementFrame(element: pill, timeout: 3)
        let inputFrame = waitForStableInputFrame(app: app, input: input, timeout: 3)
        let pillCenter = pillFrame.midY
        let inputCenter = inputFrame.midY
        let delta = abs(pillCenter - inputCenter)
        XCTAssertLessThanOrEqual(
            delta,
            centerTolerance,
            "Input center misaligned for \(context): \(delta)"
        )
    }

    private func assertCaretVisibleInInput(
        app: XCUIApplication,
        caret: XCUIElement,
        pill: XCUIElement,
        input: XCUIElement,
        context: String
    ) {
        let inputFrame = waitForStableInputFrame(app: app, input: input, timeout: 2)
        let pillFrame = waitForStableElementFrame(element: pill, timeout: 2)
        let caretFrame = waitForCaretFrameNearPill(
            caret: caret,
            pillFrame: pillFrame,
            timeout: 2
        )
        XCTAssertGreaterThanOrEqual(
            caretFrame.minY,
            inputFrame.minY - caretVisibilityTolerance,
            "Caret should be visible inside input for \(context): caret=\(caretFrame) input=\(inputFrame)"
        )
        XCTAssertLessThanOrEqual(
            caretFrame.maxY,
            inputFrame.maxY + caretVisibilityTolerance,
            "Caret should be visible inside input for \(context): caret=\(caretFrame) input=\(inputFrame)"
        )
    }

    private func waitForInputField(app: XCUIApplication) -> XCUIElement {
        let valueProxy = app.otherElements["chat.inputValue"]
        if valueProxy.waitForExistence(timeout: 2) {
            return valueProxy
        }
        let textView = app.textViews["chat.inputField"]
        if textView.waitForExistence(timeout: 4) {
            return textView
        }
        let textField = app.textFields["chat.inputField"]
        if textField.waitForExistence(timeout: 4) {
            return textField
        }
        let placeholderField = app.textFields["Message"]
        if placeholderField.waitForExistence(timeout: 2) {
            return placeholderField
        }
        let placeholderView = app.textViews["Message"]
        if placeholderView.waitForExistence(timeout: 2) {
            return placeholderView
        }
        let firstTextView = app.textViews.firstMatch
        if firstTextView.waitForExistence(timeout: 2) {
            return firstTextView
        }
        let firstTextField = app.textFields.firstMatch
        if firstTextField.waitForExistence(timeout: 2) {
            return firstTextField
        }
        let fallback = app.otherElements["chat.inputField"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 2))
        return fallback
    }

    private func waitForInputCaret(app: XCUIApplication) -> XCUIElement {
        let caret = app.otherElements["chat.inputCaretFrame"]
        XCTAssertTrue(caret.waitForExistence(timeout: 6))
        return caret
    }

    private func waitForCaretFrameNearPill(
        caret: XCUIElement,
        pillFrame: CGRect,
        timeout: TimeInterval
    ) -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFrame = CGRect.zero
        var stableCount = 0
        let maxDelta = max(40, pillFrame.height * 2)
        while Date() < deadline {
            let frame = caret.frame
            if frame.height > 1, frame.width > 1 {
                let delta = abs(frame.midY - pillFrame.midY)
                if delta <= maxDelta {
                    if abs(frame.midY - lastFrame.midY) <= 0.5,
                       abs(frame.height - lastFrame.height) <= 0.5 {
                        stableCount += 1
                        if stableCount >= 2 {
                            return frame
                        }
                    } else {
                        stableCount = 0
                        lastFrame = frame
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return caret.frame
    }

    private func waitForInputPill(app: XCUIApplication) -> XCUIElement {
        let framePill = app.otherElements["chat.inputPillFrame"]
        if framePill.waitForExistence(timeout: 15) {
            return framePill
        }
        let valueProxy = app.otherElements["chat.inputValue"]
        if valueProxy.waitForExistence(timeout: 4) {
            return valueProxy
        }
        let pill = app.otherElements["chat.inputPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        return pill
    }

    private func waitForInputPillBottomEdge(app: XCUIApplication) -> XCUIElement {
        let liveBottomEdge = app.otherElements["chat.inputPillBottomEdgeLive"]
        if liveBottomEdge.waitForExistence(timeout: 6) {
            return liveBottomEdge
        }
        let bottomEdge = app.otherElements["chat.inputPillBottomEdge"]
        if bottomEdge.waitForExistence(timeout: 6) {
            return bottomEdge
        }
        return waitForInputPill(app: app)
    }

    private func waitForKeyboard(app: XCUIApplication, timeout: TimeInterval = 4) {
        let keyboard = app.keyboards.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var lastMinY = keyboard.frame.minY
        var stableCount = 0
        while Date() < deadline {
            if keyboard.exists, keyboard.frame.height > 0 {
                let currentMinY = keyboard.frame.minY
                if abs(currentMinY - lastMinY) < 1 {
                    stableCount += 1
                    if stableCount >= 3 {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        return
                    }
                } else {
                    stableCount = 0
                    lastMinY = currentMinY
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
    }

    private func clearInput(app: XCUIApplication, input: XCUIElement) {
        if (input.elementType == .textView || input.elementType == .textField) && input.isHittable {
            input.tap()
        }
        if let value = input.value as? String {
            if value == "Message" || value.isEmpty {
                return
            }
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
            app.typeText(deleteString)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let remaining = readInputValue(app: app, input: input), !remaining.isEmpty {
                let debugClearButton = app.buttons["chat.debugClearInput"]
                if debugClearButton.waitForExistence(timeout: 1) {
                    debugClearButton.tap()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    return
                }
                input.press(forDuration: 1.1)
                let selectAll = app.menuItems["Select All"]
                if selectAll.waitForExistence(timeout: 1) {
                    selectAll.tap()
                    app.typeText(XCUIKeyboardKey.delete.rawValue)
                }
            }
        }
    }

    private func focusInput(app: XCUIApplication, pill: XCUIElement, input: XCUIElement) {
        if tapElement(input) {
            return
        }
        _ = tapElement(pill)
    }

    private func typeText(app: XCUIApplication, input: XCUIElement, text: String) {
        if (input.elementType == .textView || input.elementType == .textField) && input.isHittable {
            input.typeText(text)
            return
        }
        let textView = app.textViews["chat.inputField"]
        if textView.exists {
            _ = tapElement(textView)
            textView.typeText(text)
            return
        }
        app.typeText(text)
    }

    private func setMultilineText(
        app: XCUIApplication,
        pill: XCUIElement,
        input: XCUIElement,
        text: String
    ) {
        focusInput(app: app, pill: pill, input: input)
        waitForKeyboard(app: app)
        typeText(app: app, input: input, text: text)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func readInputValue(app: XCUIApplication, input: XCUIElement) -> String? {
        if let value = input.value as? String, !value.isEmpty, value != "Message" {
            return value
        }
        let fallback = app.otherElements["chat.inputValue"].firstMatch
        if fallback.exists,
           let value = fallback.value as? String,
           !value.isEmpty,
           value != "Message" {
            return value
        }
        if !input.label.isEmpty {
            return input.label
        }
        return nil
    }

    private func tapElement(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        if element.isHittable {
            element.tap()
            return true
        }
        let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        coordinate.tap()
        return true
    }


    private func waitForHeightIncrease(
        element: XCUIElement,
        baseline: CGFloat,
        minGrowth: CGFloat,
        timeout: TimeInterval
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var currentHeight = element.frame.height
        while Date() < deadline {
            currentHeight = element.frame.height
            if currentHeight > baseline + minGrowth {
                return currentHeight
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return currentHeight
    }

    private func waitForHeightDecrease(
        element: XCUIElement,
        baseline: CGFloat,
        maxGrowth: CGFloat,
        timeout: TimeInterval
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var currentHeight = element.frame.height
        while Date() < deadline {
            currentHeight = element.frame.height
            if currentHeight <= baseline + maxGrowth {
                return currentHeight
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return currentHeight
    }

    private func waitForInputWithinPill(
        pill: XCUIElement,
        input: XCUIElement,
        app: XCUIApplication?,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var consecutiveHits = 0
        while Date() < deadline {
            let pillFrame = pill.frame
            let inputFrame = app.map { inputFrameForAlignment(app: $0, input: input) } ?? input.frame
            let withinTop = inputFrame.minY >= pillFrame.minY - frameTolerance
            let withinBottom = inputFrame.maxY <= pillFrame.maxY + frameTolerance
            if withinTop && withinBottom {
                consecutiveHits += 1
                if consecutiveHits >= 2 {
                    return
                }
            } else {
                consecutiveHits = 0
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func inputFrameForAlignment(app: XCUIApplication, input: XCUIElement) -> CGRect {
        let proxy = app.otherElements["chat.inputValue"].firstMatch
        if proxy.exists, proxy.frame.height > 1, proxy.frame.width > 1 {
            return proxy.frame
        }
        return input.frame
    }

    private func waitForStableInputFrame(
        app: XCUIApplication,
        input: XCUIElement,
        timeout: TimeInterval
    ) -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFrame = CGRect.zero
        var stableCount = 0
        while Date() < deadline {
            let frame = inputFrameForAlignment(app: app, input: input)
            if frame.height > 1, frame.width > 1 {
                let delta = abs(frame.midY - lastFrame.midY)
                if delta <= 0.5, abs(frame.height - lastFrame.height) <= 0.5 {
                    stableCount += 1
                    if stableCount >= 2 {
                        return frame
                    }
                } else {
                    stableCount = 0
                    lastFrame = frame
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return inputFrameForAlignment(app: app, input: input)
    }

    private func readPillHeightValue(app: XCUIApplication) -> CGFloat? {
        let element = app.otherElements["chat.pillHeightValue"]
        guard element.exists else { return nil }
        if let value = element.value as? String, let height = Double(value) {
            return CGFloat(height)
        }
        let label = element.label
        if !label.isEmpty, let height = Double(label) {
            return CGFloat(height)
        }
        return nil
    }

    private func waitForStablePillHeight(
        app: XCUIApplication,
        pill: XCUIElement,
        timeout: TimeInterval
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var lastHeight: CGFloat = 0
        var stableCount = 0
        while Date() < deadline {
            let frameHeight = pill.frame.height
            let height = frameHeight > 1 ? frameHeight : (readPillHeightValue(app: app) ?? frameHeight)
            if height > 1 {
                if abs(height - lastHeight) <= 0.5 {
                    stableCount += 1
                    if stableCount >= 2 {
                        return height
                    }
                } else {
                    stableCount = 0
                    lastHeight = height
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let frameHeight = pill.frame.height
        return frameHeight > 1 ? frameHeight : (readPillHeightValue(app: app) ?? frameHeight)
    }

    private func waitForPillHeightIncrease(
        app: XCUIApplication,
        pill: XCUIElement,
        baseline: CGFloat,
        minGrowth: CGFloat,
        timeout: TimeInterval
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var currentHeight = pill.frame.height
        while Date() < deadline {
            let frameHeight = pill.frame.height
            currentHeight = frameHeight > 1 ? frameHeight : (readPillHeightValue(app: app) ?? frameHeight)
            if currentHeight > baseline + minGrowth {
                return currentHeight
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return currentHeight
    }

    private func waitForStableElementFrame(element: XCUIElement, timeout: TimeInterval) -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFrame = CGRect.zero
        var stableCount = 0
        while Date() < deadline {
            let frame = element.frame
            if frame.height > 1, frame.width > 1 {
                let delta = abs(frame.midY - lastFrame.midY)
                if delta <= 0.5, abs(frame.height - lastFrame.height) <= 0.5 {
                    stableCount += 1
                    if stableCount >= 2 {
                        return frame
                    }
                } else {
                    stableCount = 0
                    lastFrame = frame
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.frame
    }

    private struct BottomEdgeMetrics {
        let maxDeviation: CGFloat
        let maxHeight: CGFloat
        let maxKeyboardShift: CGFloat
        let maxDeviationWithStableKeyboard: CGFloat
        let maxKeyboardGapDeviation: CGFloat
        let stableKeyboardSamples: Int
    }

    private func typeTextStepwiseAndMeasure(
        app: XCUIApplication,
        input: XCUIElement,
        pill: XCUIElement,
        bottomEdge: XCUIElement,
        baselineBottom: CGFloat,
        baselineKeyboardMinY: CGFloat,
        baselineKeyboardGap: CGFloat,
        text: String,
        perStepDuration: TimeInterval
    ) -> BottomEdgeMetrics {
        var maxDeviation: CGFloat = 0
        var maxHeight = pill.frame.height
        var maxKeyboardShift: CGFloat = 0
        var maxDeviationWithStableKeyboard: CGFloat = 0
        var maxKeyboardGapDeviation: CGFloat = 0
        var stableKeyboardSamples = 0
        for character in text {
            typeText(app: app, input: input, text: String(character))
            let metrics = sampleBottomEdgeMetrics(
                app: app,
                bottomEdge: bottomEdge,
                pill: pill,
                baselineBottom: baselineBottom,
                baselineKeyboardMinY: baselineKeyboardMinY,
                baselineKeyboardGap: baselineKeyboardGap,
                duration: perStepDuration
            )
            maxDeviation = max(maxDeviation, metrics.maxDeviation)
            maxHeight = max(maxHeight, metrics.maxHeight)
            maxKeyboardShift = max(maxKeyboardShift, metrics.maxKeyboardShift)
            maxDeviationWithStableKeyboard = max(maxDeviationWithStableKeyboard, metrics.maxDeviationWithStableKeyboard)
            maxKeyboardGapDeviation = max(maxKeyboardGapDeviation, metrics.maxKeyboardGapDeviation)
            stableKeyboardSamples += metrics.stableKeyboardSamples
        }
        return BottomEdgeMetrics(
            maxDeviation: maxDeviation,
            maxHeight: maxHeight,
            maxKeyboardShift: maxKeyboardShift,
            maxDeviationWithStableKeyboard: maxDeviationWithStableKeyboard,
            maxKeyboardGapDeviation: maxKeyboardGapDeviation,
            stableKeyboardSamples: stableKeyboardSamples
        )
    }

    private func assertPillBottomStableAfterTyping(
        app: XCUIApplication,
        pill: XCUIElement,
        bottomEdge: XCUIElement,
        baselineBottom: CGFloat,
        baselineKeyboardMinY: CGFloat,
        baselineKeyboardGap: CGFloat,
        duration: TimeInterval,
        context: String
    ) {
        let metrics = sampleBottomEdgeMetrics(
            app: app,
            bottomEdge: bottomEdge,
            pill: pill,
            baselineBottom: baselineBottom,
            baselineKeyboardMinY: baselineKeyboardMinY,
            baselineKeyboardGap: baselineKeyboardGap,
            duration: duration
        )
        XCTAssertLessThanOrEqual(
            metrics.maxKeyboardShift,
            keyboardTolerance,
            "Keyboard should stay fixed \(context) (shift \(metrics.maxKeyboardShift))"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxDeviationWithStableKeyboard,
            bottomEdgeTolerance,
            "Pill bottom should stay fixed \(context) (max deviation \(metrics.maxDeviationWithStableKeyboard))"
        )
        XCTAssertLessThanOrEqual(
            metrics.maxKeyboardGapDeviation,
            bottomEdgeTolerance,
            "Pill bottom should stay fixed relative to the keyboard \(context) (gap deviation \(metrics.maxKeyboardGapDeviation))"
        )
    }

    private func sampleBottomEdgeMetrics(
        app: XCUIApplication,
        bottomEdge: XCUIElement,
        pill: XCUIElement,
        baselineBottom: CGFloat,
        baselineKeyboardMinY: CGFloat,
        baselineKeyboardGap: CGFloat,
        duration: TimeInterval
    ) -> BottomEdgeMetrics {
        let deadline = Date().addingTimeInterval(duration)
        var maxDeviation: CGFloat = 0
        var maxHeight = pill.frame.height
        var maxKeyboardShift: CGFloat = 0
        var maxDeviationWithStableKeyboard: CGFloat = 0
        var maxKeyboardGapDeviation: CGFloat = 0
        var stableKeyboardSamples = 0
        while Date() < deadline {
            let bottom = bottomEdge.frame.maxY
            let height = pill.frame.height
            maxDeviation = max(maxDeviation, abs(bottom - baselineBottom))
            maxHeight = max(maxHeight, height)
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists, keyboard.frame.height > 0 {
                let shift = abs(keyboard.frame.minY - baselineKeyboardMinY)
                maxKeyboardShift = max(maxKeyboardShift, shift)
                let gap = keyboard.frame.minY - bottom
                maxKeyboardGapDeviation = max(maxKeyboardGapDeviation, abs(gap - baselineKeyboardGap))
                if shift <= keyboardTolerance {
                    stableKeyboardSamples += 1
                    maxDeviationWithStableKeyboard = max(maxDeviationWithStableKeyboard, abs(bottom - baselineBottom))
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
        }
        return BottomEdgeMetrics(
            maxDeviation: maxDeviation,
            maxHeight: maxHeight,
            maxKeyboardShift: maxKeyboardShift,
            maxDeviationWithStableKeyboard: maxDeviationWithStableKeyboard,
            maxKeyboardGapDeviation: maxKeyboardGapDeviation,
            stableKeyboardSamples: stableKeyboardSamples
        )
    }

    private func sampleKeyboardShift(
        app: XCUIApplication,
        baselineKeyboardMinY: CGFloat,
        duration: TimeInterval
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(duration)
        var maxShift: CGFloat = 0
        while Date() < deadline {
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists, keyboard.frame.height > 0 {
                let shift = abs(keyboard.frame.minY - baselineKeyboardMinY)
                maxShift = max(maxShift, shift)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
        }
        return maxShift
    }

    private func waitForStablePillBottom(
        bottomEdge: XCUIElement,
        pill: XCUIElement,
        tolerance: CGFloat,
        stableSamples: Int,
        timeout: TimeInterval
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var lastBottom = bottomEdge.frame.maxY
        var stableCount = 0
        while Date() < deadline {
            let currentBottom = bottomEdge.frame.maxY
            if currentBottom <= 1 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                continue
            }
            let pillBottom = pill.frame.maxY
            if abs(currentBottom - pillBottom) > frameTolerance {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                continue
            }
            if abs(currentBottom - lastBottom) <= tolerance {
                stableCount += 1
                if stableCount >= stableSamples {
                    return currentBottom
                }
            } else {
                stableCount = 0
                lastBottom = currentBottom
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
        }
        return bottomEdge.frame.maxY
    }

    private func waitForStableCaretDistanceToBottom(
        caret: XCUIElement,
        bottomEdge: XCUIElement,
        timeout: TimeInterval,
        tolerance: CGFloat,
        stableSamples: Int
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var lastDistance = caretBottomDistance(caret: caret, bottomEdge: bottomEdge)
        var stableCount = 0
        while Date() < deadline {
            let caretFrame = caret.frame
            let bottomFrame = bottomEdge.frame
            if caretFrame.height > 1, bottomFrame.height > 0 {
                let currentDistance = caretBottomDistance(caret: caret, bottomEdge: bottomEdge)
                if abs(currentDistance - lastDistance) <= tolerance {
                    stableCount += 1
                    if stableCount >= stableSamples {
                        return currentDistance
                    }
                } else {
                    stableCount = 0
                    lastDistance = currentDistance
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return caretBottomDistance(caret: caret, bottomEdge: bottomEdge)
    }

    private func caretBottomDistance(caret: XCUIElement, bottomEdge: XCUIElement) -> CGFloat {
        bottomEdge.frame.maxY - caret.frame.maxY
    }

    private func waitForStableCaretMaxY(
        caret: XCUIElement,
        timeout: TimeInterval,
        tolerance: CGFloat,
        stableSamples: Int
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var lastMaxY = caret.frame.maxY
        var stableCount = 0
        while Date() < deadline {
            let frame = caret.frame
            if frame.height > 1, frame.width > 1 {
                let currentMaxY = frame.maxY
                if abs(currentMaxY - lastMaxY) <= tolerance {
                    stableCount += 1
                    if stableCount >= stableSamples {
                        return currentMaxY
                    }
                } else {
                    stableCount = 0
                    lastMaxY = currentMaxY
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return caret.frame.maxY
    }

    private func waitForStableViewportBottom(
        app: XCUIApplication,
        timeout: TimeInterval,
        tolerance: CGFloat,
        stableSamples: Int
    ) -> CGFloat {
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var lastBottom = window.exists ? window.frame.maxY : app.frame.maxY
        var stableCount = 0
        while Date() < deadline {
            let currentBottom = window.exists ? window.frame.maxY : app.frame.maxY
            if abs(currentBottom - lastBottom) <= tolerance {
                stableCount += 1
                if stableCount >= stableSamples {
                    return currentBottom
                }
            } else {
                stableCount = 0
                lastBottom = currentBottom
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return window.exists ? window.frame.maxY : app.frame.maxY
    }

    private func openConversation(app: XCUIApplication, name: String) {
        if app.otherElements["chat.inputPillFrame"].waitForExistence(timeout: 2) ||
            app.otherElements["chat.inputPill"].waitForExistence(timeout: 2) {
            return
        }
        let row = app.otherElements["conversation.row.\(name)"]
        if row.waitForExistence(timeout: 6) {
            row.tap()
            return
        }
        let list = app.tables.element(boundBy: 0)
        let cell = list.cells.containing(.staticText, identifier: name).firstMatch
        if !cell.waitForExistence(timeout: 6) {
            ensureConversationVisible(app: app, name: name)
        }
        if cell.exists && cell.isHittable {
            cell.tap()
            return
        }
        let firstCell = list.cells.firstMatch
        if firstCell.exists && firstCell.isHittable {
            firstCell.tap()
            return
        }
        let conversation = app.staticTexts[name]
        XCTAssertTrue(conversation.waitForExistence(timeout: 6))
        conversation.tap()
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
        if emailField.waitForExistence(timeout: 2) {
            XCTFail("Sign-in screen visible. Ensure CMUX_UITEST_MOCK_DATA or auto-auth is configured.")
        }
    }

    private func waitForConversationList(app: XCUIApplication) {
        let pillFrame = app.otherElements["chat.inputPillFrame"]
        if pillFrame.waitForExistence(timeout: 12) {
            return
        }
        let pill = app.otherElements["chat.inputPill"]
        if pill.waitForExistence(timeout: 12) {
            return
        }
        let navBar = app.navigationBars["Tasks"]
        if navBar.waitForExistence(timeout: 10) {
            return
        }
        let list = app.tables.element(boundBy: 0)
        _ = list.waitForExistence(timeout: 6)
    }
}
