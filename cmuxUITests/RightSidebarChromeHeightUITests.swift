import XCTest
import Foundation
import CoreGraphics
import ImageIO

final class RightSidebarChromeHeightUITests: XCTestCase {
    func testSecondaryBarMatchesModeBarAndPaneTabs() {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-right-sidebar-chrome-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += ["-workspacePresentationMode", "minimal"]
        app.launchArguments += ["-rightSidebar.beta.feed.enabled", "YES"]
        app.launchArguments += ["-rightSidebar.beta.dock.enabled", "YES"]
        app.launch()
        defer { app.terminate() }

        if app.state == .runningBackground {
            app.activate()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20) || app.windows.firstMatch.waitForExistence(timeout: 6))
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 25) else {
            XCTFail("Timed out waiting for setup data. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let alphaTitle = loadJSON(atPath: dataPath)?["alphaTitle"] ?? "UITest Alpha"
        let alphaTab = app.buttons[alphaTitle]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5))
        XCTAssertNotNil(waitForJSONNumber("rightSidebarModeBarWidth", greaterThan: 1, atPath: dataPath, timeout: 5))

        let sessionsButton = app.buttons["RightSidebarModeButton.sessions"]
        XCTAssertTrue(sessionsButton.waitForExistence(timeout: 5))
        sessionsButton.click()

        guard let geometry = waitForJSONNumber("rightSidebarSecondaryBarWidth", greaterThan: 1, atPath: dataPath, timeout: 5),
              let modeBarHeight = Double(geometry["rightSidebarModeBarHeight"] ?? ""),
              let secondaryBarHeight = Double(geometry["rightSidebarSecondaryBarHeight"] ?? "") else {
            XCTFail("Timed out waiting for right sidebar secondary bar geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        XCTAssertEqual(secondaryBarHeight, modeBarHeight, accuracy: 0.5, "Expected secondary bar to match the right sidebar mode bar. geometry=\(geometry)")
        XCTAssertEqual(secondaryBarHeight, 28, accuracy: 0.5, "Expected right sidebar chrome to use the standard minimal-mode lane height. geometry=\(geometry)")
        XCTAssertGreaterThanOrEqual(alphaTab.frame.height, CGFloat(secondaryBarHeight), "Expected Bonsplit pane tab hit target to cover the compact chrome lane. geometry=\(geometry) alphaTab=\(alphaTab.frame)")

        let controlHeightKeys = [
            "rightSidebarModeControl_sessionsHeight",
            "rightSidebarSecondaryControl_directoryHeight",
            "rightSidebarSecondaryControl_agentHeight",
            "rightSidebarSecondaryControl_scopeHeight",
        ]
        guard let controlGeometry = waitForJSONNumbers(controlHeightKeys, greaterThan: 1, atPath: dataPath, timeout: 5),
              let modeControlHeight = Double(controlGeometry["rightSidebarModeControl_sessionsHeight"] ?? ""),
              let directoryControlHeight = Double(controlGeometry["rightSidebarSecondaryControl_directoryHeight"] ?? ""),
              let agentControlHeight = Double(controlGeometry["rightSidebarSecondaryControl_agentHeight"] ?? ""),
              let scopeControlHeight = Double(controlGeometry["rightSidebarSecondaryControl_scopeHeight"] ?? "") else {
            XCTFail("Timed out waiting for right sidebar control geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        XCTAssertEqual(directoryControlHeight, modeControlHeight, accuracy: 0.5, "Expected By folder pill to match mode button height. geometry=\(controlGeometry)")
        XCTAssertEqual(agentControlHeight, modeControlHeight, accuracy: 0.5, "Expected By agent pill to match mode button height. geometry=\(controlGeometry)")
        XCTAssertEqual(scopeControlHeight, modeControlHeight, accuracy: 0.5, "Expected This folder only control to match mode button height. geometry=\(controlGeometry)")

        let feedButton = app.buttons["RightSidebarModeButton.feed"]
        XCTAssertTrue(feedButton.waitForExistence(timeout: 5))
        feedButton.click()

        let feedControlHeightKeys = [
            "rightSidebarSecondaryControl_feed_actionableHeight",
            "rightSidebarSecondaryControl_feed_activityHeight",
        ]
        guard let feedGeometry = waitForJSONNumbers(feedControlHeightKeys, greaterThan: 1, atPath: dataPath, timeout: 5),
              let feedSecondaryBarHeight = Double(feedGeometry["rightSidebarSecondaryBarHeight"] ?? ""),
              let actionableControlHeight = Double(feedGeometry["rightSidebarSecondaryControl_feed_actionableHeight"] ?? ""),
              let activityControlHeight = Double(feedGeometry["rightSidebarSecondaryControl_feed_activityHeight"] ?? "") else {
            XCTFail("Timed out waiting for feed secondary bar geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        XCTAssertEqual(feedSecondaryBarHeight, modeBarHeight, accuracy: 0.5, "Expected feed secondary bar to match the mode bar. geometry=\(feedGeometry)")
        XCTAssertEqual(actionableControlHeight, modeControlHeight, accuracy: 0.5, "Expected Feed Actionable pill to match mode button height. geometry=\(feedGeometry)")
        XCTAssertEqual(activityControlHeight, modeControlHeight, accuracy: 0.5, "Expected Feed All Activity pill to match mode button height. geometry=\(feedGeometry)")

        let dockButton = app.buttons["RightSidebarModeButton.dock"]
        XCTAssertTrue(dockButton.waitForExistence(timeout: 5))
        dockButton.click()

        let dockPanel = app.descendants(matching: .any)["DockPanel"].firstMatch
        XCTAssertTrue(dockPanel.waitForExistence(timeout: 5), "Expected Dock panel to render after selecting Dock mode")
        XCTAssertFalse(app.otherElements["DockScopeToggle"].exists, "Expected Dock scope switcher row to be removed")
        XCTAssertFalse(app.buttons["DockScopeTab.workspace"].exists, "Expected Workspace Dock tab to be removed")
        XCTAssertFalse(app.buttons["DockScopeTab.global"].exists, "Expected Global Dock tab to be removed")
        XCTAssertFalse(app.buttons["New Dock Pane"].exists, "Expected Dock toolbar action row to be removed")
        XCTAssertFalse(app.buttons["Open Dock Config"].exists, "Expected Dock toolbar action row to be removed")
        XCTAssertFalse(app.buttons["Reload Dock"].exists, "Expected Dock toolbar action row to be removed")
    }

    func testMatchedTerminalBackgroundKeepsSidebarBackgroundsAndBordersUnified() {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-sidebar-appearance-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += [
            "-workspacePresentationMode", "minimal",
            "-sidebarMatchTerminalBackground", "true",
            "-sidebarBlendMode", "withinWindow",
            "-sidebarTintHex", "#FF0044",
            "-sidebarTintHexLight", "#FFCC00",
            "-sidebarTintHexDark", "#FF0044",
            "-sidebarTintOpacity", "1.0",
        ]
        app.launch()
        defer { app.terminate() }

        if app.state == .runningBackground {
            app.activate()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20) || app.windows.firstMatch.waitForExistence(timeout: 6))
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 25) else {
            XCTFail("Timed out waiting for setup data. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Expected main window to exist")
        let sidebar = app.otherElements["Sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Expected left sidebar to exist")
        let leftResizer = app.otherElements["SidebarResizer"].firstMatch
        XCTAssertTrue(leftResizer.waitForExistence(timeout: 5), "Expected left sidebar resizer to exist")
        let rightResizer = app.otherElements["RightSidebarResizer"].firstMatch
        XCTAssertTrue(rightResizer.waitForExistence(timeout: 5), "Expected right sidebar resizer to exist")
        guard let geometry = waitForJSONNumber("rightSidebarModeBarWidth", greaterThan: 1, atPath: dataPath, timeout: 5),
              let rightSidebarWidthValue = Double(geometry["rightSidebarModeBarWidth"] ?? "") else {
            XCTFail("Timed out waiting for right sidebar mode bar geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let screenshot = window.screenshot()
        guard let image = decodedScreenshot(screenshot) else {
            XCTFail("Failed to decode window screenshot")
            return
        }

        let windowFrame = window.frame
        let leftBoundaryX = leftResizer.frame.midX
        let rightBoundaryX = rightResizer.frame.midX
        XCTAssertEqual(
            rightBoundaryX,
            windowFrame.maxX - CGFloat(rightSidebarWidthValue),
            accuracy: 12,
            "Expected right sidebar resizer to track right sidebar width. rightResizer=\(rightResizer.frame) geometry=\(geometry) window=\(windowFrame)"
        )
        XCTAssertGreaterThan(rightBoundaryX, leftBoundaryX + 160, "Expected terminal area between sidebars. window=\(windowFrame) sidebar=\(sidebar.frame) geometry=\(geometry)")

        let sampleY = max(windowFrame.minY + 140, min(windowFrame.maxY - 90, windowFrame.midY))
        let leftBackgroundRect = CGRect(
            x: sidebar.frame.minX + 14,
            y: sampleY - 48,
            width: max(20, sidebar.frame.width - 40),
            height: 96
        )
        let terminalBackgroundRect = CGRect(
            x: leftBoundaryX + 48,
            y: sampleY - 48,
            width: max(40, rightBoundaryX - leftBoundaryX - 96),
            height: 96
        )
        let rightBackgroundRect = CGRect(
            x: rightBoundaryX + 24,
            y: sampleY - 48,
            width: max(20, windowFrame.maxX - rightBoundaryX - 48),
            height: 96
        )

        guard let leftBackground = medianColor(inScreenRect: leftBackgroundRect, windowFrame: windowFrame, image: image),
              let terminalBackground = medianColor(inScreenRect: terminalBackgroundRect, windowFrame: windowFrame, image: image),
              let rightBackground = medianColor(inScreenRect: rightBackgroundRect, windowFrame: windowFrame, image: image) else {
            addKeptScreenshot(screenshot, name: "matched-sidebar-backgrounds")
            XCTFail("Failed to sample sidebar and terminal backgrounds. image=\(image.width)x\(image.height) window=\(windowFrame)")
            return
        }

        let leftDelta = rgbDistance(leftBackground, terminalBackground)
        let rightDelta = rgbDistance(rightBackground, terminalBackground)
        let backgroundTolerance = 14.0
        XCTAssertLessThanOrEqual(leftDelta, backgroundTolerance, "Expected left sidebar background to match terminal. left=\(leftBackground) terminal=\(terminalBackground) delta=\(leftDelta)")
        XCTAssertLessThanOrEqual(rightDelta, backgroundTolerance, "Expected right sidebar background to match terminal. right=\(rightBackground) terminal=\(terminalBackground) delta=\(rightDelta)")

        guard let leftSeparatorContrast = strongestVerticalSeparatorContrast(
            expectedScreenX: leftBoundaryX,
            sampleScreenY: sampleY,
            windowFrame: windowFrame,
            image: image,
            leadingBackground: leftBackground,
            trailingBackground: terminalBackground
        ),
        let rightSeparatorContrast = strongestVerticalSeparatorContrast(
            expectedScreenX: rightBoundaryX,
            sampleScreenY: sampleY,
            windowFrame: windowFrame,
            image: image,
            leadingBackground: terminalBackground,
            trailingBackground: rightBackground
        ) else {
            addKeptScreenshot(screenshot, name: "matched-sidebar-separators")
            XCTFail("Failed to sample sidebar separators. image=\(image.width)x\(image.height) window=\(windowFrame)")
            return
        }

        XCTAssertGreaterThanOrEqual(leftSeparatorContrast, 6.0, "Expected visible divider between left sidebar and workspace. contrast=\(leftSeparatorContrast) left=\(leftBackground) terminal=\(terminalBackground)")
        XCTAssertGreaterThanOrEqual(rightSeparatorContrast, 6.0, "Expected visible divider between workspace and right sidebar. contrast=\(rightSeparatorContrast) terminal=\(terminalBackground) right=\(rightBackground)")
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

        init?(cgImage: CGImage) {
            let width = cgImage.width
            let height = cgImage.height
            guard width > 0, height > 0 else { return nil }

            let bytesPerPixel = 4
            let bytesPerRow = width * bytesPerPixel
            var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
            let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                guard let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                ) else {
                    return false
                }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
                return true
            }
            guard ok else { return nil }

            self.width = width
            self.height = height
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

    private func decodedScreenshot(_ screenshot: XCUIScreenshot) -> ScreenshotImage? {
        guard let source = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return ScreenshotImage(cgImage: cgImage)
    }

    private func addKeptScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func medianColor(
        inScreenRect screenRect: CGRect,
        windowFrame: CGRect,
        image: ScreenshotImage
    ) -> PixelColor? {
        medianColor(
            inPixelRect: pixelRect(forScreenRect: screenRect, windowFrame: windowFrame, image: image),
            image: image
        )
    }

    private func medianColor(inPixelRect pixelRect: CGRect, image: ScreenshotImage) -> PixelColor? {
        let clamped = pixelRect.integral.intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }

        let x0 = Int(clamped.minX)
        let y0 = Int(clamped.minY)
        let x1 = min(image.width, Int(clamped.maxX))
        let y1 = min(image.height, Int(clamped.maxY))
        guard x1 > x0, y1 > y0 else { return nil }

        var reds: [Double] = []
        var greens: [Double] = []
        var blues: [Double] = []
        var alphas: [Double] = []
        let sampleCapacity = max(1, (x1 - x0) * (y1 - y0) / 4)
        reds.reserveCapacity(sampleCapacity)
        greens.reserveCapacity(sampleCapacity)
        blues.reserveCapacity(sampleCapacity)
        alphas.reserveCapacity(sampleCapacity)

        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
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

    private func strongestVerticalSeparatorContrast(
        expectedScreenX: CGFloat,
        sampleScreenY: CGFloat,
        windowFrame: CGRect,
        image: ScreenshotImage,
        leadingBackground: PixelColor,
        trailingBackground: PixelColor
    ) -> Double? {
        let scaleX = CGFloat(image.width) / max(1, windowFrame.width)
        let scaleY = CGFloat(image.height) / max(1, windowFrame.height)
        let expectedPixelX = Int(((expectedScreenX - windowFrame.minX) * scaleX).rounded())
        let samplePixelY = Int(((sampleScreenY - windowFrame.minY) * scaleY).rounded())
        let scanRadius = max(4, Int((10 * scaleX).rounded(.up)))
        let halfHeight = max(12, Int((70 * scaleY / 2).rounded(.up)))

        var best: Double?
        for x in (expectedPixelX - scanRadius)...(expectedPixelX + scanRadius) {
            let rect = CGRect(
                x: CGFloat(x),
                y: CGFloat(samplePixelY - halfHeight),
                width: 1,
                height: CGFloat(halfHeight * 2 + 1)
            )
            guard let color = medianColor(inPixelRect: rect, image: image) else { continue }
            let contrast = min(rgbDistance(color, leadingBackground), rgbDistance(color, trailingBackground))
            if best.map({ contrast > $0 }) ?? true {
                best = contrast
            }
        }
        return best
    }

    private func pixelRect(forScreenRect screenRect: CGRect, windowFrame: CGRect, image: ScreenshotImage) -> CGRect {
        let scaleX = CGFloat(image.width) / max(1, windowFrame.width)
        let scaleY = CGFloat(image.height) / max(1, windowFrame.height)
        return CGRect(
            x: (screenRect.minX - windowFrame.minX) * scaleX,
            y: (screenRect.minY - windowFrame.minY) * scaleY,
            width: screenRect.width * scaleX,
            height: screenRect.height * scaleY
        )
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

    private func waitForJSONNumbers(_ keys: [String], greaterThan threshold: Double, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), containsNumbers(data, keys: keys, greaterThan: threshold) {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path).flatMap {
            containsNumbers($0, keys: keys, greaterThan: threshold) ? $0 : nil
        }
    }

    private func containsNumbers(_ data: [String: String], keys: [String], greaterThan threshold: Double) -> Bool {
        keys.allSatisfy { key in
            guard let rawValue = data[key], let value = Double(rawValue) else { return false }
            return value > threshold
        }
    }

    private func waitForJSONKey(_ key: String, equals expected: String, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), data[key] == expected { return data }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path).flatMap { $0[key] == expected ? $0 : nil }
    }

    private func waitForJSONNumber(_ key: String, greaterThan threshold: Double, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), let rawValue = data[key], let value = Double(rawValue), value > threshold { return data }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path).flatMap {
            guard let rawValue = $0[key], let value = Double(rawValue), value > threshold else { return nil }
            return $0
        }
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }
}

final class TerminalViewportUITests: XCTestCase {
    func testTerminalSurfaceUsesAvailableViewportAndTracksWindowResize() {
        let dataPath = "/tmp/cmux-ui-test-terminal-viewport-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_WINDOW_SIZE"] = "900x620"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_RESIZE_WINDOW_SIZE"] = "1180x780"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_SIDEBAR"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += ["-workspacePresentationMode", "minimal"]
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        defer { app.terminate() }
        defer {
            try? FileManager.default.removeItem(atPath: dataPath)
        }

        if app.state == .runningBackground {
            app.activate()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20) || app.windows.firstMatch.waitForExistence(timeout: 6))

        guard let small = waitForViewportGeometry(atPath: dataPath, prefix: "terminalViewportInitial", timeout: 20, matching: { geometry in
            geometry.windowWidth >= 560 &&
                geometry.panelWidth > 300 &&
                geometry.panelHeight > 220 &&
                geometry.fillsAvailableViewport
        }) else {
            XCTFail("Timed out waiting for small terminal viewport geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        assertTerminalViewportFillsAvailableSpace(small)

        guard let large = waitForViewportGeometry(atPath: dataPath, prefix: "terminalViewportResized", timeout: 20, matching: { geometry in
            geometry.requestedWindowSize == "1180x780" &&
                geometry.windowWidth > small.windowWidth + 180 &&
                geometry.windowHeight > small.windowHeight + 120 &&
                geometry.panelWidth > small.panelWidth + 180 &&
                geometry.panelHeight > small.panelHeight + 120 &&
                geometry.fillsAvailableViewport
        }) else {
            XCTFail("Timed out waiting for resized terminal viewport geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        assertTerminalViewportFillsAvailableSpace(large)
    }

    private struct ViewportGeometry {
        let data: [String: String]
        let requestedWindowSize: String
        let windowWidth: CGFloat
        let windowHeight: CGFloat
        let windowContentWidth: CGFloat
        let windowContentHeight: CGFloat
        let panelWidth: CGFloat
        let panelHeight: CGFloat
        let hostedFrameMinX: CGFloat
        let hostedFrameMinY: CGFloat
        let hostedFrameWidth: CGFloat
        let hostedFrameHeight: CGFloat
        let hostedBoundsWidth: CGFloat
        let hostedBoundsHeight: CGFloat

        var fillsAvailableViewport: Bool {
            windowContentWidth > 300 &&
                windowContentHeight > 240 &&
                abs(hostedFrameMinX) <= 3 &&
                abs(hostedFrameMinY) <= 3 &&
                abs(hostedFrameWidth - panelWidth) <= 3 &&
                abs(hostedFrameHeight - panelHeight) <= 3 &&
                abs(hostedBoundsWidth - hostedFrameWidth) <= 3 &&
                abs(hostedBoundsHeight - hostedFrameHeight) <= 3 &&
                panelWidth >= windowContentWidth - 24 &&
                panelHeight >= windowContentHeight - 130
        }

        init?(data: [String: String], prefix: String) {
            func key(_ suffix: String) -> String {
                "\(prefix)\(suffix)"
            }

            guard data[key("Ready")] == "1",
                  data[key("SidebarVisible")] == "0",
                  data[key("RightSidebarVisible")] == "0" else {
                return nil
            }
            self.data = data
            requestedWindowSize = data[key("RequestedWindowSize")] ?? ""
            guard let windowWidth = Self.number(key("WindowWidth"), in: data),
                  let windowHeight = Self.number(key("WindowHeight"), in: data),
                  let windowContentWidth = Self.number(key("WindowContentWidth"), in: data),
                  let windowContentHeight = Self.number(key("WindowContentHeight"), in: data),
                  let panelWidth = Self.number(key("PanelWidth"), in: data),
                  let panelHeight = Self.number(key("PanelHeight"), in: data),
                  let hostedFrameMinX = Self.number(key("HostedFrameMinX"), in: data),
                  let hostedFrameMinY = Self.number(key("HostedFrameMinY"), in: data),
                  let hostedFrameWidth = Self.number(key("HostedFrameWidth"), in: data),
                  let hostedFrameHeight = Self.number(key("HostedFrameHeight"), in: data),
                  let hostedBoundsWidth = Self.number(key("HostedBoundsWidth"), in: data),
                  let hostedBoundsHeight = Self.number(key("HostedBoundsHeight"), in: data) else {
                return nil
            }
            self.windowWidth = windowWidth
            self.windowHeight = windowHeight
            self.windowContentWidth = windowContentWidth
            self.windowContentHeight = windowContentHeight
            self.panelWidth = panelWidth
            self.panelHeight = panelHeight
            self.hostedFrameMinX = hostedFrameMinX
            self.hostedFrameMinY = hostedFrameMinY
            self.hostedFrameWidth = hostedFrameWidth
            self.hostedFrameHeight = hostedFrameHeight
            self.hostedBoundsWidth = hostedBoundsWidth
            self.hostedBoundsHeight = hostedBoundsHeight
        }

        private static func number(_ key: String, in data: [String: String]) -> CGFloat? {
            guard let rawValue = data[key], let value = Double(rawValue) else { return nil }
            return CGFloat(value)
        }
    }

    private func assertTerminalViewportFillsAvailableSpace(
        _ geometry: ViewportGeometry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(geometry.hostedFrameMinX, 0, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedFrameMinY, 0, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedFrameWidth, geometry.panelWidth, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedFrameHeight, geometry.panelHeight, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedBoundsWidth, geometry.hostedFrameWidth, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedBoundsHeight, geometry.hostedFrameHeight, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(geometry.panelWidth, geometry.windowContentWidth - 24, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(geometry.panelHeight, geometry.windowContentHeight - 130, "geometry=\(geometry.data)", file: file, line: line)
    }

    private func waitForViewportGeometry(
        atPath path: String,
        prefix: String,
        timeout: TimeInterval,
        matching predicate: (ViewportGeometry) -> Bool
    ) -> ViewportGeometry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path),
               let geometry = ViewportGeometry(data: data, prefix: prefix),
               predicate(geometry) {
                return geometry
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path),
           let geometry = ViewportGeometry(data: data, prefix: prefix),
           predicate(geometry) {
            return geometry
        }
        return nil
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }
}
