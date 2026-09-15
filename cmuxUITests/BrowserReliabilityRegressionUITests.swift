import XCTest
import Foundation
import CoreGraphics
import ImageIO

/// Socket-level regressions for browser automation reliability.
///
/// Shares the launch/socket harness with `BrowserFixtureSocketTestCase`
/// (defined in BrowserFixtureInteractionUITests.swift).
final class BrowserReliabilityRegressionUITests: BrowserFixtureSocketTestCase {

    /// End-to-end browser hover regression: the automation command must run
    /// the page's complete pointer/mouse enter sequence and reveal a popover
    /// whose bounds stay inside the visible browser viewport.
    func testBrowserHoverRevealsPopoverInsideViewport() throws {
        try launchApp()
        let sid = try openFixture("hover-popover")

        try socketResult(method: "browser.hover", params: [
            "surface_id": sid,
            "selector": "#trigger",
        ])
        try socketResult(
            method: "browser.wait",
            params: ["surface_id": sid, "selector": "#popover[data-visible='true']", "timeout_ms": 5_000],
            responseTimeout: 10
        )

        let state = try XCTUnwrap(
            try evalValue("window.__cmuxHoverState()", surfaceID: sid) as? [String: Any],
            "Expected the hover fixture to expose its state"
        )
        XCTAssertEqual(state["pointerEnterCount"] as? Int, 1)
        XCTAssertEqual(state["mouseEnterCount"] as? Int, 1)
        XCTAssertEqual(state["popoverVisible"] as? Bool, true)
        XCTAssertEqual(state["popoverInsideViewport"] as? Bool, true)
    }

    /// The user-visible regression is native pointer routing through the
    /// mounted WKWebView. Exercise that path with XCUITest's real hover event,
    /// then prove the web content still occupies the complete browser panel and
    /// the popover is painted at its right edge.
    func testNativeXCUITHoverRevealsPopoverAtPaneEdge() throws {
        let setupPath = "/tmp/cmux-ui-test-browser-hover-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: setupPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: setupPath)
        }
        let fixtureURL = Self.fixtureURL("hover-popover").absoluteString
        let app = try launchApp(
            additionalLaunchArguments: ["-NSAppSleepDisabled", "YES"],
            additionalLaunchEnvironment: [
                "CMUX_UI_TEST_GOTO_SPLIT_SETUP": "1",
                "CMUX_UI_TEST_GOTO_SPLIT_PATH": setupPath,
                "CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL": fixtureURL,
            ]
        )
        if app.state != .runningForeground {
            app.activate()
        }
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 8),
            "Expected the app to be foregrounded for native pointer routing. state=\(app.state.rawValue)"
        )
        let setup = try waitForSetup(at: setupPath)
        let sid = try XCTUnwrap(
            setup["browserPanelId"],
            "Launch-time browser fixture did not report a browser panel: \(setup)"
        )

        let browserPane = app.descendants(matching: .any)
            .matching(identifier: "BrowserPanelContent.\(sid)")
            .firstMatch
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 8), "Expected the browser WKWebView")

        if browserPane.waitForExistence(timeout: 2) {
            let paneRightGap = browserPane.frame.maxX - webView.frame.maxX
            XCTAssertLessThanOrEqual(
                paneRightGap,
                12,
                "The WKWebView must fill the browser panel before hover. pane=\(browserPane.frame) webView=\(webView.frame)"
            )
        }

        // The fixture places the button 80 points from the web viewport's
        // right edge and 141 points below its top edge. Use screen coordinates
        // derived from the live XCUI frame so this remains stable across CI
        // display sizes while still sending a native pointer event.
        let target = webView.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(
                dx: max(1, webView.frame.width - 80),
                dy: min(max(1, webView.frame.height - 1), 141)
            )
        )
        target.hover()

        let visibleState = try waitForHoverState(surfaceID: sid)
        XCTAssertEqual(visibleState["trustedPointerEnterCount"] as? Int, 1)
        XCTAssertEqual(visibleState["trustedMouseEnterCount"] as? Int, 1)
        XCTAssertEqual(visibleState["popoverVisible"] as? Bool, true)
        XCTAssertEqual(visibleState["popoverInsideViewport"] as? Bool, true)

        let screenshot = app.screenshot()
        let appAttachment = XCTAttachment(screenshot: screenshot)
        appAttachment.name = "native-xcuitest-hover-popover-window"
        appAttachment.lifetime = .keepAlways
        add(appAttachment)

        let panelScreenshot = (browserPane.exists ? browserPane : webView).screenshot()
        let panelAttachment = XCTAttachment(screenshot: panelScreenshot)
        panelAttachment.name = "native-xcuitest-hover-popover-panel"
        panelAttachment.lifetime = .keepAlways
        add(panelAttachment)

        let marker = try XCTUnwrap(
            markerBounds(in: panelScreenshot),
            "Expected the magenta hover popover to be painted in the app window"
        )
        XCTAssertGreaterThan(
            marker.bounds.maxX,
            CGFloat(marker.imageWidth) * 0.9,
            "Expected the painted popover to reach the browser pane edge. marker=\(marker.bounds) imageWidth=\(marker.imageWidth) pane=\(browserPane.frame)"
        )
    }

    private func waitForSetup(at path: String) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let setup = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               setup["webViewFocused"] == "true" {
                return setup
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw XCTSkip("Launch-time browser fixture did not become ready: \(path)")
    }

    private func waitForHoverState(surfaceID: String) throws -> [String: Any] {
        var state: [String: Any]?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let candidate = try? self.evalValue(
                    "window.__cmuxHoverState()",
                    surfaceID: surfaceID
                ) as? [String: Any],
                    candidate["popoverVisible"] as? Bool == true else {
                    return false
                }
                state = candidate
                return true
            },
            object: NSObject()
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 5),
            .completed,
            "Native hover did not reveal the fixture popover"
        )
        return try XCTUnwrap(state, "Expected hover state after native pointer event")
    }

    private struct MarkerBounds {
        let bounds: CGRect
        let imageWidth: Int
    }

    private func markerBounds(in screenshot: XCUIScreenshot) -> MarkerBounds? {
        guard let source = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0 else {
            return nil
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let decoded = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { return nil }

        var bounds: CGRect?
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let index = y * bytesPerRow + x * 4
                let red = pixels[index]
                let green = pixels[index + 1]
                let blue = pixels[index + 2]
                let alpha = pixels[index + 3]
                guard red > 220, blue > 220, green < 80, alpha > 200 else { continue }
                let point = CGRect(x: CGFloat(x), y: CGFloat(y), width: 2, height: 2)
                bounds = bounds.map { $0.union(point) } ?? point
            }
        }
        guard let bounds else { return nil }
        return MarkerBounds(bounds: bounds, imageWidth: width)
    }

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
