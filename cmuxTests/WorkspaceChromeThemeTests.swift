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


final class WorkspaceChromeThemeTests: XCTestCase {
    func testResolvedChromeColorsUsesLightGhosttyBackground() {
        guard let backgroundColor = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(from: backgroundColor)
        XCTAssertEqual(colors.backgroundHex, "#FDF6E3")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#FDF6E3")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#FDF6E3")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
        XCTAssertEqual(colors.borderHex, "#DED7C442")
    }

    func testResolvedChromeColorsUsesDarkGhosttyBackground() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(from: backgroundColor)
        XCTAssertEqual(colors.backgroundHex, "#272822")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#272822")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#272822")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
        XCTAssertEqual(colors.borderHex, "#4F504A5B")
    }

    func testResolvedChromeColorsKeepSemanticBackgroundButClearLocalBackdropsWhenSharingWindowBackdrop() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(
            from: backgroundColor,
            sharesWindowBackdrop: true
        )
        XCTAssertEqual(colors.backgroundHex, "#272822")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#00000000")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#00000000")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
        XCTAssertEqual(colors.borderHex, "#4F504A5B")
    }

    func testResolvedChromeColorsKeepPaneClearForRendererOwnedBackgrounds() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(
            from: backgroundColor,
            renderingMode: .ghosttyRendererOwnedBackgroundImage
        )
        XCTAssertEqual(colors.backgroundHex, "#272822")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#272822")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#272822")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
        XCTAssertEqual(colors.borderHex, "#4F504A5B")
    }
}

