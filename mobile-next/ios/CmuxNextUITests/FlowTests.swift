import XCTest

/// Drives the real app against the live backend and a real Mac for recorded
/// verification runs. Inputs come from the environment:
/// `CNM_TEST_EMAIL`, `CNM_TEST_CODE` (test sign-in), `CNM_PAIR_CODE`.
final class FlowTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
    }

    func testLaunchShowsWelcome() {
        let app = XCUIApplication()
        app.launchArguments = ["-cnm-reset", "-cnm-email-auth"]
        app.launch()
        XCTAssertTrue(app.buttons["auth.apple"].waitForExistence(timeout: 10))
        pause(3)
        snap(app, "welcome")
    }

    /// Sign up with email, verify the code, pair the Mac.
    func testSignUpAndPair() throws {
        let email = try XCTUnwrap(env["CNM_TEST_EMAIL"])
        let code = try XCTUnwrap(env["CNM_TEST_CODE"])
        let app = XCUIApplication()
        app.launchArguments = ["-cnm-reset", "-cnm-email-auth"]
        app.launch()

        XCTAssertTrue(app.buttons["auth.signup"].waitForExistence(timeout: 10))
        pause(2.5)
        snap(app, "01-welcome")
        app.buttons["auth.signup"].tap()
        let field = app.textFields["auth.email"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        pause(0.8)
        field.typeText(email)
        snap(app, "02-email")
        app.buttons["auth.continue"].tap()

        let codeField = app.textFields["auth.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15))
        pause(0.8)
        snap(app, "03-code")
        codeField.typeText(code)

        XCTAssertTrue(app.buttons["shell.menu"].waitForExistence(timeout: 20))
        pause(1)
        snap(app, "04-home-empty")

        if let pairCode = env["CNM_PAIR_CODE"], !pairCode.isEmpty {
            let add = app.buttons["home.addMac"]
            if add.waitForExistence(timeout: 4) {
                add.tap()
            } else {
                app.buttons["shell.menu"].tap()
                pause(1)
                app.buttons["sidebar.macs"].tap()
                let macsAdd = app.buttons["macs.add"]
                XCTAssertTrue(macsAdd.waitForExistence(timeout: 10))
                macsAdd.tap()
            }
            let codeBox = app.textFields["addmac.code"]
            XCTAssertTrue(codeBox.waitForExistence(timeout: 5))
            codeBox.typeText(pairCode)
            pause(0.5)
            snap(app, "05-pair-code")
            app.buttons["addmac.pair"].tap()
            pause(1.5)
            snap(app, "06a-awaiting-approval")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'is paired'")).firstMatch.waitForExistence(timeout: 30))
            snap(app, "06-paired")
            app.buttons["addmac.pair"].tap()
        }
        if env["CNM_PAIR_CODE"]?.isEmpty == false { return }
        // Wait for the Mac to connect and Chief's conversation to appear.
        let chief = app.descendants(matching: .any)["home.pin.cv_chief"]
        XCTAssertTrue(chief.waitForExistence(timeout: 60), "Chief conversation never appeared")
        pause(1.5)
        snap(app, "07-home-connected")
    }

    /// Assumes a signed-in, paired app (run after testSignUpAndPair).
    func testChiefConversation() throws {
        let app = launchSignedIn()
        let chief = app.descendants(matching: .any)["home.pin.cv_chief"]
        XCTAssertTrue(chief.waitForExistence(timeout: 60))
        pause(1)
        chief.tap()
        let field = app.textFields["conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        pause(1)
        snap(app, "10-chief-open")
        field.tap()
        pause(0.8)
        field.typeText("Hey Chief, what can you do from here?")
        pause(0.6)
        snap(app, "11-chief-typed")
        app.buttons["conversation.send"].tap()
        pause(1.5)
        snap(app, "12-chief-sent")
        // Wait for a reply bubble.
        pause(25)
        snap(app, "13-chief-reply")
        app.swipeDown()
        pause(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1.5)
        snap(app, "14-home-after")
    }

    func testDrawerAndAgent() throws {
        let app = launchSignedIn()
        XCTAssertTrue(app.buttons["shell.menu"].waitForExistence(timeout: 30))
        pause(4)
        app.buttons["shell.menu"].tap()
        pause(1.2)
        snap(app, "20-drawer")
        app.buttons["sidebar.new"].tap()
        let field = app.textFields["agent.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        pause(2)
        snap(app, "21-new-agent")
        field.tap()
        field.typeText("List the files in this folder and tell me what this project is, in two sentences.")
        pause(0.5)
        app.buttons["agent.send"].tap()
        pause(6)
        snap(app, "22-agent-working")
        pause(40)
        snap(app, "23-agent-done")
        app.swipeDown()
        pause(1)
        snap(app, "24-agent-final")
    }

    func testTerminal() throws {
        let app = launchSignedIn()
        XCTAssertTrue(app.buttons["shell.menu"].waitForExistence(timeout: 30))
        pause(4)
        app.buttons["shell.menu"].tap()
        pause(1)
        app.buttons["sidebar.terminals"].tap()
        let newTerminal = app.buttons.matching(identifier: "terminals.new").element(boundBy: 0)
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 20))
        pause(1)
        snap(app, "30-terminals")
        newTerminal.tap()
        pause(4)
        snap(app, "31-terminal")
        app.buttons["terminal.keyboard"].tap()
        pause(1.5)
        app.typeText("echo hello from $(hostname) && ls -la | head -12\n")
        pause(3)
        snap(app, "32-terminal-output")
    }

    /// Drawer: tap open, tap-dim close, drag open, drag closed, for frame analysis.
    func testDrawerAnimation() throws {
        let app = launchSignedIn()
        pause(3)
        app.buttons["shell.menu"].tap()
        pause(1.2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        pause(1.2)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.56)), withVelocity: .default, thenHoldForDuration: 0)
        pause(1.2)
        let open = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        open.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: 0)
        pause(1.5)
    }

    /// An agent edit that needs approval: permission card, allow, diff row.
    func testAgentPermission() throws {
        let app = launchSignedIn()
        pause(4)
        app.buttons["shell.menu"].tap()
        pause(1)
        app.buttons["sidebar.new"].tap()
        let field = app.textFields["agent.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        pause(2)
        XCTAssertEqual(app.buttons["new.project"].label, "demo-app")
        snap(app, "50-new-demo")
        field.tap()
        field.typeText("Add a function farewell(name) to greet.py that returns 'bye ' + name. Edit the file directly.")
        app.buttons["agent.send"].tap()
        let allow = app.buttons["permission.allow_once"]
        if allow.waitForExistence(timeout: 120) {
            pause(1)
            snap(app, "51-permission")
            allow.tap()
            pause(2)
            snap(app, "52-allowed")
        } else {
            snap(app, "51-no-permission")
        }
        pause(25)
        app.swipeDown()
        snap(app, "53-done")
        let field2 = app.textFields["agent.field"]
        field2.tap()
        field2.typeText("Now show me the final greet.py.")
        snap(app, "54-followup-typed")
        app.buttons["agent.send"].tap()
        pause(0.6)
        snap(app, "55-followup-sent")
        pause(20)
        snap(app, "56-followup-reply")
    }

    /// Messages parity run: new conversation, two sends, reply, back to list.
    func testMessagesParity() throws {
        let app = launchSignedIn()
        pause(4)
        snap(app, "60-home")
        app.buttons["home.compose"].tap()
        let field = app.textFields["conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        pause(1.2)
        snap(app, "61-new-conversation")
        field.tap()
        pause(1.0)
        snap(app, "62-keyboard")
        field.typeText("Running a bit late")
        pause(0.5)
        snap(app, "63-typed")
        app.buttons["conversation.send"].tap()
        pause(1.5)
        field.typeText("Can you check on the demo-app agent?")
        pause(0.4)
        app.buttons["conversation.send"].tap()
        pause(1.5)
        snap(app, "64-two-sent")
        pause(25)
        snap(app, "65-reply")
        // Long-press Chief's latest bubble and love it.
        let bubbles = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "agent"))
        if bubbles.count > 0 {
            bubbles.element(boundBy: bubbles.count - 1).press(forDuration: 0.6)
            pause(0.8)
            snap(app, "65b-tapback-menu")
            let heart = app.buttons["tapback.love"]
            XCTAssertTrue(heart.waitForExistence(timeout: 3), "no heart button")
            XCTAssertTrue(heart.isHittable, "heart not hittable at \(heart.frame)")
            heart.tap()
            pause(1.2)
            snap(app, "65c-tapback-badge")
        }
        app.swipeDown()
        pause(1)
        snap(app, "66-keyboard-down")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1.5)
        snap(app, "67-list")
    }

    /// Two Macs on different networks: both connect; a terminal runs on the second.
    func testTwoMacs() throws {
        let app = launchSignedIn()
        app.buttons["shell.menu"].tap()
        pause(1)
        app.buttons["sidebar.macs"].tap()
        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Connected'"))
        let deadline = Date().addingTimeInterval(60)
        while connected.count < 2, Date() < deadline { pause(1) }
        XCTAssertEqual(connected.count, 2, "both Macs should connect")
        snap(app, "70-two-macs")
        app.buttons["shell.menu"].tap()
        pause(1)
        app.buttons["sidebar.terminals"].tap()
        let news = app.buttons.matching(identifier: "terminals.new")
        XCTAssertTrue(news.element(boundBy: 1).waitForExistence(timeout: 20))
        snap(app, "71-terminals-two-macs")
        news.element(boundBy: 1).tap()
        pause(4)
        app.buttons["terminal.keyboard"].tap()
        pause(1)
        app.typeText("echo hi from $(scutil --get ComputerName) on $(sw_vers -productVersion)\n")
        pause(10)
        snap(app, "72-terminal-other-mac")
    }

    /// Attach a library photo to an agent prompt and ask about it.
    func testAgentImage() throws {
        let app = launchSignedIn()
        pause(4)
        app.buttons["shell.menu"].tap()
        pause(1)
        app.buttons["sidebar.new"].tap()
        let field = app.textFields["agent.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        pause(1.5)
        app.buttons["agent.attach"].tap()
        pause(3)
        snap(app, "80-picker")
        // The picker is out of process; tap the first photo in its grid, then Add.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.165, dy: 0.47)).tap()
        pause(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.905, dy: 0.165)).tap()
        pause(2)
        snap(app, "81-attached")
        field.tap()
        field.typeText("What is in this photo? Answer in one sentence.")
        app.buttons["agent.send"].tap()
        pause(35)
        app.swipeDown()
        snap(app, "82-answer")
    }

    /// Slash-command menu and the mode chip in an existing agent chat.
    func testAgentCommandsAndModes() throws {
        let app = launchSignedIn()
        pause(4)
        app.buttons["shell.menu"].tap()
        pause(1)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'What is in this photo'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let field = app.textFields["agent.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        pause(3)
        field.tap()
        field.typeText("/")
        pause(1.2)
        snap(app, "90-slash-menu")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        app.swipeDown()
        pause(0.8)
        app.buttons["agent.mode"].tap()
        pause(1)
        snap(app, "91-mode-menu")
        let plan = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'plan'")).firstMatch
        if plan.waitForExistence(timeout: 3) { plan.tap() }
        pause(1.5)
        snap(app, "92-mode-changed")
    }

    /// Plan mode: the agent plans, then asks to start coding.
    func testAgentPlanMode() throws {
        let app = launchSignedIn()
        pause(4)
        app.buttons["shell.menu"].tap()
        pause(1)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'What is in this photo'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let field = app.textFields["agent.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        pause(2)
        field.tap()
        field.typeText("Plan how to add a --shout flag to greet.py that uppercases the greeting. Keep the plan to 3 steps.")
        app.buttons["agent.send"].tap()
        pause(50)
        snap(app, "93-plan")
        let reject = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'permission.reject'")).firstMatch
        if reject.exists { reject.tap(); pause(2) }
        snap(app, "94-plan-after")
    }

    /// Ask Chief to start an agent; it appears in the drawer.
    func testChiefSpawnsAgent() throws {
        let app = launchSignedIn()
        pause(4)
        app.buttons["home.compose"].tap()
        let field = app.textFields["conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Start a claude agent in /Users/cmux/cnm-projects/demo-app to add a one-line docstring to greet(). Don't wait for it.")
        app.buttons["conversation.send"].tap()
        pause(40)
        snap(app, "95-chief-spawn-reply")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        app.buttons["shell.menu"].tap()
        pause(1.5)
        snap(app, "96-drawer-new-agent")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'docstring'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "spawned agent should be listed")
        row.tap()
        pause(20)
        snap(app, "97-spawned-agent")
    }

    /// Drag left on the transcript to reveal send times (for frame analysis).
    func testTimestampReveal() throws {
        let app = launchSignedIn()
        let chief = app.descendants(matching: .any)["home.pin.cv_chief"]
        XCTAssertTrue(chief.waitForExistence(timeout: 60))
        chief.tap()
        XCTAssertTrue(app.textFields["conversation.field"].waitForExistence(timeout: 10))
        pause(2)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                    withVelocity: 300, thenHoldForDuration: 1.0)
        pause(1.5)
    }

    /// Forces TURN relay and checks the Mac connects through it.
    func testRelayConnection() throws {
        let app = launchSignedIn(arguments: ["-cnm-relay-only"])
        app.buttons["shell.menu"].tap()
        pause(1)
        app.buttons["sidebar.macs"].tap()
        let relay = app.staticTexts["Connected · relay"]
        XCTAssertTrue(relay.waitForExistence(timeout: 60), "Mac never connected through the relay")
        pause(1)
        snap(app, "40-macs-relay")
        app.buttons["shell.menu"].tap()
        pause(1)
        app.buttons["sidebar.terminals"].tap()
        let newTerminal = app.buttons.matching(identifier: "terminals.new").element(boundBy: 0)
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 20))
        newTerminal.tap()
        pause(4)
        app.buttons["terminal.keyboard"].tap()
        pause(1)
        app.typeText("echo relayed from $(hostname)\n")
        pause(3)
        snap(app, "41-terminal-relay")
    }

    /// Signs in with the test account when the app starts signed out.
    private func launchSignedIn(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-cnm-email-auth"]
        app.launch()
        let menu = app.buttons["shell.menu"]
        let login = app.buttons["auth.login"]
        _ = menu.waitForExistence(timeout: 8) || login.waitForExistence(timeout: 2)
        if !menu.exists, login.exists, let email = env["CNM_TEST_EMAIL"], let code = env["CNM_TEST_CODE"] {
            login.tap()
            let field = app.textFields["auth.email"]
            _ = field.waitForExistence(timeout: 5)
            field.typeText(email)
            app.buttons["auth.continue"].tap()
            let codeField = app.textFields["auth.code"]
            _ = codeField.waitForExistence(timeout: 15)
            codeField.typeText(code)
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        return app
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
