import XCTest
import UIKit

final class TerminalThemeParityUITests: XCTestCase {
    private enum SystemAppearance: String, CaseIterable {
        case light
        case dark
    }

    private struct ThemeStage {
        let name: String
        let background: (red: Int, green: Int, blue: Int)
    }

    private struct ToolbarControl {
        let identifier: String
        let frame: CGRect
        let minimumContrast: Double
        let isEnabled: Bool
    }

    private static let themeStages = [
        ThemeStage(name: "dark", background: (16, 21, 34)),
        ThemeStage(name: "light", background: (244, 240, 223)),
        ThemeStage(name: "custom", background: (6, 63, 70)),
    ]

    private static let requiredTopControls: [(
        identifier: String,
        minimumContrast: Double,
        requiresHitTarget: Bool
    )] = [
        ("MobileWorkspaceBackButton", 3, true),
        ("MobileWorkspaceTitleMenu", 4.5, false),
        ("MobileTerminalDropdown", 3, true),
    ]

    private static let requiredAccessoryControls: [(
        identifier: String,
        minimumContrast: Double,
        requiresHitTarget: Bool
    )] = [
        ("terminal.inputAccessory.hideKeyboard", 3, true),
        ("terminal.inputAccessory.composer", 3, true),
        ("terminal.inputAccessory.control", 4.5, true),
        ("terminal.inputAccessory.alt", 4.5, true),
        ("terminal.inputAccessory.command", 4.5, true),
        ("terminal.inputAccessory.shift", 4.5, true),
    ]

    private static let iconAccessoryIdentifiers: Set<String> = [
        "terminal.inputAccessory.hideKeyboard",
        "terminal.inputAccessory.composer",
        "terminal.inputAccessory.files",
        "terminal.inputAccessory.hideChrome",
        "terminal.inputAccessory.customize",
        "terminal.inputAccessory.paste",
        "terminal.inputAccessory.zoomIn",
        "terminal.inputAccessory.zoomOut",
    ]

    private static let maximumTransitionBurstSamples = 12

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChromeRepaintsForLiveThemes() throws {
        for appearance in SystemAppearance.allCases {
            try verifyThemeSequence(systemAppearance: appearance)
        }
    }

    @MainActor
    private func verifyThemeSequence(systemAppearance: SystemAppearance) throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_WORKSPACE_DETAIL_DELAYED_TERMINAL"] = "1"
        app.launchEnvironment["CMUX_UITEST_THEME_PARITY_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_THEME_PARITY_SYSTEM_APPEARANCE"] = systemAppearance.rawValue
        app.launchEnvironment["CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE"] = "1"
        app.launch()
        defer { app.terminate() }

        var baselineFrames: [String: CGRect] = [:]
        var previousStageCapture: (pixels: ScreenshotPixels, controls: [String: ToolbarControl])?
        var customThemeCapture: (pixels: ScreenshotPixels, controls: [String: ToolbarControl])?
        for (index, stage) in Self.themeStages.enumerated() {
            if index > 0, let previousStageCapture {
                let previousStage = Self.themeStages[index - 1]
                let advanceButton = app.buttons["TerminalThemeAdvance"]
                XCTAssertTrue(advanceButton.waitForExistence(timeout: 3), "Missing controlled theme advance entrypoint.")
                advanceButton.tap()
                try assertThemeTransitionBurstHasReadableControls(
                    in: app,
                    from: previousStage,
                    toward: stage,
                    previousStageCapture: previousStageCapture,
                    systemAppearance: systemAppearance
                )
            }
            try waitForStage(stage.name, in: app)
            let result = try capture(
                app,
                name: "\(systemAppearance.rawValue)-system-\(stage.name)-theme",
                expectedBackground: stage.background,
                baselineFrames: baselineFrames
            )
            if baselineFrames.isEmpty {
                baselineFrames = result.controls.mapValues(\.frame)
            }
            previousStageCapture = result
            if stage.name == "custom" {
                customThemeCapture = result
            }
        }

