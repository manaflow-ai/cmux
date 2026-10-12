import XCTest

/// Recorded scenarios. Each test is run on its own while `simctl io recordVideo`
/// captures the screen (see scripts/run_scenario.sh). Points are in the
/// iPhone 17 Pro coordinate space (402 x 874 pt, 3x).
final class Scenarios: XCTestCase {
    var app: XCUIApplication!

    /// Directory on the host that stills are written into (the simulator shares the host filesystem).
    static let stillsDir: String = ProcessInfo.processInfo.environment["CNM_STILLS"]
        ?? "/Users/cmux/cnm/imessage/stills"

    override func setUp() {
        continueAfterFailure = true
        app = SMS.app
        app.activate()
        SMS.pause(0.5)
        SMS.dismissKeyboardOnboarding(app)
        dismissKeyboardIfNeeded()
        SMS.goToList(app)
        SMS.pause(0.8)
    }

    // MARK: helpers

    func still(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: Self.stillsDir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: Self.stillsDir).appendingPathComponent("\(name).png")
        do { try png.write(to: url) } catch { print("CNM still write failed \(error)") }
        SMS.mark("still \(name)")
    }

    func pt(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { SMS.screenCoordinate(app, x: x, y: y) }

    /// Press, drag at a given speed (pt/s), hold, release.
    func drag(_ from: CGPoint, _ to: CGPoint, velocity: CGFloat = 600, hold: TimeInterval = 0.0, press: TimeInterval = 0.05) {
        pt(from.x, from.y).press(forDuration: press, thenDragTo: pt(to.x, to.y),
                                 withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: hold)
    }

    func dismissKeyboardIfNeeded() {
        if app.keyboards.firstMatch.exists {
            // Tap the transcript/list area above the keyboard.
            pt(201, 300).tap()
            SMS.pause(0.6)
        }
    }

    func openChat(_ chat: String) {
        SMS.goToList(app)
        app.staticTexts[chat].firstMatch.tap()
        SMS.pause(1.2)
    }

    /// Dismisses a context menu by tapping the dimmed backdrop on the side away from the menu.
    func dismissMenu() {
        let anchor = ["Copy", "Pin", "Mark as Unread", "Unpin"].map { app.buttons[$0] }.first { $0.exists }
        if let f = anchor?.frame {
            let x: CGFloat = f.midX < 201 ? 385 : 17
            pt(x, min(f.maxY + 60, 760)).tap()
        } else {
            pt(385, 700).tap()
        }
        SMS.pause(1.2)
    }

    func dump(_ tag: String) { print("=== \(tag) ===\n" + app.debugDescription) }

    // MARK: 1. Conversation list

    func testS1List() throws {
        still("s1-list-light")

        SMS.mark("scroll-up-collapse")
        drag(CGPoint(x: 201, y: 650), CGPoint(x: 201, y: 350), velocity: 400, hold: 0.8)
        SMS.pause(1.5)
        SMS.mark("pull-down")
        drag(CGPoint(x: 201, y: 300), CGPoint(x: 201, y: 650), velocity: 400, hold: 0.8)
        SMS.pause(1.5)

        let row = app.cells.containing(.staticText, identifier: Chat.a).firstMatch
        let rowY = row.frame.midY
        SMS.mark("swipe-left")
        drag(CGPoint(x: 360, y: rowY), CGPoint(x: 170, y: rowY), velocity: 500, hold: 0.3)
        SMS.pause(1.2)
        still("s1-swipe-left-actions")
        dump("SWIPE-LEFT")
        pt(201, 650).tap()
        SMS.pause(1.2)

        SMS.mark("swipe-right")
        drag(CGPoint(x: 30, y: rowY), CGPoint(x: 220, y: rowY), velocity: 500, hold: 0.3)
        SMS.pause(1.2)
        still("s1-swipe-right-actions")
        dump("SWIPE-RIGHT")
        pt(201, 650).tap()
        SMS.pause(1.2)

        SMS.mark("long-press-row")
        row.press(forDuration: 1.2)
        SMS.pause(1.2)
        still("s1-row-context-menu")
        SMS.mark("dismiss-row-menu")
        dismissMenu()

        SMS.mark("search-tap")
        pt(201, 822).tap()
        SMS.pause(1.5)
        still("s1-search-active")
        app.typeText("dinner")
        SMS.pause(1.5)
        still("s1-search-results")
        dump("SEARCH")
        if app.buttons["close"].exists { app.buttons["close"].firstMatch.tap() } else { pt(366, 503).tap() }
        SMS.pause(1.5)
    }

    /// Relaunch: NOTE the simulator Messages store is in-memory, so this wipes seeded messages.
    func testS0Launch() throws {
        SMS.mark("terminate")
        app.terminate()
        SMS.pause(1.0)
        SMS.mark("launch")
        app.activate()
        SMS.pause(2.5)
        still("s0-after-launch")
    }

    /// Pins the primary chat (run last: pinned layout changes the list).
    func testS8Pin() throws {
        let row = app.cells.containing(.staticText, identifier: Chat.a).firstMatch
        SMS.mark("long-press-row")
        row.press(forDuration: 1.2)
        SMS.pause(1.2)
        SMS.mark("tap-pin")
        app.buttons["Pin"].firstMatch.tap()
        SMS.pause(1.0)
        still("s8-pinned-1s")
        SMS.pause(3.0)
        still("s8-pinned")
        dump("PINNED")
    }

    /// Marks the loopback chat unread to capture the unread dot and back-button badge.
    func testS9Unread() throws {
        let row = app.cells.containing(.staticText, identifier: Chat.b).firstMatch
        row.press(forDuration: 1.2)
        SMS.pause(1.0)
        if app.buttons["Mark as Unread"].exists { app.buttons["Mark as Unread"].tap() } else { dismissMenu() }
        SMS.pause(1.5)
        still("s9-list-unread")
        dump("LIST-UNREAD")
        app.staticTexts[Chat.a].firstMatch.tap()
        SMS.pause(1.5)
        still("s9-backbutton-badge")
        dump("BACK-BADGE")
        app.navigationBars.buttons["BackButton"].tap()
        SMS.pause(1.0)
    }

    /// Unpins whatever is pinned (best effort) so later scenarios see the plain list.
    func testS1bUnpin() throws {
        dump("BEFORE-UNPIN")
        let pinned = app.collectionViews["ConversationList"].cells.firstMatch
        pinned.press(forDuration: 1.2)
        SMS.pause(1.0)
        still("s1-pinned-context-menu")
        dump("PIN-MENU")
        if app.buttons["Unpin"].exists { app.buttons["Unpin"].tap() } else { dismissMenu() }
        SMS.pause(1.5)
    }

    func testProbeEdge() throws {
        app.staticTexts[Chat.a].firstMatch.tap()
        SMS.pause(1.5)
        drag(CGPoint(x: 3, y: 450), CGPoint(x: 400, y: 450), velocity: 1500, hold: 0.0)
        SMS.pause(1.5)
        let inList = !app.navigationBars.buttons["BackButton"].exists
        print("CNM-EDGE-RESULT-1 inList=\(inList)")
        if !inList {
            pt(3, 450).press(forDuration: 0.0, thenDragTo: pt(300, 450), withVelocity: .fast, thenHoldForDuration: 0)
            SMS.pause(1.5)
            print("CNM-EDGE-RESULT-2 inList=\(!app.navigationBars.buttons["BackButton"].exists)")
        }
    }

    func testProbeState() throws {
        still("probe-list")
        app.staticTexts[Chat.a].firstMatch.tap()
        SMS.pause(1.5)
        still("probe-a")
    }

    // MARK: 2. Push / pop

    func testS2PushPop() throws {
        SMS.mark("push")
        app.staticTexts[Chat.a].firstMatch.tap()
        SMS.pause(1.5)
        still("s2-transcript-a")
        dump("TRANSCRIPT-A")
        SMS.mark("edge-partial-cancel")
        drag(CGPoint(x: 2, y: 450), CGPoint(x: 130, y: 450), velocity: 250, hold: 0.4)
        SMS.pause(1.5)
        SMS.mark("edge-complete")
        drag(CGPoint(x: 3, y: 450), CGPoint(x: 400, y: 450), velocity: 1500, hold: 0.0)
        SMS.pause(1.5)
        SMS.mark("push-2")
        app.staticTexts[Chat.a].firstMatch.tap()
        SMS.pause(1.5)
        SMS.mark("back-button")
        app.navigationBars.buttons["BackButton"].tap()
        SMS.pause(1.5)
        SMS.mark("push-b")
        app.staticTexts[Chat.b].firstMatch.tap()
        SMS.pause(1.5)
        still("s2-transcript-b")
        app.navigationBars.buttons["BackButton"].tap()
        SMS.pause(1.0)
    }

    // MARK: 3. Composer + send

    func testS3Composer() throws {
        openChat(Chat.a)
        SMS.pause(0.8)
        let field = app.textFields["messageBodyField"]
        SMS.mark("focus-field")
        field.tap()
        SMS.pause(1.8)
        still("s3-keyboard-up")
        SMS.mark("type-short")
        field.typeText("Running a bit late")
        SMS.pause(1.0)
        still("s3-composer-typed")
        dump("COMPOSER-TYPED")
        SMS.mark("send-1")
        app.buttons["sendButton"].tap()
        SMS.pause(2.5)
        still("s3-after-send-1")
        SMS.mark("type-multiline")
        field.typeText("This one is a longer message so the composer has to grow over several lines while I keep typing more words")
        SMS.pause(0.8)
        field.typeText("\nSecond paragraph\nThird line\nFourth line\nFifth line")
        SMS.pause(1.2)
        still("s3-composer-multiline")
        dump("COMPOSER-MULTI")
        SMS.mark("send-2")
        app.buttons["sendButton"].tap()
        SMS.pause(2.5)
        SMS.mark("send-3-consecutive")
        field.typeText("Ok")
        app.buttons["sendButton"].tap()
        SMS.pause(1.2)
        field.typeText("Leaving now 🚗")
        app.buttons["sendButton"].tap()
        SMS.pause(3.0)
        still("s3-grouped-tails")
        dump("AFTER-SENDS")
        // Back button should now show an unread count for the loopback chat.
        still("s3-backbutton-unread")
        dismissKeyboardIfNeeded()
        SMS.pause(1.0)
        SMS.mark("timestamp-reveal")
        drag(CGPoint(x: 330, y: 500), CGPoint(x: 150, y: 500), velocity: 300, hold: 1.0)
        SMS.pause(1.2)
        still("s3-timestamps-revealed-released")
    }

    /// Captures the timestamp reveal while the finger is still down (separate run so the still lands mid-gesture).
    func testS3bTimestampHold() throws {
        openChat(Chat.a)
        let start = pt(330, 500)
        let mid = pt(140, 500)
        let exp = expectation(description: "still")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: URL(fileURLWithPath: Self.stillsDir).appendingPathComponent("s3-timestamps-revealed-held.png"))
            exp.fulfill()
        }
        start.press(forDuration: 0.05, thenDragTo: mid, withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 2.5)
        wait(for: [exp], timeout: 10)
        SMS.pause(1.0)
    }

    // MARK: 4. Tapback + context menu

    func testS4Tapback() throws {
        openChat(Chat.a)
        let received = app.textViews.matching(identifier: "CKBalloonTextView").matching(NSPredicate(format: "value == %@", "Where should we go?")).firstMatch
        SMS.mark("long-press-received")
        received.press(forDuration: 1.0)
        SMS.pause(1.5)
        still("s4-tapback-menu-received")
        dump("TAPBACK-MENU")
        let heart = app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'heart'")).firstMatch
        if heart.exists { SMS.mark("tap-heart"); heart.tap() } else { dismissMenu() }
        SMS.pause(2.0)
        still("s4-after-heart")

        let sent = app.textViews.matching(identifier: "CKBalloonTextView").matching(NSPredicate(format: "value == %@", "See you at 7")).firstMatch
        SMS.mark("long-press-sent")
        sent.press(forDuration: 1.0)
        SMS.pause(1.5)
        still("s4-tapback-menu-sent")
        dump("TAPBACK-MENU-SENT")
        let thumb = app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'thumbsup'")).firstMatch
        if thumb.exists { SMS.mark("tap-thumb"); thumb.tap() } else { dismissMenu() }
        SMS.pause(2.0)
        still("s4-after-thumb")
        SMS.mark("long-press-dismiss")
        let perfect = app.textViews.matching(identifier: "CKBalloonTextView").matching(NSPredicate(format: "value BEGINSWITH %@", "Perfect")).firstMatch
        perfect.press(forDuration: 1.0)
        SMS.pause(1.5)
        still("s4-context-menu-copy")
        SMS.mark("dismiss-menu")
        dismissMenu()
    }

    // MARK: 5. Interactive keyboard dismissal

    func testS5KeyboardDismiss() throws {
        openChat(Chat.a)
        app.textFields["messageBodyField"].tap()
        SMS.pause(1.5)
        SMS.mark("drag-partial")
        drag(CGPoint(x: 201, y: 300), CGPoint(x: 201, y: 560), velocity: 250, hold: 0.6)
        SMS.pause(1.5)
        SMS.mark("drag-dismiss")
        drag(CGPoint(x: 201, y: 300), CGPoint(x: 201, y: 860), velocity: 350, hold: 0.0)
        SMS.pause(1.5)
        still("s5-keyboard-dismissed")
    }

    // MARK: 6. Scrolling the transcript

    func testS6Scroll() throws {
        openChat(Chat.a)
        SMS.mark("scroll-up")
        drag(CGPoint(x: 201, y: 300), CGPoint(x: 201, y: 750), velocity: 1500)
        SMS.pause(2.0)
        still("s6-scrolled-up")
        SMS.mark("scroll-down")
        drag(CGPoint(x: 201, y: 750), CGPoint(x: 201, y: 250), velocity: 1500)
        SMS.pause(2.0)
        SMS.mark("status-bar-tap")
        drag(CGPoint(x: 201, y: 300), CGPoint(x: 201, y: 700), velocity: 2500)
        SMS.pause(1.0)
        pt(201, 20).tap()
        SMS.pause(1.5)
        still("s6-after-statusbar-tap")
        SMS.mark("fling-bottom")
        app.swipeUp(velocity: .fast)
        SMS.pause(2.0)
    }

    // MARK: 7. Stills (run once in light, once in dark)

    func testS7Stills() throws {
        let mode = ProcessInfo.processInfo.environment["CNM_MODE"] ?? "dark"
        still("s7-\(mode)-list")
        dump("S7-LIST")
        openChat(Chat.a)
        SMS.pause(0.8)
        still("s7-\(mode)-transcript-a")
        dump("S7-TRANSCRIPT-BOTTOM")
        pt(201, 20).tap()
        SMS.pause(1.5)
        still("s7-\(mode)-transcript-a-top")
        dump("S7-TRANSCRIPT-TOP")
        app.textFields["messageBodyField"].tap()
        SMS.pause(1.2)
        app.textFields["messageBodyField"].typeText("Draft text")
        SMS.pause(0.8)
        still("s7-\(mode)-composer-keyboard")
        dump("S7-COMPOSER")
        app.textFields["messageBodyField"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        dismissKeyboardIfNeeded()
        let receivedCells = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "+1"))
        if let received = receivedCells.allElementsBoundByIndex.last(where: { $0.isHittable }) {
            received.press(forDuration: 1.0)
            SMS.pause(1.2)
            still("s7-\(mode)-tapback-menu")
        }
        dismissMenu()
        openChat(Chat.b)
        SMS.pause(0.8)
        still("s7-\(mode)-transcript-b")
        dump("S7-TRANSCRIPT-B")
        SMS.goToList(app)
    }
}
