import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class GhosttyBackgroundThemeTests: XCTestCase {
    func testColorClampsOpacity() {
        let base = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1.0)

        let lowerClamped = GhosttyBackgroundTheme.color(backgroundColor: base, opacity: -2.0)
        XCTAssertEqual(lowerClamped.alphaComponent, 0.0, accuracy: 0.0001)

        let upperClamped = GhosttyBackgroundTheme.color(backgroundColor: base, opacity: 5.0)
        XCTAssertEqual(upperClamped.alphaComponent, 1.0, accuracy: 0.0001)
    }

    func testColorFromNotificationUsesBackgroundAndOpacity() {
        let fallbackColor = NSColor.black
        let fallbackOpacity = 1.0
        let notification = Notification(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0),
                GhosttyNotificationKey.backgroundOpacity: NSNumber(value: 0.57),
            ]
        )

        let actual = GhosttyBackgroundTheme.color(
            from: notification,
            fallbackColor: fallbackColor,
            fallbackOpacity: fallbackOpacity
        )
        guard let srgb = actual.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(srgb.redComponent, 0.18, accuracy: 0.005)
        XCTAssertEqual(srgb.greenComponent, 0.29, accuracy: 0.005)
        XCTAssertEqual(srgb.blueComponent, 0.44, accuracy: 0.005)
        XCTAssertEqual(srgb.alphaComponent, 0.57, accuracy: 0.005)
    }

    func testColorFromNotificationFallsBackWhenPayloadMissing() {
        let fallbackColor = NSColor(srgbRed: 0.12, green: 0.34, blue: 0.56, alpha: 1.0)
        let fallbackOpacity = 0.42
        let notification = Notification(name: .ghosttyDefaultBackgroundDidChange)

        let actual = GhosttyBackgroundTheme.color(
            from: notification,
            fallbackColor: fallbackColor,
            fallbackOpacity: fallbackOpacity
        )
        guard let srgb = actual.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(srgb.redComponent, 0.12, accuracy: 0.005)
        XCTAssertEqual(srgb.greenComponent, 0.34, accuracy: 0.005)
        XCTAssertEqual(srgb.blueComponent, 0.56, accuracy: 0.005)
        XCTAssertEqual(srgb.alphaComponent, 0.42, accuracy: 0.005)
    }
}

