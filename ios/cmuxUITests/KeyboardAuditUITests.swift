import XCTest

/// Keyboard audit (plans/cmux-next/ios-keyboard.md, step 1): each test
/// drives one keyboard path on an isolated simulator and records the
/// geometry as `KBD-AUDIT` lines. Assertions state the target behavior, so a
/// failure here is a finding.
@MainActor
final class KeyboardAuditUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: Home conversation

    /// Tap the field: the keyboard shows, the field sits on it, and the
    /// newest message stays visible above the field.
    func testComposerRidesKeyboardAndNewestMessageStaysVisible() {
        let app = KeyboardUITest.launch(conversation: "chief")
        let composer = KeyboardUITest.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        KeyboardUITest.wait(3) { KeyboardUITest.newestVisibleMessage(app) != nil }
        let before = KeyboardUITest.newestVisibleMessage(app)?.frame ?? .null
        KeyboardUITest.record("closed", ["composer": composer.frame.short, "newest": before.short])

        composer.tap()
        let keyboard = KeyboardUITest.keyboard(app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "keyboard did not show")
        KeyboardUITest.wait(2) { abs(composer.frame.maxY - keyboard.frame.minY) < 40 }
        let newest = KeyboardUITest.newestVisibleMessage(app)?.frame ?? .null
        KeyboardUITest.record("open", ["composer": composer.frame.short, "keyboard": keyboard.frame.short,
                                       "newest": newest.short])
        assertFieldOnKeyboard(composer, keyboard)
        XCTAssertLessThanOrEqual(newest.maxY, composer.frame.minY + 1, "newest message is under the field")
        XCTAssertGreaterThan(newest.minY, app.navigationBars.firstMatch.frame.maxY - 1, "newest message is off screen")
    }

    /// Send keeps the keyboard up and the field focused and empty; the sent
    /// message shows above the field.
    func testSendKeepsFocus() {
        let app = KeyboardUITest.launch(conversation: "chief")
        let composer = KeyboardUITest.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        XCTAssertTrue(KeyboardUITest.keyboard(app).waitForExistence(timeout: 5))
        composer.typeText("audit send one")
        app.buttons["Send"].firstMatch.tap()
        KeyboardUITest.wait(3) { (composer.value as? String ?? "").isEmpty }
        let newest = KeyboardUITest.newestVisibleMessage(app)
        KeyboardUITest.record("afterSend", ["keyboard": KeyboardUITest.keyboard(app).exists,
                                            "composerValue": composer.value as? String ?? "nil",
                                            "newestLabel": newest?.label ?? "nil",
                                            "newest": newest?.frame.short ?? "nil",
                                            "composer": composer.frame.short])
        XCTAssertTrue(KeyboardUITest.keyboard(app).exists, "keyboard closed after send")
        XCTAssertTrue(composer.hasKeyboardFocusValue, "field lost focus after send")
        let sent = KeyboardUITest.messages(app).last { $0.label.contains("audit send one") }
        XCTAssertNotNil(sent, "sent message is not on screen")
        XCTAssertLessThanOrEqual(sent?.frame.maxY ?? .infinity, composer.frame.minY + 1, "sent message is under the field")
        // A second message types into the same field without another tap.
        app.typeText("audit send two")
        XCTAssertEqual(composer.value as? String, "audit send two")
    }

    /// The field grows one line at a time up to five lines, then scrolls.
    func testComposerGrowsToFiveLines() {
        let app = KeyboardUITest.launch(conversation: "chief")
        let composer = KeyboardUITest.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        XCTAssertTrue(KeyboardUITest.keyboard(app).waitForExistence(timeout: 5))
        var heights: [CGFloat] = [composer.frame.height]
        for line in 1...7 {
            composer.typeText("\nline \(line)")
            KeyboardUITest.wait(1) { false }
            heights.append(composer.frame.height)
        }
        KeyboardUITest.record("grow", ["heights": heights.map { String(format: "%.1f", $0) }.joined(separator: ",")])
        XCTAssertGreaterThan(heights[4], heights[0], "field did not grow")
        XCTAssertEqual(heights[4] - heights[3], heights[3] - heights[2], accuracy: 1, "line 5 is clipped")
        XCTAssertEqual(heights[7], heights[4], accuracy: 1, "field grew past five lines")
        let newest = KeyboardUITest.newestVisibleMessage(app)?.frame ?? .null
        XCTAssertLessThanOrEqual(newest.maxY, composer.frame.minY + 1, "growing field covers the newest message")
    }

    /// Drag the transcript down through the keyboard: the keyboard follows
    /// the finger and closes; the field returns to the bottom and the newest
    /// message stays visible.
    func testInteractiveDismissal() {
        let app = KeyboardUITest.launch(conversation: "chief")
        let composer = KeyboardUITest.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let closedBottom = composer.frame.maxY
        composer.tap()
        let keyboard = KeyboardUITest.keyboard(app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        KeyboardUITest.wait(3) { !keyboard.exists }
        let newest = KeyboardUITest.newestVisibleMessage(app)?.frame ?? .null
        KeyboardUITest.record("afterDismiss", ["keyboard": keyboard.exists, "composer": composer.frame.short,
                                               "newest": newest.short, "window": window.frame.short])
        XCTAssertFalse(keyboard.exists, "drag did not dismiss the keyboard")
        XCTAssertEqual(composer.frame.maxY, closedBottom, accuracy: 2, "field did not return to the bottom")
    }

    /// Hardware keyboard: Return sends, Shift-Return adds a line.
    func testHardwareReturnSendsAndShiftReturnAddsLine() {
        let app = KeyboardUITest.launch(conversation: "chief")
        let composer = KeyboardUITest.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        // Harness control: a plain hardware key must type, or the run cannot test hardware keys.
        composer.typeKey("x", modifierFlags: [])
        let control = composer.value as? String ?? ""
        KeyboardUITest.record("hardwareControl", ["typed": control.debugDescription])
        // The software keyboard's auto-capitalization may make it "X".
        guard control.lowercased() == "x" else {
            XCTFail("harness: hardware key events do not reach the app (typeKey x gave \(control.debugDescription))")
            return
        }
        // Second control: a special key (Delete) must reach the app too.
        composer.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        let afterDelete = composer.value as? String ?? ""
        guard afterDelete.isEmpty else {
            XCTFail("harness: special hardware keys do not reach the app (Delete left \(afterDelete.debugDescription)); UNVERIFIED here")
            return
        }
        composer.typeText("first")
        composer.typeKey(XCUIKeyboardKey.return, modifierFlags: .shift)
        composer.typeText("second")
        let multi = composer.value as? String ?? ""
        composer.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        KeyboardUITest.wait(3) { (composer.value as? String ?? "").isEmpty }
        let newest = KeyboardUITest.newestVisibleMessage(app)
        KeyboardUITest.record("hardwareReturn", ["afterShiftReturn": multi.debugDescription,
                                                 "afterReturn": (composer.value as? String ?? "nil").debugDescription,
                                                 "newestLabel": newest?.label ?? "nil"])
        XCTAssertEqual(multi, "first\nsecond")
        XCTAssertTrue((composer.value as? String ?? "x").isEmpty, "hardware Return did not send")
    }

    /// Rotation with the keyboard up keeps the field on the keyboard and the
    /// newest message visible.
    func testRotationKeepsFieldAndNewestMessage() {
        let app = KeyboardUITest.launch(conversation: "chief")
        let composer = KeyboardUITest.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        let keyboard = KeyboardUITest.keyboard(app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        KeyboardUITest.wait(2) { false }
        let landscapeNewest = KeyboardUITest.newestVisibleMessage(app)?.frame ?? .null
        KeyboardUITest.record("landscape", ["composer": composer.frame.short, "keyboard": keyboard.frame.short,
                                            "newest": landscapeNewest.short, "window": app.windows.firstMatch.frame.short])
        assertFieldOnKeyboard(composer, keyboard)
        XCTAssertGreaterThan(landscapeNewest.height, 0, "no message visible in landscape")
        XCTAssertLessThanOrEqual(landscapeNewest.maxY, composer.frame.minY + 1)
        XCUIDevice.shared.orientation = .portrait
        KeyboardUITest.wait(2) { false }
        let portraitNewest = KeyboardUITest.newestVisibleMessage(app)?.frame ?? .null
        KeyboardUITest.record("portraitAgain", ["composer": composer.frame.short, "keyboard": keyboard.frame.short,
                                                "newest": portraitNewest.short])
        assertFieldOnKeyboard(composer, keyboard)
        XCTAssertLessThanOrEqual(portraitNewest.maxY, composer.frame.minY + 1)
    }

    /// Hardware shortcuts on Home and in a conversation (Messages-level bar):
    /// Cmd-F searches, Cmd-N starts a new message, Esc leaves a conversation.
    func testHardwareShortcuts() {
        let app = KeyboardUITest.launch()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        let searchFocused = KeyboardUITest.wait(2) { search.exists && search.hasKeyboardFocusValue }
        KeyboardUITest.record("cmdF", ["searchFocused": searchFocused])
        XCTAssertTrue(searchFocused, "Cmd-F does not focus search")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        app.typeKey("n", modifierFlags: .command)
        let newMessage = KeyboardUITest.wait(2) { app.navigationBars["New Message"].exists }
        KeyboardUITest.record("cmdN", ["newMessage": newMessage])
        XCTAssertTrue(newMessage, "Cmd-N does not open New Message")
    }

    /// Esc in a conversation returns to Home (hardware keyboard).
    func testEscapeLeavesConversation() {
        let app = KeyboardUITest.launch(conversation: "chief")
        let composer = KeyboardUITest.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let left = KeyboardUITest.wait(2) { !composer.exists }
        KeyboardUITest.record("escape", ["leftConversation": left])
        XCTAssertTrue(left, "Esc does not leave the conversation")
    }

    // MARK: Search and invite

    /// Search: typing filters; the keyboard's Search key closes the keyboard
    /// and keeps the results.
    func testSearchFieldKeyboard() {
        let app = KeyboardUITest.launch()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        let list = app.collectionViews.firstMatch
        list.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let keyboard = KeyboardUITest.keyboard(app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        search.typeText("nightly")
        KeyboardUITest.wait(2) { false }
        let resultCount = app.collectionViews.cells.count
        let returnKey = keyboard.buttons.allElementsBoundByIndex.last?.label ?? "nil"
        KeyboardUITest.record("search", ["keyboard": keyboard.frame.short, "results": resultCount, "returnKey": returnKey])
        keyboard.buttons["search"].firstMatch.tap()
        KeyboardUITest.wait(2) { !keyboard.exists }
        KeyboardUITest.record("searchSubmit", ["keyboardAfterSearchKey": keyboard.exists])
    }

    /// Invite: the field is focused on open; Send on the keyboard sends.
    func testInviteSheetKeyboard() {
        let app = KeyboardUITest.launch()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        app.navigationBars.buttons["Invite"].firstMatch.tap()
        let keyboard = KeyboardUITest.keyboard(app)
        let shown = keyboard.waitForExistence(timeout: 5)
        let field = app.textFields.firstMatch
        KeyboardUITest.record("invite", ["keyboardOnOpen": shown, "fieldFocused": field.hasKeyboardFocusValue,
                                         "keyboard": keyboard.frame.short,
                                         "sendButton": app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Send'")).firstMatch.frame.short])
        XCTAssertTrue(shown, "invite sheet does not focus its field")
    }

    // MARK: Terminal

    /// Tap the terminal: the keyboard shows with a key bar (Esc, Ctrl, Tab,
    /// arrows); the terminal content stays visible above it.
    func testTerminalTapShowsKeyboardAndKeyBar() {
        let app = KeyboardUITest.launch(terminal: true)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        KeyboardUITest.wait(4) { false }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let keyboard = KeyboardUITest.keyboard(app)
        let shown = keyboard.waitForExistence(timeout: 4)
        let escKey = app.buttons["Escape"].waitForExistence(timeout: 3)
        let ctrlKey = app.buttons["Control"].exists
        KeyboardUITest.record("terminal", ["keyboardOnTap": shown, "escKey": escKey, "ctrlKey": ctrlKey,
                                           "keyboard": keyboard.frame.short])
        XCTAssertTrue(shown, "tapping the terminal does not show the keyboard")
        XCTAssertTrue(escKey && ctrlKey, "no terminal key bar")
    }
}

extension KeyboardAuditUITests {
    /// The field's bottom is 8 pt above the keyboard's top. The keyboard
    /// element's frame starts below the suggestion bar (up to 52 pt in the
    /// audit run), so the gap is checked as a range.
    func assertFieldOnKeyboard(_ composer: XCUIElement, _ keyboard: XCUIElement,
                               file: StaticString = #filePath, line: UInt = #line) {
        let gap = keyboard.frame.minY - composer.frame.maxY
        XCTAssertTrue((7...60).contains(gap), "field is not on the keyboard (gap \(gap) pt)", file: file, line: line)
    }
}

extension XCUIElement {
    /// True while this element is the first responder.
    var hasKeyboardFocusValue: Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
