import XCTest

final class IntelCmdDSmokeUITests: XCTestCase {
    private let launchTag = "ui-tests-intel-cmd-d-smoke"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchAndCmdDDoesNotCrash() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAndEnsureStarted(app)

        XCTAssertTrue(
            waitForWindowCount(app: app, atLeast: 1, timeout: 12.0),
            "Expected app to open a window before Cmd+D. state=\(app.state.rawValue)"
        )

        app.typeKey("d", modifierFlags: [.command])

        XCTAssertTrue(
            waitForWindowCount(app: app, atLeast: 1, timeout: 5.0),
            "Expected app window to stay open after Cmd+D. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForAppToKeepRunning(app: app, timeout: 5.0),
            "Expected app to keep running after Cmd+D. state=\(app.state.rawValue)"
        )
    }

    private func launchAndEnsureStarted(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground || app.state == .runningBackground {
            return
        }

        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func waitForWindowCount(app: XCUIApplication, atLeast count: Int, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.windows.count >= count
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForAppToKeepRunning(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.state != .notRunning
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
