import XCTest

/// The embedded Chromium engine's lifecycle in a running app, through the
/// Debug "Chromium Page" probe (`ChromiumDebugWindowController`):
///
/// - `testChromiumPageSurvivesRelayoutAndClose`: a page loads, the window
///   resizes and the page hides and shows (forced relayout), the window closes,
///   and cmux keeps running. Guards the CEF start crash class (allocator zone
///   race, CefAppProtocol conformance) and relayout crashes.
/// - `testMissingRuntimeFallsBackWithoutCrashing`: with no runtime the probe
///   reports `notBundled` and cmux keeps running.
///
/// A build without the CEF artifact cannot render a page; the first test then
/// checks the fallback instead, unless `CMUX_UI_TEST_REQUIRE_CEF=1` (the
/// Chromium lane), where a missing engine fails the test.
final class ChromiumEmbedLifecycleUITests: XCTestCase {
    private static let probeTitle = "cmux-cef-probe"
    private static let probeURL = "data:text/html,%3Ctitle%3E\(probeTitle)%3C%2Ftitle%3E%3Ch1%3Eprobe%3C%2Fh1%3E"
    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    private func launch(environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-tests-cef-\(UUID().uuidString.prefix(8))"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        self.app = app
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        return app
    }

    private func probeStatus(_ app: XCUIApplication) -> XCUIElement {
        app.windows["cmux.chromiumDebug"].staticTexts["cmux.chromiumDebug.status"]
    }

    private func statusText(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    /// Waits until the status line satisfies `matches`; returns the last text.
    private func waitForStatus(_ element: XCUIElement, timeout: TimeInterval,
                               _ matches: @escaping (String) -> Bool) -> (Bool, String) {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement, element.exists else { return false }
            return matches((element.value as? String) ?? element.label)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let met = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        return (met, element.exists ? statusText(element) : "<no status>")
    }

    func testChromiumPageSurvivesRelayoutAndClose() throws {
        let requireEngine = ProcessInfo.processInfo.environment["CMUX_UI_TEST_REQUIRE_CEF"] == "1"
        let app = launch(environment: ["CMUX_CEF_DEBUG_URL": Self.probeURL, "CMUX_CEF_DEBUG_RELAYOUT": "1"])
        let window = app.windows["cmux.chromiumDebug"]
        XCTAssertTrue(window.waitForExistence(timeout: 30), "the Chromium probe window did not open")
        let status = probeStatus(app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "the probe has no status line")

        let (settled, text) = waitForStatus(status, timeout: 90) { text in
            text.contains("relayout done") || text.contains("unavailable") || text.contains("load failed")
        }
        XCTAssertTrue(settled, "Chromium neither loaded nor reported a reason: \(text)")
        if text.contains("unavailable: notBundled"), !requireEngine {
            // A build without the CEF artifact: the engine is reported as not
            // bundled and nothing else happens.
            XCTAssertNotEqual(app.state, .notRunning, "cmux exited without a Chromium engine")
            return
        }
        XCTAssertTrue(text.contains(Self.probeTitle), "the page did not load before the relayout: \(text)")
        XCTAssertTrue(text.contains("relayout done"), "the forced relayout did not finish: \(text)")

        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 15), "the Chromium probe window did not close")
        // The page's browser is destroyed asynchronously; cmux must outlive it.
        let alive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state != %d",
                                                                     XCUIApplication.State.notRunning.rawValue),
                                              object: app)
        XCTAssertEqual(XCTWaiter().wait(for: [alive], timeout: 5), .completed)
        XCTAssertFalse(app.windows["cmux.chromiumDebug"].exists)
        XCTAssertNotEqual(app.state, .notRunning, "cmux exited after the Chromium page closed")
    }

    func testMissingRuntimeFallsBackWithoutCrashing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-no-cef-\(UUID().uuidString)").path
        let app = launch(environment: ["CMUX_CEF_DEBUG_URL": Self.probeURL, "CMUX_CEF_RUNTIME": missing])
        let window = app.windows["cmux.chromiumDebug"]
        XCTAssertTrue(window.waitForExistence(timeout: 30), "the Chromium probe window did not open")
        let (reported, text) = waitForStatus(probeStatus(app), timeout: 20) { $0.contains("Chromium unavailable") }
        XCTAssertTrue(reported, "a missing runtime was not reported: \(text)")
        XCTAssertTrue(text.contains("notBundled"), "unexpected reason: \(text)")
        XCTAssertNotEqual(app.state, .notRunning, "cmux exited without a Chromium runtime")
    }
}