        let settledCustomThemeCapture = try XCTUnwrap(customThemeCapture)
        try assertModifierStatesRemainDistinct(
            in: app,
            resting: settledCustomThemeCapture,
            systemAppearance: systemAppearance
        )
    }

    @MainActor
    private func waitForStage(_ stage: String, in app: XCUIApplication) throws {
        XCTAssertTrue(
            app.otherElements["TerminalThemeStage-\(stage)"].waitForExistence(timeout: 10),
            "Theme fixture did not reach \(stage)."
        )
    }

    @MainActor
    private func assertThemeTransitionBurstHasReadableControls(
        in app: XCUIApplication,
        from previousStage: ThemeStage,
        toward nextStage: ThemeStage,
        previousStageCapture: (pixels: ScreenshotPixels, controls: [String: ToolbarControl]),
        systemAppearance: SystemAppearance
    ) throws {
        let previousBackground = previousStageCapture.pixels.color(xUnit: 0.5, yUnit: 0.5)
        let clock = ContinuousClock()
        let transitionDeadline = clock.now.advanced(by: .seconds(15))
        var samples: [XCUIScreenshot] = []
        var sampledBackground = previousBackground

        while clock.now < transitionDeadline {
            let screenshot = app.screenshot()
            let pixels = try ScreenshotPixels(image: screenshot.image)
            let background = pixels.color(xUnit: 0.5, yUnit: 0.5)
            sampledBackground = background
            if backgroundHasChanged(
                background,
                from: previousBackground,
                toward: nextStage.background
            ) {
                samples.append(screenshot)
                break
            }
        }

        _ = try XCTUnwrap(
            samples.first,
            "Terminal background did not transition from \(previousStage.name) toward \(nextStage.name); "
                + "last center pixel was \(sampledBackground)."
        )

        let burstDeadline = clock.now.advanced(by: .seconds(1))
        while samples.count < Self.maximumTransitionBurstSamples,
              clock.now < burstDeadline {
            samples.append(app.screenshot())
        }
        XCTAssertFalse(
            samples.isEmpty,
            "\(previousStage.name)->\(nextStage.name) transition burst captured no post-change samples."
        )

        let previousExpectsDarkContent = statusBarUsesDarkGlyphs(on: previousStage.background)
        var failedSamples: [(index: Int, controls: [String])] = []
        for (index, screenshot) in samples.enumerated() {
            let pixels = try ScreenshotPixels(image: screenshot.image)
            var failures: [String] = []
            for control in previousStageCapture.controls.values
                .filter(\.isEnabled)
                .sorted(by: { $0.identifier < $1.identifier }) {
                let result = pixels.referencedContentContrast(
                    in: control.frame,
                    screenFrame: app.frame,
                    reference: previousStageCapture.pixels,
                    referenceExpectsDarkContent: previousExpectsDarkContent,
                    minimumContrast: control.minimumContrast
                )
                guard result.conservativeContrast < control.minimumContrast else { continue }
                failures.append(
                    "\(control.identifier)=\(String(format: "%.2f", result.conservativeContrast)):1 "
                        + "(required \(String(format: "%.1f", control.minimumContrast)):1, "
                        + "mask pixels \(result.sampleCount))"
                )
            }
            if !failures.isEmpty {
                failedSamples.append((index, failures))
            }
        }

        let attachmentIndices = Set([0] + failedSamples.map(\.index))
        for index in attachmentIndices.sorted() {
            let isFailure = failedSamples.contains { $0.index == index }
            let suffix = index == 0
                ? (isFailure ? "first-failed" : "first")
                : "failed"
            let attachment = XCTAttachment(screenshot: samples[index])
            attachment.name = "\(systemAppearance.rawValue)-system-\(previousStage.name)-to-\(nextStage.name)"
                + "-\(suffix)-sample-\(index + 1)-of-\(samples.count)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertTrue(
            failedSamples.isEmpty,
            "\(previousStage.name)->\(nextStage.name) transition burst has unreadable active controls "
                + "in \(failedSamples.count) of \(samples.count) samples: "
                + failedSamples.map { "sample \($0.index + 1): \($0.controls.joined(separator: ", "))" }
                    .joined(separator: "; ")
        )
    }

    private func backgroundHasChanged(
        _ actual: (red: Int, green: Int, blue: Int),
        from previous: (red: Int, green: Int, blue: Int),
        toward target: (red: Int, green: Int, blue: Int)
    ) -> Bool {
        let distanceFromPrevious = colorDistance(actual, previous)
        return distanceFromPrevious >= 24
            && colorDistance(actual, target) < colorDistance(previous, target)
    }

    private func colorDistance(
        _ first: (red: Int, green: Int, blue: Int),
        _ second: (red: Int, green: Int, blue: Int)
    ) -> Int {
        abs(first.red - second.red)
            + abs(first.green - second.green)
            + abs(first.blue - second.blue)
    }

    @MainActor
    private func capture(
        _ app: XCUIApplication,
        name: String,
        expectedBackground: (red: Int, green: Int, blue: Int),
        baselineFrames: [String: CGRect]
    ) throws -> (pixels: ScreenshotPixels, controls: [String: ToolbarControl]) {
        let controls = try visibleToolbarControls(in: app)
        let screenshot = app.screenshot()
        let pixels = try ScreenshotPixels(image: screenshot.image)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["CMUX_THEME_EVIDENCE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            )
        }
        for point in [(0.01, 0.05), (0.5, 0.5), (0.01, 0.9)] {
            let actual = pixels.color(xUnit: point.0, yUnit: point.1)
            XCTAssertEqual(actual.red, expectedBackground.red, accuracy: 8, "red at \(point)")
            XCTAssertEqual(actual.green, expectedBackground.green, accuracy: 8, "green at \(point)")
            XCTAssertEqual(actual.blue, expectedBackground.blue, accuracy: 8, "blue at \(point)")
        }
        assertStatusBarContrast(
            pixels,
            expectsDarkGlyphs: statusBarUsesDarkGlyphs(on: expectedBackground)
        )
        let expectsDarkContent = statusBarUsesDarkGlyphs(on: expectedBackground)
        for control in controls.values {
            let result = pixels.contentContrast(
                in: control.frame,
                screenFrame: app.frame,
                expectsDarkContent: expectsDarkContent,
                minimumContrast: control.minimumContrast
            )
            if control.isEnabled {
                XCTAssertGreaterThanOrEqual(
                    result.qualifyingPixelFraction,
                    0.004,
                    "\(control.identifier) content contrast \(result.maximumContrast):1 on local background "
                        + "\(result.backgroundLuminance) should reach \(control.minimumContrast):1; "
                        + "qualifying fraction \(result.qualifyingPixelFraction)."
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    result.maximumContrast,
                    3,
                    "Disabled \(control.identifier) should remain recognizable."
                )
            }
            if let baselineFrame = baselineFrames[control.identifier] {
                assertFrame(control.frame, equals: baselineFrame, identifier: control.identifier)
            }
        }
        if !baselineFrames.isEmpty {
            XCTAssertEqual(Set(controls.keys), Set(baselineFrames.keys), "Theme change added or removed toolbar controls.")
        }
        return (pixels, controls)
    }

    @MainActor
    private func visibleToolbarControls(in app: XCUIApplication) throws -> [String: ToolbarControl] {
        var controls: [String: ToolbarControl] = [:]
        for expected in Self.requiredTopControls + Self.requiredAccessoryControls {
            let element = try toolbarControlElement(
                identifier: expected.identifier,
                requiresHitTarget: expected.requiresHitTarget,
                in: app
            )
            controls[expected.identifier] = ToolbarControl(
                identifier: expected.identifier,
                frame: element.frame,
                minimumContrast: expected.minimumContrast,
                isEnabled: element.isEnabled
            )
        }

        let accessoryQuery = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.inputAccessory.")
        )
        for element in accessoryQuery.allElementsBoundByIndex where element.exists && element.isHittable {
            let identifier = element.identifier
            guard !identifier.isEmpty,
                  controls[identifier] == nil,
                  app.frame.contains(element.frame) else { continue }
            controls[identifier] = ToolbarControl(
                identifier: identifier,
                frame: element.frame,
                minimumContrast: Self.iconAccessoryIdentifiers.contains(identifier) ? 3 : 4.5,
                isEnabled: element.isEnabled
            )
        }
        return controls
    }

    @MainActor
    private func toolbarControlElement(
        identifier: String,
        requiresHitTarget: Bool,
        in app: XCUIApplication
    ) throws -> XCUIElement {
        let query = requiresHitTarget
            ? app.buttons.matching(identifier: identifier)
            : app.descendants(matching: .any).matching(identifier: identifier)
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 3), "Missing \(identifier).")
        let candidates = query.allElementsBoundByIndex.filter(\.exists)
        if requiresHitTarget {
            return try XCTUnwrap(
                candidates.first(where: { $0.isHittable }),
                "\(identifier) lost its hit target."
            )
        }
        return try XCTUnwrap(candidates.first, "Missing \(identifier).")
    }

    @MainActor
    private func assertModifierStatesRemainDistinct(
        in app: XCUIApplication,
        resting: (pixels: ScreenshotPixels, controls: [String: ToolbarControl]),
        systemAppearance: SystemAppearance
    ) throws {
        let identifier = "terminal.inputAccessory.control"
        let control = try toolbarControlElement(identifier: identifier, requiresHitTarget: true, in: app)
        let restingControl = try XCTUnwrap(resting.controls[identifier])
        func renderedDifference(_ pixels: ScreenshotPixels, from reference: ScreenshotPixels) -> Double {
            pixels.differenceFraction(
                from: reference,
                in: restingControl.frame,
                screenFrame: app.frame
            )
        }

        // The first tap arms the one-shot modifier.
        control.tap()
        let (armedScreenshot, armedPixels) = try waitForScreenshot(
            in: app,
            timeout: .seconds(3),
            failureMessage: "Armed modifier should have a distinct rendered state."
        ) { pixels in
            renderedDifference(pixels, from: resting.pixels) > 0.08
        }
        XCTAssertTrue(control.isHittable, "Armed modifier lost its hit target.")
        assertFrame(control.frame, equals: restingControl.frame, identifier: identifier)
        XCTAssertGreaterThan(
            renderedDifference(armedPixels, from: resting.pixels),
            0.08,
            "Armed modifier should have a distinct rendered state."
        )

        // Escape follows the real non-modifier action path, which consumes the
        // one-shot Control modifier and clears its pending double-tap window.
        let escape = try toolbarControlElement(
            identifier: "terminal.inputAccessory.escape",
            requiresHitTarget: true,
            in: app
        )
        XCTAssertTrue(escape.isHittable, "Escape action lost its hit target.")
        escape.tap()
        _ = try waitForScreenshot(
            in: app,
            timeout: .seconds(3),
            failureMessage: "Modifier did not return to its resting presentation after disarming."
        ) { pixels in
            renderedDifference(pixels, from: resting.pixels) < 0.01
        }

        // From that fully consumed state, the double tap arms the sticky lock.
        control.doubleTap()
        let (stickyScreenshot, stickyPixels) = try waitForScreenshot(
            in: app,
            timeout: .seconds(3),
            failureMessage: "Sticky modifier should differ from resting and one-shot armed presentations."
        ) { pixels in
            renderedDifference(pixels, from: resting.pixels) > 0.08
                && renderedDifference(pixels, from: armedPixels) > 0.01
        }
        XCTAssertTrue(control.isHittable, "Sticky modifier lost its hit target.")
        assertFrame(control.frame, equals: restingControl.frame, identifier: identifier)
        XCTAssertGreaterThan(
            renderedDifference(stickyPixels, from: resting.pixels),
            0.08,
            "Sticky modifier should differ from the resting presentation."
        )
        XCTAssertGreaterThan(
            renderedDifference(stickyPixels, from: armedPixels),
            0.01,
            "Sticky modifier should remain distinguishable from one-shot armed."
        )

        for (state, screenshot) in [("armed", armedScreenshot), ("sticky", stickyScreenshot)] {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "\(systemAppearance.rawValue)-system-custom-theme-\(state)-modifier"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func waitForScreenshot(
        in app: XCUIApplication,
        timeout: Duration,
        failureMessage: String,
        matching predicate: (ScreenshotPixels) -> Bool
    ) throws -> (screenshot: XCUIScreenshot, pixels: ScreenshotPixels) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var match: (screenshot: XCUIScreenshot, pixels: ScreenshotPixels)?
        repeat {
            let screenshot = app.screenshot()
            let pixels = try ScreenshotPixels(image: screenshot.image)
            if predicate(pixels) {
                match = (screenshot, pixels)
                break
            }
        } while clock.now < deadline
        return try XCTUnwrap(match, failureMessage)
    }

    private func assertFrame(_ actual: CGRect, equals expected: CGRect, identifier: String) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, "\(identifier) shifted horizontally.")
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, "\(identifier) shifted vertically.")
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, "\(identifier) changed width.")
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, "\(identifier) changed height.")
    }

    private func assertStatusBarContrast(
        _ pixels: ScreenshotPixels,
        expectsDarkGlyphs: Bool
    ) {
        let luminanceRange = pixels.luminanceRange(
            xUnits: 0.1 ... 0.27,
            yUnits: 0.025 ... 0.055
        )
        if expectsDarkGlyphs {
            XCTAssertLessThan(luminanceRange.minimum, 0.25, "Status-bar glyphs should be dark.")
        } else {
            XCTAssertGreaterThan(luminanceRange.maximum, 0.75, "Status-bar glyphs should be light.")
        }
    }

    private func statusBarUsesDarkGlyphs(
        on background: (red: Int, green: Int, blue: Int)
    ) -> Bool {
        let channels = [background.red, background.green, background.blue].map { component -> Double in
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2] > 0.5
    }
}

