import XCTest
import Foundation

/// End-to-end coverage for external-open rule routing in the embedded
/// browser. The app launches with a rule matching `127.0.0.1:8397` and with
/// `CMUX_UI_TEST_CAPTURE_EXTERNAL_OPEN_PATH` configured, so system-browser
/// escapes are written to a capture file instead of launching a real
/// browser. Clicks are delivered through the socket `browser.click` (real
/// WebKit link activations), which is exactly the layer where routing bugs
/// live — matcher unit tests cannot see delegate wiring.
final class BrowserExternalOpenRoutingUITests: BrowserFixtureSocketTestCase {
    private var capturePath = ""

    override var extraLaunchArguments: [String] {
        ["-browserExternalOpenPatterns", "127.0.0.1:8397"]
    }

    override var extraLaunchEnvironment: [String: String] {
        ["CMUX_UI_TEST_CAPTURE_EXTERNAL_OPEN_PATH": capturePath]
    }

    override func setUp() {
        super.setUp()
        capturePath = "/tmp/cmux-ui-test-external-open-\(UUID().uuidString).log"
        try? FileManager.default.removeItem(atPath: capturePath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: capturePath)
        super.tearDown()
    }

    private func captureLines() -> [String] {
        (try? String(contentsOfFile: capturePath, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    private func waitForCaptureLine(
        containing needle: String,
        timeout: TimeInterval = 10.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if captureLines().contains(where: { $0.contains(needle) }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    func testMatchedLinkClickEscapesToSystemBrowser() throws {
        try launchApp()
        let sid = try openFixture("external-open-routing")
        try waitForSelector("#matched-link", surfaceID: sid)
        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#matched-link"])
        XCTAssertTrue(
            waitForCaptureLine(containing: "http://127.0.0.1:8397/matched"),
            "Expected matched link click to escape to the system browser. capture=\(captureLines())"
        )
        XCTAssertTrue(
            captureLines().contains { $0.hasPrefix("navDelegate.escape ") },
            "Expected the escape to route through the navigation-delegate hook. capture=\(captureLines())"
        )
        // The embedded page must not have navigated to the matched URL.
        let href = try evalString("location.href", surfaceID: sid)
        XCTAssertTrue(
            href.hasSuffix("external-open-routing.html"),
            "Embedded page navigated away after an escape: \(href)"
        )
    }

    func testUnmatchedLinkClickStaysEmbedded() throws {
        try launchApp()
        let sid = try openFixture("external-open-routing")
        try waitForSelector("#unmatched-link", surfaceID: sid)
        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#unmatched-link"])
        try socketResult(
            method: "browser.wait",
            params: ["surface_id": sid, "load_state": "complete", "timeout_ms": 10_000],
            responseTimeout: 16.0
        )
        let href = try evalString("location.href", surfaceID: sid)
        XCTAssertTrue(
            href.hasSuffix("external-open-target.html"),
            "Expected unmatched link to navigate embedded, got: \(href)"
        )
        XCTAssertEqual(captureLines(), [], "Unmatched navigation must not touch the system browser")
    }

    func testScriptedWindowOpenToMatchedURLNeverEscapes() throws {
        try launchApp()
        let sid = try openFixture("external-open-routing")
        try waitForSelector("#popup-button", surfaceID: sid)
        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#popup-button"])
        // Affirmative: window.open must actually open an embedded tab (proves it
        // fired and stayed embedded, not that it silently no-op'd), and it must
        // not reach the system browser.
        let popupOpenedEmbedded = try waitForEmbeddedTab(urlContaining: "127.0.0.1:8397")
        let tabsAfterPopup = try openTabURLs()
        XCTAssertTrue(
            popupOpenedEmbedded,
            "Scripted window.open should open an embedded tab. tabs=\(tabsAfterPopup)"
        )
        XCTAssertFalse(
            captureLines().contains { $0.contains("/popup") },
            "Scripted window.open must never reach the system browser. capture=\(captureLines())"
        )
    }

    func testFormPostTargetBlankToMatchedHostStaysEmbedded() throws {
        try launchApp()
        let sid = try openFixture("external-open-routing")
        try waitForSelector("#post-submit", surfaceID: sid)
        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#post-submit"])
        // Affirmative: the POST must open an embedded tab at the matched host
        // (proves the submission happened and stayed embedded, keeping its body
        // rather than being dropped or re-issued as a GET in the system browser),
        // and it must not reach the system browser.
        let postOpenedEmbedded = try waitForEmbeddedTab(urlContaining: "127.0.0.1:8397")
        let tabsAfterPost = try openTabURLs()
        XCTAssertTrue(
            postOpenedEmbedded,
            "target=_blank form POST should open an embedded tab. tabs=\(tabsAfterPost)"
        )
        XCTAssertFalse(
            captureLines().contains { $0.contains("/post") },
            "A form POST must keep its body embedded, never escape as a GET. capture=\(captureLines())"
        )
    }
}
