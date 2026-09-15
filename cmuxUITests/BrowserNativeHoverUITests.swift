import XCTest
import Foundation
import CoreGraphics
import ImageIO

/// Uses the macOS pointer path, with page state exposed through accessibility.
/// No browser.hover or JavaScript event dispatch can satisfy these assertions.
final class BrowserNativeHoverUITests: XCTestCase {
    func testNativeHoverEntersLeavesAndReentersBrowserContent() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let app: XCUIApplication
        if let bundleID = environment["CMUX_HOVER_TEST_APP_BUNDLE_ID"] {
            // A standalone runner can test the reporter's OS against a
            // cloud-built tagged app without rebuilding or launching main.
            XCTAssertTrue(bundleID.hasPrefix("com.cmuxterm.app.debug."))
            app = XCUIApplication(bundleIdentifier: bundleID)
            app.activate()
        } else {
            app = XCUIApplication.cmuxTestApplication()
            app.launchEnvironment["CMUX_TAG"] = "hover-ui-\(UUID().uuidString.prefix(8))"
            app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"] = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("BrowserFixtures/hover-popover.html")
                .absoluteString
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            addTeardownBlock { app.terminate() }
        }

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15), "Browser web content must be accessible")
        let trigger = webView.buttons["Hover me"].firstMatch
        XCTAssertTrue(trigger.waitForExistence(timeout: 10), "Hover fixture must finish loading")
        let blank = webView.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 40))
        let target = trigger.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let active = webView.staticTexts["Native hover active"].firstMatch
        let idle = webView.staticTexts["Native hover idle"].firstMatch

        blank.hover()
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        capture(app, name: "native-hover-before")
        for attempt in 1...2 {
            target.hover()
            let didEnter = active.waitForExistence(timeout: 5)
            let screenshot = webView.screenshot()
            capture(app, name: "native-hover-enter-\(attempt)")
            XCTAssertTrue(didEnter, "Native pointer/mouse enter and CSS :hover must all activate")
            XCTAssertTrue(
                hasPaintedHoverMarkers(screenshot),
                "The screenshot must contain the CSS hover highlight and the complete popover"
            )
            blank.hover()
            let didLeave = idle.waitForExistence(timeout: 5)
            capture(app, name: "native-hover-leave-\(attempt)")
            XCTAssertTrue(didLeave, "Moving away must deliver mouseleave and dismiss the popover")
        }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func hasPaintedHoverMarkers(_ screenshot: XCUIScreenshot) -> Bool {
        guard let source = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard decoded else { return false }
        var magenta = 0
        var green = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[index], g = pixels[index + 1], b = pixels[index + 2]
            if r > 220 && g < 80 && b > 220 { magenta += 1 }
            if r < 80 && g > 220 && b < 80 { green += 1 }
        }
        // Both markers cover thousands of pixels even on a 1x display.
        return magenta > 5_000 && green > 1_000
    }
}
