import XCTest

/// Behavior gates for the DEBUG chat lab (`CMUX_CHAT_LAB=1`). The headline test
/// proves the message list stays glued to the composer through an interactive
/// swipe-to-dismiss: the in-app `CADisplayLink` probe records the per-frame
/// residual between the composer's real (presentation-layer) top and where the
/// list's applied inset implies it should be, and publishes max/mean/n via the
/// `ChatLabTrackProbe` accessibility value. A correctly-synced drag keeps the
/// max within a couple of points; the old notification-frozen approach would
/// diverge to the full keyboard travel.
///
/// Runs on a real device / CI (XCUITest cannot sample per frame itself, so the
/// in-process probe does the sampling and the test only drives + reads back).
final class ChatLabUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_CHAT_LAB"] = "1"
        app.launchEnvironment["CMUX_CHAT_FIXTURE"] = fixture
        app.launch()
        return app
    }

    private func parseProbe(_ value: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for pair in value.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let number = Double(kv[1]) { out[String(kv[0])] = number }
        }
        return out
    }

    /// The composer must track the keyboard through an interactive dismiss.
    func testComposerTracksKeyboardThroughInteractiveDismiss() throws {
        let app = launch(fixture: "wrapping")
        let list = app.otherElements["ChatLabList"]
        XCTAssertTrue(list.waitForExistence(timeout: 15), "chat lab did not render")

        // Raise the keyboard.
        let field = app.textViews["ChatLabComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("tracking test")

        // Interactive swipe-to-dismiss: drag down on the list while the keyboard
        // is up, at a moderate velocity, then hold so the probe samples settle.
        let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let bottom = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        top.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .default, thenHoldForDuration: 0.1)

        let probe = app.otherElements["ChatLabTrackProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let values = parseProbe(probe.value as? String ?? "")

        let samples = values["n"] ?? 0
        XCTAssertGreaterThan(samples, 10, "probe collected too few frames: \(probe.value ?? "nil")")
        let maxDelta = values["max"] ?? .greatestFiniteMagnitude
        XCTAssertLessThanOrEqual(maxDelta, 4.0, "composer/list tracking drifted: \(probe.value ?? "nil")")
    }

    /// Tapping the list (a message or negative space) dismisses the keyboard.
    func testTappingListDismissesKeyboard() throws {
        let app = launch(fixture: "wrapping")
        let list = app.otherElements["ChatLabList"]
        XCTAssertTrue(list.waitForExistence(timeout: 15))

        let field = app.textViews["ChatLabComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "keyboard did not appear")

        // Tap in the list's upper area (a message / negative space), not the composer.
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.keyboards.element)
        waitForExpectations(timeout: 5)
    }

    /// Scrolling a large history must stay smooth (hitch gate, soft).
    func testLargeHistoryScrollPerformance() throws {
        let app = launch(fixture: "history-10k")
        let list = app.otherElements["ChatLabList"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        let metrics: [XCTMetric] = [
            XCTOSSignpostMetric.scrollingAndDecelerationMetric,
            XCTHitchMetric(waitUntilStable: true),
        ]
        measure(metrics: metrics) {
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
    }
}
