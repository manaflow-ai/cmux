import XCTest
import Foundation

/// Socket-level regressions for browser automation reliability.
///
/// Shares the launch/socket harness with `BrowserFixtureSocketTestCase`
/// (defined in BrowserFixtureInteractionUITests.swift).
final class BrowserReliabilityRegressionUITests: BrowserFixtureSocketTestCase {

    /// Regression: a WKWebView that has never committed a navigation has no
    /// JavaScript context, so browser.wait used to hang for its full timeout
    /// (or fail) on a URL-less browser.open_split surface. The surface must
    /// be kicked to about:blank and the wait must return ok promptly.
    func testWaitLoadStateOnNeverNavigatedSurfaceReturnsPromptly() throws {
        try launchApp()
        let sid = try openBrowserSurface()

        // If the regression returns (no about:blank bootstrap), browser.wait
        // hangs for its full internal timeout and then surfaces a timeout/error
        // envelope (or no response at all). A small internal timeout_ms keeps a
        // hang bounded; `ok == true` is the structural proof it returned
        // successfully instead of timing out. We derive the wall-clock bound
        // generously from the injected timeout plus the socket responseTimeout
        // so a heavily loaded CI runner (WebKit content-process spin-up + socket
        // jitter) cannot fail correct code, while an actual unbounded hang still
        // trips the responseTimeout and fails.
        let internalTimeoutMs = 1_500
        let responseTimeout = 12.0
        let start = Date()
        let envelope = socketEnvelope(
            method: "browser.wait",
            params: ["surface_id": sid, "load_state": "complete", "timeout_ms": internalTimeoutMs],
            responseTimeout: responseTimeout
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
            envelope?["ok"] as? Bool,
            true,
            "browser.wait {load_state: complete} on a never-navigated surface should succeed " +
            "(not hang until its \(internalTimeoutMs)ms timeout): the webview's JS context must " +
            "be bootstrapped via about:blank. Envelope: \(String(describing: envelope))"
        )
        // Generous bound: only an unbounded hang (which would itself exceed the
        // socket responseTimeout and yield no ok envelope) can exceed this.
        let durationBound = Double(internalTimeoutMs) / 1_000.0 + responseTimeout
        XCTAssertLessThan(
            elapsed,
            durationBound,
            "browser.wait should resolve well within \(durationBound)s wall-clock on a " +
            "never-navigated surface (took \(elapsed)s); the webview's JS context must be " +
            "bootstrapped via about:blank instead of hanging until the timeout"
        )
    }

    /// Regression: browser.url.get on a never-navigated surface must report
    /// "about:blank" (matching JS location.href) instead of an empty string,
    /// so agents can tell "blank page" from "no data".
    func testURLGetOnNeverNavigatedSurfaceReturnsAboutBlank() throws {
        try launchApp()
        let sid = try openBrowserSurface()

        let result = try socketResult(method: "browser.url.get", params: ["surface_id": sid])
        XCTAssertEqual(result["url"] as? String, "about:blank")
    }

    /// Regression: page CSP without 'unsafe-eval' blocks page-world script
    /// evaluation; browser.eval must fall back to the isolated content world
    /// and still return a result.
    func testEvalSucceedsUnderCSPWithoutUnsafeEval() throws {
        try launchApp()
        let sid = try openFixture("csp-no-unsafe-eval")

        let result = try socketResult(
            method: "browser.eval",
            params: ["surface_id": sid, "script": "document.title"],
            responseTimeout: 15.0
        )
        XCTAssertEqual(
            result["value"] as? String,
            "csp-no-unsafe-eval",
            "browser.eval must succeed under CSP without 'unsafe-eval': \(result)"
        )
    }

    /// Regression: a throwing eval must surface the real JS exception text
    /// (from WKJavaScriptExceptionMessage), not WKError's generic
    /// "A JavaScript exception occurred" localizedDescription.
    func testEvalErrorCarriesRealExceptionText() throws {
        try launchApp()
        let sid = try openBrowserSurface()

        let envelope = try XCTUnwrap(
            socketEnvelope(
                method: "browser.eval",
                params: ["surface_id": sid, "script": "nonexistentFn()"],
                responseTimeout: 15.0
            ),
            "Expected a response for the throwing eval"
        )
        XCTAssertEqual(
            envelope["ok"] as? Bool,
            false,
            "eval of an undefined function should fail: \(envelope)"
        )
        let error = try XCTUnwrap(envelope["error"] as? [String: Any], "Expected error object: \(envelope)")
        let message = try XCTUnwrap(error["message"] as? String, "Expected error message: \(error)")
        XCTAssertTrue(
            message.contains("nonexistentFn"),
            "error message should carry the real exception text naming nonexistentFn, got: \(message)"
        )
        XCTAssertNotEqual(
            message,
            "A JavaScript exception occurred",
            "error message must not be WKError's generic localizedDescription"
        )
    }
}
