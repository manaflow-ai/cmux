import XCTest
import UIKit

final class TerminalThemeParityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChromeRepaintsForLiveThemes() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_WORKSPACE_DETAIL_DELAYED_TERMINAL"] = "1"
        app.launchEnvironment["CMUX_UITEST_THEME_PARITY_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE"] = "1"
        app.launch()
        defer { app.terminate() }

        try waitForStage("dark", in: app)
        try capture(app, name: "dark-theme", expectedBackground: (16, 21, 34))
        try waitForStage("light", in: app)
        try capture(app, name: "light-theme-live-reload", expectedBackground: (244, 240, 223))
        try waitForStage("custom", in: app)
        try capture(app, name: "custom-theme-live-reload", expectedBackground: (6, 63, 70))
    }

    @MainActor
    private func waitForStage(_ stage: String, in app: XCUIApplication) throws {
        XCTAssertTrue(
            app.otherElements["TerminalThemeStage-\(stage)"].waitForExistence(timeout: 10),
            "Theme fixture did not reach \(stage)."
        )
    }

    @MainActor
    private func capture(
        _ app: XCUIApplication,
        name: String,
        expectedBackground: (red: Int, green: Int, blue: Int)
    ) throws {
        let screenshot = app.screenshot()
        let pixels = try ScreenshotPixels(image: screenshot.image)
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
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["CMUX_THEME_EVIDENCE_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
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
}
