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


@MainActor
final class WorkspaceChromeColorTests: XCTestCase {
    func testBonsplitChromeHexIncludesAlphaWhenTranslucent() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let hex = Workspace.bonsplitChromeHex(backgroundColor: color, backgroundOpacity: 0.5)
        XCTAssertEqual(hex, "#1122337F")
    }

    func testBonsplitChromeHexOmitsAlphaWhenOpaque() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let hex = Workspace.bonsplitChromeHex(backgroundColor: color, backgroundOpacity: 1.0)
        XCTAssertEqual(hex, "#112233")
    }

    func testBonsplitChromeHexKeepsBackdropWhenSharingWindowBackdrop() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let hex = Workspace.bonsplitChromeHex(
            backgroundColor: color,
            backgroundOpacity: 0.5,
            sharesWindowBackdrop: true
        )
        XCTAssertEqual(hex, "#1122337F")
    }

    func testBonsplitChromeColorsKeepPaneClearWhenTerminalUsesHostLayerBackground() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let colors = Workspace.bonsplitChromeColors(
            backgroundColor: color,
            backgroundOpacity: 0.5,
            renderingMode: .windowHostBackdrop
        )

        XCTAssertEqual(colors.backgroundHex, "#1122337F")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#1122337F")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#1122337F")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
    }

    func testBonsplitChromeColorsKeepSemanticBackgroundButClearLocalBackdropsWhenSharingWindowBackdrop() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let colors = Workspace.bonsplitChromeColors(
            backgroundColor: color,
            backgroundOpacity: 0.5,
            sharesWindowBackdrop: true,
            renderingMode: .windowHostBackdrop
        )

        XCTAssertEqual(colors.backgroundHex, "#1122337F")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#00000000")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#00000000")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
    }
}

