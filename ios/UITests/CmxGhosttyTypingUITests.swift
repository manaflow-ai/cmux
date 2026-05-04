import UIKit
import XCTest

final class CmxGhosttyTypingUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment = [
            "CMUX_IOS_BRIDGE_TICKET": Self.directTicket,
            "CMUX_IOS_AUTOCONNECT": "1",
            "CMUX_IOS_UI_TESTING_ECHO_SESSION": "1",
        ]
        app.launch()
    }

    func testTypingIntoGhosttyRendersEchoedOutput() throws {
        let terminal = try openTerminal()

        terminal.tap()
        let input = app.descendants(matching: .any)["terminal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.typeText("echo UI_GHOSTTY_SYNC_OK\n")

        XCTAssertTrue(waitForTerminalValue(terminal, containing: "UI_GHOSTTY_SYNC_OK", timeout: 10))
    }

    func testRepeatedPinchZoomKeepsGhosttyResponsive() throws {
        app.terminate()
        app.launchEnvironment["CMUX_IOS_UI_TESTING_ZOOM_STRESS_CYCLES"] = "80"
        app.launch()

        let terminal = try openTerminal()

        terminal.tap()
        XCTAssertTrue(waitForTerminalValue(terminal, containing: "ZOOM_STRESS_DONE", timeout: 30))

        for _ in 0..<8 {
            terminal.pinch(withScale: 0.55, velocity: -1)
            terminal.pinch(withScale: 1.8, velocity: 1)
        }

        terminal.tap()
        let input = app.descendants(matching: .any)["terminal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.typeText("echo ZOOM_OK\n")

        XCTAssertTrue(waitForTerminalValue(terminal, containing: "ZOOM_OK", timeout: 10))
    }

    func testPaletteIndexedPromptUsesRemoteTheme() throws {
        app.terminate()
        app.launchEnvironment["CMUX_IOS_UI_TESTING_PALETTE_SESSION"] = "1"
        app.launch()

        let terminal = try openTerminal(expectedPrompt: "palette-test$")
        let image = terminal.screenshot().image

        XCTAssertGreaterThan(
            image.countPixels(where: { pixel in
                pixel.red > 180 && pixel.blue > 130 && pixel.green < 90
            }),
            20,
            "expected palette-indexed prompt text to render with the remote magenta palette entry"
        )
    }

    private func openTerminal() throws -> XCUIElement {
        try openTerminal(expectedPrompt: "ui-test$")
    }

    private func openTerminal(expectedPrompt: String) throws -> XCUIElement {
        let workspace = app.descendants(matching: .any)["workspace.row.1"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()

        let terminal = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTerminalValue(terminal, containing: expectedPrompt, timeout: 10))
        return terminal
    }

    private func waitForTerminalValue(
        _ terminal: XCUIElement,
        containing expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { element, _ in
            guard let terminal = element as? XCUIElement else { return false }
            return (terminal.value as? String)?.contains(expected) == true
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: terminal)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private static let directTicket = #"{"version":1,"alpn":"/cmux/cmx/3","endpoint":{"id":"ui-test-endpoint","addrs":[]},"auth":{"mode":"direct"},"node":{"id":"ui-test-node","name":"UI Test Mac","subtitle":"Ghostty echo session","kind":"macbook"}}"#
}

private struct CmxPixel {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
}

private extension UIImage {
    func countPixels(where predicate: (CmxPixel) -> Bool) -> Int {
        guard let cgImage else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let pixel = CmxPixel(
                red: pixels[offset],
                green: pixels[offset + 1],
                blue: pixels[offset + 2]
            )
            if predicate(pixel) {
                count += 1
            }
        }
        return count
    }
}
