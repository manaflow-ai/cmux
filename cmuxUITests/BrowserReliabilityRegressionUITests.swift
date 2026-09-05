import XCTest
import Foundation

/// Socket-level regressions for browser automation reliability.
///
/// Shares the launch/socket harness with `BrowserFixtureSocketTestCase`
/// (defined in BrowserFixtureInteractionUITests.swift).
final class BrowserReliabilityRegressionUITests: BrowserFixtureSocketTestCase {

    /// Regression: browser.navigate used to acknowledge only that WKWebView.load
    /// was called. After a connection-refused error page, a slow recovered origin
    /// therefore returned `ok` while the old error-page DOM was still active.
    /// Success must mean that the requested document actually committed.
    func testGotoWaitsForRecoveredDocumentCommitAfterConnectionRefusal() throws {
        try launchApp()
        let sid = try openBrowserSurface()
        let server = try BrowserRecoveryHTTPServer()
        let failedURL = "http://127.0.0.1:\(server.port)/unavailable"
        let recoveredURL = "http://127.0.0.1:\(server.port)/recovered"

        XCTAssertNotNil(
            socketEnvelope(
                method: "browser.navigate",
                params: ["surface_id": sid, "url": failedURL],
                responseTimeout: 15
            ),
            "Expected the refused navigation to reach a terminal response"
        )
        try socketResult(
            method: "browser.wait",
            params: [
                "surface_id": sid,
                "text": "refused to connect",
                "timeout_ms": 10_000,
            ],
            responseTimeout: 15
        )

        try server.start()
        defer { server.stop() }

        let pendingNavigation = try beginPendingSocketRequest(
            method: "browser.navigate",
            params: ["surface_id": sid, "url": recoveredURL],
            responseTimeout: 15
        )
        defer { closePendingSocketRequest(pendingNavigation) }
        try server.waitForRequest()
        let returnedBeforeResponseRelease = pendingSocketResponseIsReady(pendingNavigation)
        try server.releaseResponse()

        let navigationEnvelope = try XCTUnwrap(
            finishPendingSocketRequest(pendingNavigation),
            "Expected browser.navigate to return after the recovered response was released"
        )
        XCTAssertEqual(
            navigationEnvelope["ok"] as? Bool,
            true,
            "browser.navigate failed after the recovered response was released: \(navigationEnvelope)"
        )
        XCTAssertFalse(
            returnedBeforeResponseRelease,
            "browser.navigate returned before the recovered response could commit"
        )
        XCTAssertEqual(
            try evalString(
                "document.body.dataset.cmuxRecovered || ''",
                surfaceID: sid
            ),
            "true",
            "browser.navigate returned success before the recovered document committed"
        )

        let sameDocumentURL = recoveredURL + "#verified"
        let sameDocumentEnvelope = try XCTUnwrap(
            socketEnvelope(
                method: "browser.navigate",
                params: ["surface_id": sid, "url": sameDocumentURL],
                responseTimeout: 15
            ),
            "Expected a terminal response for the same-document navigation"
        )
        XCTAssertEqual(
            sameDocumentEnvelope["ok"] as? Bool,
            true,
            "same-document browser.navigate failed: \(sameDocumentEnvelope)"
        )
        XCTAssertEqual(
            try evalString("window.location.hash", surfaceID: sid),
            "#verified",
            "same-document browser.navigate returned before the trusted document event"
        )
        XCTAssertEqual(
            try evalString("document.body.dataset.cmuxRecovered || ''", surfaceID: sid),
            "true",
            "the fragment navigation unexpectedly replaced the recovered document"
        )
    }

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

