@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class WindowChromeSeparatorColorTests: XCTestCase {
    func testDarkChromeSeparatorMatchesBonsplitDerivation() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let color = WindowChromeSeparatorColor.color(forChromeBackground: backgroundColor)
        let rgba = rgbaComponents(color)

        XCTAssertEqual(rgba.red, CGFloat(39.0 / 255.0) + CGFloat(0.16), accuracy: 0.0001)
        XCTAssertEqual(rgba.green, CGFloat(40.0 / 255.0) + CGFloat(0.16), accuracy: 0.0001)
        XCTAssertEqual(rgba.blue, CGFloat(34.0 / 255.0) + CGFloat(0.16), accuracy: 0.0001)
        XCTAssertEqual(rgba.alpha, CGFloat(0.36), accuracy: 0.0001)
    }

    func testLightChromeSeparatorMatchesBonsplitDerivation() {
        guard let backgroundColor = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test color")
            return
        }

        let color = WindowChromeSeparatorColor.color(forChromeBackground: backgroundColor)
        let rgba = rgbaComponents(color)

        XCTAssertEqual(rgba.red, CGFloat(253.0 / 255.0) - CGFloat(0.12), accuracy: 0.0001)
        XCTAssertEqual(rgba.green, CGFloat(246.0 / 255.0) - CGFloat(0.12), accuracy: 0.0001)
        XCTAssertEqual(rgba.blue, CGFloat(227.0 / 255.0) - CGFloat(0.12), accuracy: 0.0001)
        XCTAssertEqual(rgba.alpha, CGFloat(0.26), accuracy: 0.0001)
    }

    private func rgbaComponents(_ color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }
}

