import AppKit
import XCTest

/// Checks the compositor output after socket-created Canvas browser splits.
/// A browser snapshot cannot detect a texture painted outside its native view.
final class CanvasBrowserRenderingUITests: BrowserFixtureSocketTestCase {
    func testBrowserPixelsFollowCanvasPaneAfterSocketSplit() throws {
        let app = try launchApp(additionalLaunchArguments: ["-fileExplorer.isVisible", "NO"])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let workspace = try socketResult(
            method: "workspace.create",
            params: ["title": "Canvas browser rendering", "focus": true]
        )
        let workspaceID = try XCTUnwrap(workspace["workspace_id"] as? String)
        let sourceID = try XCTUnwrap(workspace["surface_id"] as? String)
        try socketResult(method: "canvas.set_mode", params: ["workspace_id": workspaceID, "mode": "canvas"])
        try setFrame(surfaceID: sourceID, workspaceID: workspaceID, x: 0, y: 0)

        for iteration in 1...3 {
            // Frame both the source and its right-hand split before opening
            // the browser. Persisted viewport/sidebar state can otherwise put
            // a correctly rendered split outside the captured window.
            try socketResult(
                method: "canvas.set_viewport",
                params: ["workspace_id": workspaceID, "x": 430, "y": 150, "zoom": 0.7]
            )
            let opened = try socketResult(
                method: "browser.open_split",
                params: [
                    "workspace_id": workspaceID,
                    "surface_id": sourceID,
                    "url": Self.fixtureURL("canvas-rendering").absoluteString,
                    "focus": false,
                ],
                responseTimeout: 20
            )
            let browserID = try XCTUnwrap(opened["surface_id"] as? String)
            try socketResult(
                method: "browser.wait",
                params: ["surface_id": browserID, "load_state": "complete", "timeout_ms": 10_000],
                responseTimeout: 15
            )
            let webView = app.webViews.containing(.button, identifier: "Canvas center").firstMatch
            XCTAssertTrue(webView.waitForExistence(timeout: 15))
            try assertAligned(webView: webView, window: window, name: "split-\(iteration)")

            // The moved pane overlaps the source terminal; bring the browser
            // forward so occlusion cannot masquerade as a rendering failure.
            try socketResult(method: "surface.focus", params: ["surface_id": browserID])
            let frameBeforeMove = webView.frame
            try setFrame(surfaceID: browserID, workspaceID: workspaceID, x: 120, y: -60)
            try waitForFrameChange(webView: webView, from: frameBeforeMove, name: "moved-\(iteration)")
            let frameBeforeZoom = webView.frame
            let canvas = try socketResult(method: "canvas.info", params: ["workspace_id": workspaceID])
            let previousZoom = try XCTUnwrap(canvas["magnification"] as? Double)
            XCTAssertGreaterThan(previousZoom, 0)
            let requestedZoom = previousZoom < 0.8 ? 0.9 : 0.7
            try socketResult(
                method: "canvas.set_viewport",
                params: ["workspace_id": workspaceID, "x": 330, "y": 90, "zoom": requestedZoom]
            )
            let zoomRatio = CGFloat(requestedZoom / previousZoom)
            let expectedSize = CGSize(
                width: frameBeforeZoom.width * zoomRatio,
                height: frameBeforeZoom.height * zoomRatio
            )
            let zoomExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    let size = webView.frame.size
                    return abs(size.width - expectedSize.width) < 2 &&
                        abs(size.height - expectedSize.height) < 2
                },
                object: nil
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [zoomExpectation], timeout: 8),
                .completed,
                "Browser must reflect zoom \(requestedZoom) before pixels are sampled; expected \(expectedSize), got \(webView.frame)"
            )
            try assertAligned(webView: webView, window: window, name: "moved-and-zoomed-\(iteration)")

            let other = try socketResult(
                method: "workspace.create",
                params: ["title": "Canvas switch away", "focus": true]
            )
            let otherID = try XCTUnwrap(other["workspace_id"] as? String)
            XCTAssertTrue(
                webView.waitForNonExistence(timeout: 8),
                "Browser should disappear after switching to the focused workspace"
            )
            try socketResult(method: "workspace.select", params: ["workspace_id": workspaceID])
            XCTAssertTrue(
                webView.waitForExistence(timeout: 8),
                "Browser should reappear after restoring the Canvas workspace"
            )
            try assertAligned(webView: webView, window: window, name: "restored-\(iteration)")
            try socketResult(method: "workspace.close", params: ["workspace_id": otherID])
            try socketResult(method: "surface.close", params: ["surface_id": browserID])
        }
    }

    private func setFrame(surfaceID: String, workspaceID: String, x: Double, y: Double) throws {
        try socketResult(
            method: "canvas.set_frame",
            params: [
                "workspace_id": workspaceID, "surface_id": surfaceID,
                "x": x, "y": y, "width": 420, "height": 300,
            ]
        )
    }

    /// Waits for accessibility geometry to reflect the socket canvas mutation.
    private func waitForFrameChange(
        webView: XCUIElement,
        from previousFrame: CGRect,
        name: String,
        timeout: TimeInterval = 8
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = webView.frame
                let changed = abs(frame.minX - previousFrame.minX) > 1 ||
                    abs(frame.minY - previousFrame.minY) > 1 ||
                    abs(frame.width - previousFrame.width) > 1 ||
                    abs(frame.height - previousFrame.height) > 1
                return frame.width > 100 && frame.height > 100 && changed
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Canvas geometry did not update after \(name): \(webView.frame)")
    }

    /// Samples the fixture's edge band inside and outside the accessibility
    /// frame, in an actual window capture rather than a WKWebView snapshot.
    private func assertAligned(webView: XCUIElement, window: XCUIElement, name: String) throws {
        var lastScreenshot = window.screenshot()
        var diagnostic = "No sized browser frame"
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let browserFrame = webView.frame
                let windowFrame = window.frame
                lastScreenshot = window.screenshot()
                guard browserFrame.width > 100, browserFrame.height > 100,
                      windowFrame.contains(browserFrame),
                      let bitmap = NSBitmapImageRep(data: webView.screenshot().pngRepresentation) else {
                    diagnostic = "browser=\(browserFrame), window=\(windowFrame)"
                    return false
                }
                let scaleX = CGFloat(bitmap.pixelsWide) / browserFrame.width
                let scaleY = CGFloat(bitmap.pixelsHigh) / browserFrame.height
                let points: [(CGPoint, Bool)] = [
                    (CGPoint(x: 3, y: browserFrame.height / 2), true),
                    (CGPoint(x: browserFrame.width - 3, y: browserFrame.height / 2), true),
                ]
                for (point, expectedMagenta) in points {
                    let x = Int(point.x * scaleX)
                    let y = Int(point.y * scaleY)
                    guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                          let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        diagnostic = "Unsampleable point \(point); browser=\(browserFrame)"
                        return false
                    }
                    let magenta = color.redComponent > 0.8 && color.greenComponent < 0.3 && color.blueComponent > 0.8
                    if magenta != expectedMagenta {
                        diagnostic = "point=\(point), expectedMagenta=\(expectedMagenta), color=\(color), browser=\(browserFrame)"
                        return false
                    }
                }
                return true
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: 8)
        let attachment = XCTAttachment(screenshot: lastScreenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(result, .completed, "Browser texture must match its Canvas viewport: \(diagnostic)")
    }
}
