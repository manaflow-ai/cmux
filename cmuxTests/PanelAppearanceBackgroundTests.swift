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


final class PanelAppearanceBackgroundTests: XCTestCase {
    func testTransparentGhosttyOpacityUsesClearContentBackground() {
        var config = GhosttyConfig()
        config.backgroundColor = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1.0)
        config.backgroundOpacity = 0.42
        config.backgroundBlur = .disabled

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertTrue(appearance.usesClearContentBackground)
        XCTAssertFalse(appearance.drawsContentBackground)
        XCTAssertEqual(appearance.backgroundColor.alphaComponent, 0.42, accuracy: 0.0001)
        XCTAssertEqual(appearance.contentBackgroundColor.alphaComponent, 0.0, accuracy: 0.0001)
    }

    func testOpaqueGhosttyBackgroundKeepsPanelFill() {
        var config = GhosttyConfig()
        config.backgroundColor = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1.0)
        config.backgroundOpacity = 1.0
        config.backgroundBlur = .disabled

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertFalse(appearance.usesClearContentBackground)
        XCTAssertTrue(appearance.drawsContentBackground)
        XCTAssertEqual(appearance.backgroundColor.alphaComponent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(appearance.contentBackgroundColor.alphaComponent, 1.0, accuracy: 0.0001)
    }

    func testLowContrastPanelForegroundFallsBackToReadableColor() {
        var config = GhosttyConfig()
        config.backgroundColor = NSColor(hex: "#FFFFFF")!
        config.backgroundOpacity = 1.0
        config.foregroundColor = NSColor(hex: "#FFFFFF")!

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertEqual(appearance.foregroundColor.hexString(), "#000000")
    }

    func testReadablePanelForegroundPreservesThemeColor() {
        var config = GhosttyConfig()
        config.backgroundColor = NSColor(hex: "#000000")!
        config.backgroundOpacity = 1.0
        config.foregroundColor = NSColor(hex: "#FDF6E3")!

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertEqual(appearance.foregroundColor.hexString(), "#FDF6E3")
    }

    func testGhosttyGlassBackgroundUsesClearContentBackground() {
        var config = GhosttyConfig()
        config.backgroundOpacity = 1.0
        config.backgroundBlur = .macosGlassRegular

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertTrue(appearance.usesClearContentBackground)
        XCTAssertFalse(appearance.drawsContentBackground)
        XCTAssertEqual(appearance.backgroundColor.alphaComponent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(appearance.contentBackgroundColor.alphaComponent, 0.0, accuracy: 0.0001)
    }

    func testTransparentWindowSettingUsesClearContentBackground() {
        var config = GhosttyConfig()
        config.backgroundOpacity = 1.0
        config.backgroundBlur = .disabled

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: true)

        XCTAssertTrue(appearance.usesClearContentBackground)
        XCTAssertFalse(appearance.drawsContentBackground)
        XCTAssertEqual(appearance.backgroundColor.alphaComponent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(appearance.contentBackgroundColor.alphaComponent, 0.0, accuracy: 0.0001)
    }
}


