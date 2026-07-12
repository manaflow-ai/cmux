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
            app.otherElements["TerminalThemeStage-\(stage)"].waitForExistence(timeout: 8),
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
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["CMUX_THEME_EVIDENCE_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
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
}