    /// End-to-end browser-engine smoke: a real pane must render a document,
    /// expose its DOM/title, produce a non-empty PNG, and release cleanly before
    /// another pane is opened.  When the CI artifact contains CEF, the shared
    /// fixture harness requests Chromium and verifies the returned engine.
    func testBrowserEngineSmokeRendersEvaluatesScreenshotsAndReopens() throws {
        try launchApp()
        let firstSurface = try openFixture("csp-no-unsafe-eval")

        XCTAssertEqual(
            try evalString("document.title", surfaceID: firstSurface),
            "csp-no-unsafe-eval",
            "the browser engine must commit a document that can be evaluated"
        )

        let firstOrigin = try BrowserRecoveryHTTPServer()
        let secondOrigin = try BrowserRecoveryHTTPServer()
        try firstOrigin.start()
        try secondOrigin.start()
        defer {
            firstOrigin.stop()
            secondOrigin.stop()
        }

        func navigateThroughHeldResponse(
            _ server: BrowserRecoveryHTTPServer,
            path: String
        ) throws {
            let request = try beginPendingSocketRequest(
                method: "browser.navigate",
                params: [
                    "surface_id": firstSurface,
                    "url": "http://127.0.0.1:\(server.port)\(path)",
                ],
                responseTimeout: 20.0
            )
            defer { closePendingSocketRequest(request) }
            try server.waitForRequest()
            try server.releaseResponse()
            let envelope = try XCTUnwrap(
                finishPendingSocketRequest(request),
                "Expected navigation response from origin \(server.port)"
            )
            XCTAssertEqual(envelope["ok"] as? Bool, true, "Navigation failed: \(envelope)")
            try socketResult(
                method: "browser.wait",
                params: [
                    "surface_id": firstSurface,
                    "load_state": "complete",
                    "timeout_ms": 10_000,
                ],
                responseTimeout: 16.0
            )
        }

        // Same-origin navigation must commit twice on the first origin.
        try navigateThroughHeldResponse(firstOrigin, path: "/same-origin")
        XCTAssertEqual(
            try evalString("window.location.port", surfaceID: firstSurface),
            String(firstOrigin.port)
        )
        try navigateThroughHeldResponse(firstOrigin, path: "/same-origin?second")
        XCTAssertEqual(
            try evalString("window.location.port", surfaceID: firstSurface),
            String(firstOrigin.port)
        )

        // A different loopback port is a distinct origin. This catches stale
        // renderer/CDP targets that appear healthy while navigation is still
        // attached to the prior origin.
        try navigateThroughHeldResponse(secondOrigin, path: "/cross-origin")
        XCTAssertEqual(
            try evalString("window.location.port", surfaceID: firstSurface),
            String(secondOrigin.port)
        )
        XCTAssertEqual(
            try evalString("document.body.dataset.cmuxRecovered || ''", surfaceID: firstSurface),
            "true"
        )

        let screenshot = try socketResult(
            method: "browser.screenshot",
            params: ["surface_id": firstSurface],
            responseTimeout: 20.0
        )
        let pngBase64 = try XCTUnwrap(
            screenshot["png_base64"] as? String,
            "browser.screenshot must return PNG data"
        )
        let png = try XCTUnwrap(
            Data(base64Encoded: pngBase64),
            "browser.screenshot returned invalid base64"
        )
        XCTAssertGreaterThan(png.count, 128, "browser.screenshot returned an empty image")
        XCTAssertTrue(
            png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            "browser.screenshot must return a PNG signature"
        )
        if png.count >= 24 {
            let width = png[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let height = png[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            XCTAssertGreaterThan(width, 10, "browser.screenshot width is invalid")
            XCTAssertGreaterThan(height, 10, "browser.screenshot height is invalid")
        } else {
            XCTFail("browser.screenshot PNG is too short to contain dimensions")
        }

        let closed = try socketResult(
            method: "browser.tab.close",
            params: ["surface_id": firstSurface],
            responseTimeout: 15.0
        )
        XCTAssertEqual(
            closed["surface_id"] as? String,
            firstSurface,
            "browser.tab.close must close the requested browser surface"
        )

        let reopenedSurface = try openFixture("sticky-input")
        XCTAssertNotEqual(
            reopenedSurface,
            firstSurface,
            "a closed browser surface must not be reused as a stale live handle"
        )
        XCTAssertEqual(
            try evalString("document.title", surfaceID: reopenedSurface),
            "sticky-input",
            "a browser pane must render normally after close/reopen"
        )
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