private struct ScreenshotPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(image: UIImage) throws {
        guard let cgImage = image.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        var storage = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let rendered = storage.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        guard let rendered else { throw CocoaError(.fileReadCorruptFile) }
        rendered.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        width = pixelWidth
        height = pixelHeight
        bytes = storage
    }

    func color(xUnit: Double, yUnit: Double) -> (red: Int, green: Int, blue: Int) {
        let x = min(width - 1, max(0, Int(xUnit * Double(width))))
        let y = min(height - 1, max(0, Int(yUnit * Double(height))))
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    func luminanceRange(
        xUnits: ClosedRange<Double>,
        yUnits: ClosedRange<Double>
    ) -> (minimum: Double, maximum: Double) {
        let xRange = Int(xUnits.lowerBound * Double(width)) ... Int(xUnits.upperBound * Double(width))
        let yRange = Int(yUnits.lowerBound * Double(height)) ... Int(yUnits.upperBound * Double(height))
        var minimum = 1.0
        var maximum = 0.0
        for y in yRange {
            for x in xRange {
                let offset = (min(y, height - 1) * width + min(x, width - 1)) * 4
                let luminance = 0.2126 * Double(bytes[offset]) / 255
                    + 0.7152 * Double(bytes[offset + 1]) / 255
                    + 0.0722 * Double(bytes[offset + 2]) / 255
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        return (minimum, maximum)
    }

    func contentContrast(
        in frame: CGRect,
        screenFrame: CGRect,
        expectsDarkContent: Bool,
        minimumContrast: Double
    ) -> (backgroundLuminance: Double, maximumContrast: Double, qualifyingPixelFraction: Double) {
        let bounds = pixelBounds(for: frame, screenFrame: screenFrame)
        let luminances = pixelLuminances(in: bounds)
        let background = dominantLuminance(in: luminances)
        let contentBounds = bounds.insetBy(
            dx: max(1, CGFloat(bounds.width) * 0.18),
            dy: max(1, CGFloat(bounds.height) * 0.18)
        ).integral
        let contentLuminances = pixelLuminances(in: contentBounds)
        var qualifyingCount = 0
        var maximumContrast = 1.0
        for luminance in contentLuminances {
            let contrast = contrastRatio(luminance, background)
            let expectedDirection = expectsDarkContent ? luminance < background : luminance > background
            if expectedDirection {
                maximumContrast = max(maximumContrast, contrast)
                if contrast >= minimumContrast {
                    qualifyingCount += 1
                }
            }
        }
        return (
            background,
            maximumContrast,
            contentLuminances.isEmpty ? 0 : Double(qualifyingCount) / Double(contentLuminances.count)
        )
    }

    func referencedContentContrast(
        in frame: CGRect,
        screenFrame: CGRect,
        reference: ScreenshotPixels,
        referenceExpectsDarkContent: Bool,
        minimumContrast: Double
    ) -> (conservativeContrast: Double, sampleCount: Int) {
        guard width == reference.width, height == reference.height else { return (1, 0) }
        let bounds = pixelBounds(for: frame, screenFrame: screenFrame)
        let background = dominantLuminance(in: pixelLuminances(in: bounds))
        let referenceBackground = reference.dominantLuminance(
            in: reference.pixelLuminances(in: bounds)
        )
        let contentBounds = bounds.insetBy(
            dx: max(1, CGFloat(bounds.width) * 0.18),
            dy: max(1, CGFloat(bounds.height) * 0.18)
        ).integral
        let luminances = pixelLuminances(in: contentBounds)
        let referenceLuminances = reference.pixelLuminances(in: contentBounds)
        var contrasts: [Double] = []
        for (luminance, referenceLuminance) in zip(luminances, referenceLuminances) {
            let referenceDirectionMatches = referenceExpectsDarkContent
                ? referenceLuminance < referenceBackground
                : referenceLuminance > referenceBackground
            guard referenceDirectionMatches,
                  contrastRatio(referenceLuminance, referenceBackground) >= minimumContrast else { continue }
            contrasts.append(contrastRatio(luminance, background))
        }
        contrasts.sort()
        guard !contrasts.isEmpty else { return (1, 0) }
        let percentileIndex = min(contrasts.count - 1, Int(Double(contrasts.count) * 0.1))
        return (contrasts[percentileIndex], contrasts.count)
    }

    func differenceFraction(
        from other: ScreenshotPixels,
        in frame: CGRect,
        screenFrame: CGRect
    ) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        let bounds = pixelBounds(for: frame, screenFrame: screenFrame)
        var changed = 0
        var total = 0
        for y in Int(bounds.minY) ..< Int(bounds.maxY) {
            for x in Int(bounds.minX) ..< Int(bounds.maxX) {
                let offset = (y * width + x) * 4
                let delta = abs(Int(bytes[offset]) - Int(other.bytes[offset]))
                    + abs(Int(bytes[offset + 1]) - Int(other.bytes[offset + 1]))
                    + abs(Int(bytes[offset + 2]) - Int(other.bytes[offset + 2]))
                if delta >= 24 { changed += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(changed) / Double(total)
    }

    private func pixelBounds(for frame: CGRect, screenFrame: CGRect) -> CGRect {
        let scaleX = CGFloat(width) / screenFrame.width
        let scaleY = CGFloat(height) / screenFrame.height
        let minX = max(0, floor((frame.minX - screenFrame.minX) * scaleX))
        let minY = max(0, floor((frame.minY - screenFrame.minY) * scaleY))
        let maxX = min(CGFloat(width), ceil((frame.maxX - screenFrame.minX) * scaleX))
        let maxY = min(CGFloat(height), ceil((frame.maxY - screenFrame.minY) * scaleY))
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func pixelLuminances(in bounds: CGRect) -> [Double] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        var result: [Double] = []
        result.reserveCapacity(Int(bounds.width * bounds.height))
        for y in Int(bounds.minY) ..< Int(bounds.maxY) {
            for x in Int(bounds.minX) ..< Int(bounds.maxX) {
                let offset = (y * width + x) * 4
                result.append(relativeLuminance(
                    red: bytes[offset],
                    green: bytes[offset + 1],
                    blue: bytes[offset + 2]
                ))
            }
        }
        return result
    }

    private func dominantLuminance(in luminances: [Double]) -> Double {
        guard !luminances.isEmpty else { return 0 }
        var bins = [Int](repeating: 0, count: 101)
        for luminance in luminances {
            bins[min(100, max(0, Int((luminance * 100).rounded())))] += 1
        }
        let dominantIndex = bins.indices.max { bins[$0] < bins[$1] } ?? 0
        let candidates = luminances.filter {
            min(100, max(0, Int(($0 * 100).rounded()))) == dominantIndex
        }.sorted()
        return candidates[candidates.count / 2]
    }

    private func contrastRatio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func relativeLuminance(red: UInt8, green: UInt8, blue: UInt8) -> Double {
        let channels = [red, green, blue].map { value -> Double in
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
