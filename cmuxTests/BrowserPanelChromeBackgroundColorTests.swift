import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class BrowserPanelChromeBackgroundColorTests: XCTestCase {
    func testLightModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .light)
    }

    func testDarkModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .dark)
    }

    func testTransparentGhosttyBackgroundUsesClearBlankBrowserChrome() {
        let baseColor = NSColor(srgbRed: 0.13, green: 0.29, blue: 0.47, alpha: 1.0)
        let themeBackground = GhosttyBackgroundTheme.color(backgroundColor: baseColor, opacity: 0.42)

        guard let actual = resolvedBrowserChromeBackgroundColor(
            for: .dark,
            themeBackgroundColor: themeBackground,
            drawsBackground: false
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(actual.alphaComponent, 0.0, accuracy: 0.001)
    }

    func testGhosttyBackgroundThemeColorCompositesTranslucentBackgrounds() {
        let baseColor = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.04, alpha: 1.0)
        let themeBackground = GhosttyBackgroundTheme.color(backgroundColor: baseColor, opacity: 0.05)

        XCTAssertEqual(themeBackground.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testBrowserChromeColorSchemeAccountsForTranslucentBackground() {
        let darkTranslucentBackground = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.04, alpha: 0.05)

        XCTAssertEqual(
            resolvedBrowserChromeColorScheme(
                for: .dark,
                themeBackgroundColor: darkTranslucentBackground,
                windowBackgroundColor: .white
            ),
            .light
        )
    }

    func testBrowserChromeDrawDecisionClearsBlankPageForTransparentGhosttyBackground() {
        XCTAssertFalse(BrowserPanel.drawsWebViewBackground(
            isBlankPage: true,
            opacity: 0.42,
            usesGhosttyGlassStyle: false,
            usesTransparentWindow: false
        ))
    }

    func testBrowserChromeDrawDecisionClearsBlankPageForGhosttyGlassStyle() {
        XCTAssertFalse(BrowserPanel.drawsWebViewBackground(
            isBlankPage: true,
            opacity: 1.0,
            usesGhosttyGlassStyle: true,
            usesTransparentWindow: false
        ))
    }

    func testBrowserChromeDrawDecisionClearsBlankPageForTransparentWindow() {
        XCTAssertFalse(BrowserPanel.drawsWebViewBackground(
            isBlankPage: true,
            opacity: 1.0,
            usesGhosttyGlassStyle: false,
            usesTransparentWindow: true
        ))
    }

    func testBrowserChromeDrawDecisionKeepsFillForRealPagesWithTransparentGhosttyBackground() {
        XCTAssertTrue(BrowserPanel.drawsWebViewBackground(
            isBlankPage: false,
            opacity: 0.42,
            usesGhosttyGlassStyle: false,
            usesTransparentWindow: false
        ))
    }

    func testBrowserChromeDrawDecisionClearsTransparentInternalRealPagesWithTransparentGhosttyBackground() {
        XCTAssertFalse(BrowserPanel.drawsWebViewBackground(
            isBlankPage: false,
            usesTransparentBackground: true,
            opacity: 0.42,
            usesGhosttyGlassStyle: false,
            usesTransparentWindow: false
        ))
    }

    func testBrowserChromeDrawDecisionKeepsFillForOpaqueGhosttyBackground() {
        XCTAssertTrue(BrowserPanel.drawsWebViewBackground(
            isBlankPage: true,
            opacity: 1.0,
            usesGhosttyGlassStyle: false,
            usesTransparentWindow: false
        ))
    }

    func testBrowserBlankPageURLDetectionTreatsOnlyEmptyAndAboutBlankAsBlank() throws {
        XCTAssertTrue(BrowserPanel.isBlankBrowserPageURL(nil))
        XCTAssertTrue(BrowserPanel.isBlankBrowserPageURL(try XCTUnwrap(URL(string: "about:blank"))))
        XCTAssertFalse(BrowserPanel.isBlankBrowserPageURL(try XCTUnwrap(URL(string: "https://mail.google.com/"))))
    }

    func testBrowserBlankPageDetectionTreatsPendingRealNavigationAsNonBlank() throws {
        XCTAssertFalse(BrowserPanel.isBlankBrowserPage(
            liveURL: nil,
            currentURL: nil,
            pendingNavigationURL: try XCTUnwrap(URL(string: "https://mail.google.com/")),
            isMainFrameProvisionalNavigationActive: true
        ))
    }

    func testBrowserBlankPageDetectionTreatsInitialPendingRealNavigationAsNonBlank() throws {
        XCTAssertFalse(BrowserPanel.isBlankBrowserPage(
            liveURL: nil,
            currentURL: nil,
            pendingNavigationURL: try XCTUnwrap(URL(string: "https://mail.google.com/")),
            isMainFrameProvisionalNavigationActive: false
        ))
    }

    func testBrowserBlankPageDetectionClearsAfterCommittedAboutBlank() throws {
        XCTAssertTrue(BrowserPanel.isBlankBrowserPage(
            liveURL: try XCTUnwrap(URL(string: "about:blank")),
            currentURL: try XCTUnwrap(URL(string: "about:blank")),
            pendingNavigationURL: try XCTUnwrap(URL(string: "about:blank")),
            isMainFrameProvisionalNavigationActive: false
        ))
    }

    private func assertResolvedColorMatchesTheme(
        for colorScheme: ColorScheme,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.13, green: 0.29, blue: 0.47, alpha: 1.0)

        guard
            let actual = resolvedBrowserChromeBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground,
                drawsBackground: true
            ).usingColorSpace(.sRGB),
            let expected = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}


