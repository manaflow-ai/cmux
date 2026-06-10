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


final class TitlebarDoubleClickPreferenceTests: XCTestCase {
    func testResolvesZoomForFillPreference() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [
                "AppleActionOnDoubleClick": "Fill",
            ]),
            .zoom
        )
    }

    func testResolvesMiniaturizeForExplicitMinimizePreference() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [
                "AppleActionOnDoubleClick": "Minimize",
            ]),
            .miniaturize
        )
    }

    func testResolvesNoneForNoActionPreference() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [
                "AppleActionOnDoubleClick": "No Action",
            ]),
            .none
        )
    }

    func testFallsBackToLegacyMiniaturizePreference() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [
                "AppleMiniaturizeOnDoubleClick": true,
            ]),
            .miniaturize
        )
    }

    func testDefaultsToZoomWhenPreferenceIsMissing() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [:]),
            .zoom
        )
    }
}

