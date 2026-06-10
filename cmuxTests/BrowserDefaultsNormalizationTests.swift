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
final class BrowserDefaultsNormalizationTests: XCTestCase {
    /// Moving default registration + settings normalization out of
    /// `BrowserPanelView.onAppear` into the model bootstrap (issue #5303) keeps the
    /// canonicalization behavior: an out-of-range or legacy raw value stored in
    /// defaults is rewritten to its canonical form, and registered fallbacks are
    /// available for unset keys.
    func testNormalizeRewritesOutOfRangeAndLegacyValues() throws {
        let suiteName = "cmux.browserDefaultsNormalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Out-of-range / invalid raw values that must be canonicalized.
        defaults.set("not-a-real-mode", forKey: BrowserThemeSettings.modeKey)
        defaults.set("not-a-real-variant", forKey: BrowserImportHintSettings.variantKey)
        defaults.set(999, forKey: BrowserToolbarAccessorySpacingDebugSettings.key)
        defaults.set(999.0, forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
        defaults.set(-5.0, forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey)

        BrowserPanel.normalizeBrowserDefaults(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: BrowserThemeSettings.modeKey), BrowserThemeSettings.defaultMode.rawValue)
        XCTAssertEqual(defaults.string(forKey: BrowserImportHintSettings.variantKey), BrowserImportHintSettings.defaultVariant.rawValue)
        XCTAssertEqual(defaults.integer(forKey: BrowserToolbarAccessorySpacingDebugSettings.key), BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing)
        XCTAssertEqual(defaults.double(forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey), BrowserProfilePopoverDebugSettings.defaultHorizontalPadding, accuracy: 0.0001)
        XCTAssertEqual(defaults.double(forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey), BrowserProfilePopoverDebugSettings.defaultVerticalPadding, accuracy: 0.0001)

        // Registered fallbacks are available for keys that were never set.
        XCTAssertEqual(defaults.string(forKey: BrowserSearchSettings.searchEngineKey), BrowserSearchSettings.defaultSearchEngine.rawValue)
    }

    /// Already-canonical, in-range values must be left untouched (no clobbering of
    /// valid user settings during normalization).
    func testNormalizePreservesValidValues() throws {
        let suiteName = "cmux.browserDefaultsNormalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let validSpacing = BrowserToolbarAccessorySpacingDebugSettings.supportedValues.last ?? BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
        // Resolve the app-target theme mode via the app-only settings type; the bare
        // `BrowserThemeMode` is ambiguous here because this file also imports
        // `CmuxSettings`, which declares a same-named enum.
        let validThemeRaw = BrowserThemeSettings.mode(for: "dark").rawValue
        defaults.set(validThemeRaw, forKey: BrowserThemeSettings.modeKey)
        defaults.set(validSpacing, forKey: BrowserToolbarAccessorySpacingDebugSettings.key)

        BrowserPanel.normalizeBrowserDefaults(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: BrowserThemeSettings.modeKey), validThemeRaw)
        XCTAssertEqual(defaults.integer(forKey: BrowserToolbarAccessorySpacingDebugSettings.key), validSpacing)
    }
}

