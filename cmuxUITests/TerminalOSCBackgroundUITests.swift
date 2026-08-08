import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class TerminalOSCBackgroundUITests: XCTestCase {
    private let initialBackground = PixelColor(red: 0x10, green: 0x18, blue: 0x20, alpha: 0xFF)
    private let oscBackground = PixelColor(red: 0x55, green: 0x22, blue: 0xCC, alpha: 0xFF)

    func testLateOSC11RepaintsPaneWithoutChangingSharedBackdrop() throws {
        let token = UUID().uuidString
        let dataPath = "/tmp/cmux-ui-test-osc11-\(token).json"
        let isolatedHome = try makeIsolatedGhosttyHome(token: token)
        defer {
            try? FileManager.default.removeItem(atPath: dataPath)
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["HOME"] = isolatedHome.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome.path
        app.launchEnvironment["XDG_CONFIG_HOME"] = isolatedHome
            .appendingPathComponent(".config", isDirectory: true).path
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_WINDOW_SIZE"] = "960x720"
        app.launchEnvironment["CMUX_TAG"] = "ui-tests-osc11-\(token.prefix(8))"
        app.launchArguments += [
            "-workspacePresentationMode", "minimal",
            "-sidebarMatchTerminalBackground", "true",
            "-sidebarBlendMode", "withinWindow",
            "-sidebarTintOpacity", "0",
            "-bgGlassEnabled", "false",
        ]
        let activationOptions = XCTExpectedFailure.Options()
        activationOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: activationOptions) {
            app.launch()
        }
        defer { app.terminate() }

        if app.state == .runningBackground {
            XCTExpectFailure("App activation may fail on headless CI runners", options: activationOptions) {
                app.activate()
            }
        }
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 20) || app.windows.firstMatch.waitForExistence(timeout: 6),
            "Expected a queryable cmux window before exercising late OSC 11. state=\(app.state.rawValue)"
        )

        guard let setup = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 25) else {
            XCTFail("Timed out waiting for terminal setup. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        if let setupError = setup["setupError"], !setupError.isEmpty {
            XCTFail("Terminal setup failed: \(setupError)")
            return
        }

        let selectedTabTitle = setup["betaTitle"] ?? "UITest Beta"
        let selectedTab = app.buttons[selectedTabTitle]
        XCTAssertTrue(selectedTab.waitForExistence(timeout: 5), "Expected selected terminal tab")
        selectedTab.click()

        let window = app.windows.firstMatch
        let terminal = app.textViews.firstMatch
        let sidebar = app.otherElements["Sidebar"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Expected main window")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "Expected terminal accessibility surface")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Expected shared-backdrop sidebar")
        XCTAssertTrue(
            waitForRenderableFrames(window: window, terminal: terminal, sidebar: sidebar, timeout: 8),
            "Expected non-empty window, terminal, and sidebar frames. " +
                "window=\(window.frame) terminal=\(terminal.frame) sidebar=\(sidebar.frame)"
        )

        let terminalSampleRect = backgroundSampleRect(in: terminal.frame)
        let sharedBackdropSampleRect = backgroundSampleRect(in: sidebar.frame)
        guard let before = waitForRenderedSample(
            window: window,
            terminalRect: terminalSampleRect,
            sharedBackdropRect: sharedBackdropSampleRect,
            targetTerminalColor: initialBackground,
            tolerance: 24,
            timeout: 12
        ) else {
            addScreenshot(window.screenshot(), name: "osc11-initial-frame-timeout")
            XCTFail("Expected the first rendered terminal frame to use \(initialBackground)")
            return
        }

        // Apply the issue's escape sequence only after the configured initial frame is visible.
        terminal.click()
        app.typeText(#"printf '\033]11;#5522cc\007'"#)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        guard let after = waitForRenderedSample(
            window: window,
            terminalRect: terminalSampleRect,
            sharedBackdropRect: sharedBackdropSampleRect,
            targetTerminalColor: oscBackground,
            tolerance: 24,
            timeout: 12
        ) else {
            addScreenshot(before.screenshot, name: "osc11-before")
            addScreenshot(window.screenshot(), name: "osc11-after-timeout")
            XCTFail("Expected late OSC 11 to repaint visible pane pixels to \(oscBackground)")
            return
        }

        addScreenshot(before.screenshot, name: "osc11-before")
        addScreenshot(after.screenshot, name: "osc11-after")
        XCTAssertLessThanOrEqual(
            rgbDistance(before.sharedBackdrop, after.sharedBackdrop),
            12,
            "OSC 11 must not recolor the shared window backdrop. " +
                "before=\(before.sharedBackdrop) after=\(after.sharedBackdrop)"
        )
        XCTAssertGreaterThan(
            rgbDistance(after.sharedBackdrop, oscBackground),
            48,
            "The surrounding shared backdrop must remain distinct from the pane-local OSC color. " +
                "shared=\(after.sharedBackdrop) osc=\(oscBackground)"
        )
    }

    private struct PixelColor: CustomStringConvertible {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        var description: String {
            String(format: "rgba(%.1f, %.1f, %.1f, %.1f)", red, green, blue, alpha)
        }
    }

    private struct ScreenshotImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(screenshot: XCUIScreenshot) {
            guard let source = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width > 0,
                  image.height > 0 else {
                return nil
            }

            let imageWidth = image.width
            let imageHeight = image.height
            let bytesPerPixel = 4
            let bytesPerRow = imageWidth * bytesPerPixel
            var pixels = [UInt8](repeating: 0, count: imageHeight * bytesPerRow)
            let decoded = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let baseAddress = raw.baseAddress else { return false }
                let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
                guard let context = CGContext(
                    data: baseAddress,
                    width: imageWidth,
                    height: imageHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                ) else {
                    return false
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight)))
                return true
            }
            guard decoded else { return nil }
            width = imageWidth
            height = imageHeight
            self.pixels = pixels
        }

        func colorAt(x: Int, y: Int) -> PixelColor? {
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let index = (y * width + x) * 4
            return PixelColor(
                red: Double(pixels[index]),
                green: Double(pixels[index + 1]),
                blue: Double(pixels[index + 2]),
                alpha: Double(pixels[index + 3])
            )
        }
    }

    private struct RenderedSample {
        let screenshot: XCUIScreenshot
        let terminal: PixelColor
        let sharedBackdrop: PixelColor
    }

    private func makeIsolatedGhosttyHome(token: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-ui-test-osc11-home-\(token)",
            isDirectory: true
        )
        let ghosttyDirectory = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDirectory, withIntermediateDirectories: true)
        try "".write(
            to: home.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )
        try """
        background = #101820
        foreground = #F4F7F7
        background-opacity = 1

        """.write(
            to: ghosttyDirectory.appendingPathComponent("config.ghostty"),
            atomically: true,
            encoding: .utf8
        )
        return home
    }

    private func waitForRenderableFrames(
        window: XCUIElement,
        terminal: XCUIElement,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        waitForCondition(timeout: timeout) {
            window.frame.width > 600 &&
                window.frame.height > 400 &&
                terminal.frame.width > 300 &&
                terminal.frame.height > 200 &&
                sidebar.frame.width > 100 &&
                sidebar.frame.height > 200
        }
    }

    private func waitForRenderedSample(
        window: XCUIElement,
        terminalRect: CGRect,
        sharedBackdropRect: CGRect,
        targetTerminalColor: PixelColor,
        tolerance: Double,
        timeout: TimeInterval
    ) -> RenderedSample? {
        var matchedSample: RenderedSample?
        _ = waitForCondition(timeout: timeout, interval: 0.2) {
            guard let sample = self.renderedSample(
                window: window,
                terminalRect: terminalRect,
                sharedBackdropRect: sharedBackdropRect
            ), self.rgbDistance(sample.terminal, targetTerminalColor) <= tolerance else {
                return false
            }
            matchedSample = sample
            return true
        }
        return matchedSample
    }

    private func renderedSample(
        window: XCUIElement,
        terminalRect: CGRect,
        sharedBackdropRect: CGRect
    ) -> RenderedSample? {
        let screenshot = window.screenshot()
        guard let image = ScreenshotImage(screenshot: screenshot),
              let terminal = medianColor(
                  inScreenRect: terminalRect,
                  windowFrame: window.frame,
                  image: image
              ),
              let sharedBackdrop = medianColor(
                  inScreenRect: sharedBackdropRect,
                  windowFrame: window.frame,
                  image: image
              ) else {
            return nil
        }
        return RenderedSample(
            screenshot: screenshot,
            terminal: terminal,
            sharedBackdrop: sharedBackdrop
        )
    }

    private func backgroundSampleRect(in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + frame.width * 0.18,
            y: frame.minY + frame.height * 0.38,
            width: frame.width * 0.64,
            height: frame.height * 0.24
        )
    }

    private func medianColor(
        inScreenRect screenRect: CGRect,
        windowFrame: CGRect,
        image: ScreenshotImage
    ) -> PixelColor? {
        let scaleX = CGFloat(image.width) / max(1, windowFrame.width)
        let scaleY = CGFloat(image.height) / max(1, windowFrame.height)
        let pixelRect = CGRect(
            x: (screenRect.minX - windowFrame.minX) * scaleX,
            y: (screenRect.minY - windowFrame.minY) * scaleY,
            width: screenRect.width * scaleX,
            height: screenRect.height * scaleY
        ).integral.intersection(
            CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        )
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        let x0 = max(0, Int(pixelRect.minX))
        let y0 = max(0, Int(pixelRect.minY))
        let x1 = min(image.width, Int(pixelRect.maxX))
        let y1 = min(image.height, Int(pixelRect.maxY))
        guard x1 > x0, y1 > y0 else { return nil }

        var reds: [Double] = []
        var greens: [Double] = []
        var blues: [Double] = []
        var alphas: [Double] = []
        for y in stride(from: y0, to: y1, by: 3) {
            for x in stride(from: x0, to: x1, by: 3) {
                guard let color = image.colorAt(x: x, y: y) else { continue }
                reds.append(color.red)
                greens.append(color.green)
                blues.append(color.blue)
                alphas.append(color.alpha)
            }
        }
        guard !reds.isEmpty else { return nil }
        return PixelColor(
            red: median(reds),
            green: median(greens),
            blue: median(blues),
            alpha: median(alphas)
        )
    }

    private func waitForCondition(
        timeout: TimeInterval,
        interval: TimeInterval = 0.1,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(interval)))
        } while Date() < deadline
        return predicate()
    }

    private func rgbDistance(_ lhs: PixelColor, _ rhs: PixelColor) -> Double {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func addScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForJSONKey(
        _ key: String,
        equals expected: String,
        atPath path: String,
        timeout: TimeInterval
    ) -> [String: String]? {
        var matched: [String: String]?
        _ = waitForCondition(timeout: timeout, interval: 0.05) {
            guard let data = self.loadJSON(atPath: path), data[key] == expected else { return false }
            matched = data
            return true
        }
        return matched
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }
}
