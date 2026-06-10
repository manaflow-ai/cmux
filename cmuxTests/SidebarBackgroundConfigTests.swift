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


final class SidebarBackgroundConfigTests: XCTestCase {

    func testParseSidebarBackgroundSingleHex() {
        var config = GhosttyConfig()
        config.parse("sidebar-background = #336699")
        XCTAssertEqual(config.rawSidebarBackground, "#336699")
    }

    func testParseSidebarBackgroundDualMode() {
        var config = GhosttyConfig()
        config.parse("sidebar-background = light:#fbf3db,dark:#103c48")
        XCTAssertEqual(config.rawSidebarBackground, "light:#fbf3db,dark:#103c48")
    }

    func testParseSidebarTintOpacity() {
        var config = GhosttyConfig()
        config.parse("sidebar-tint-opacity = 0.4")
        XCTAssertEqual(config.sidebarTintOpacity ?? -1, 0.4, accuracy: 0.0001)
    }

    func testParseSidebarTintOpacityClampedAboveOne() {
        var config = GhosttyConfig()
        config.parse("sidebar-tint-opacity = 1.5")
        XCTAssertEqual(config.sidebarTintOpacity ?? -1, 1.0, accuracy: 0.0001)
    }

    func testParseSidebarTintOpacityClampedBelowZero() {
        var config = GhosttyConfig()
        config.parse("sidebar-tint-opacity = -0.3")
        XCTAssertEqual(config.sidebarTintOpacity ?? -1, 0.0, accuracy: 0.0001)
    }

    func testResolveSidebarBackgroundSingleHex() {
        var config = GhosttyConfig()
        config.rawSidebarBackground = "#336699"
        config.resolveSidebarBackground(preferredColorScheme: .light)

        XCTAssertNotNil(config.sidebarBackground)
        XCTAssertNil(config.sidebarBackgroundLight)
        XCTAssertNil(config.sidebarBackgroundDark)
    }

    func testResolveSidebarBackgroundDualModeSetsLightAndDark() {
        var config = GhosttyConfig()
        config.rawSidebarBackground = "light:#fbf3db,dark:#103c48"
        config.resolveSidebarBackground(preferredColorScheme: .light)

        XCTAssertNotNil(config.sidebarBackgroundLight)
        XCTAssertNotNil(config.sidebarBackgroundDark)
        XCTAssertNotNil(config.sidebarBackground)
    }

    func testResolveSidebarBackgroundNilWhenNoRaw() {
        var config = GhosttyConfig()
        config.resolveSidebarBackground(preferredColorScheme: .dark)

        XCTAssertNil(config.sidebarBackground)
        XCTAssertNil(config.sidebarBackgroundLight)
        XCTAssertNil(config.sidebarBackgroundDark)
    }

    func testApplyToUserDefaultsSkipsWritesWhenNoConfig() {
        let defaults = UserDefaults.standard
        let testKey = "sidebarTintHex"
        let original = defaults.string(forKey: testKey)
        defer { restoreDefaultsValue(original, key: testKey, defaults: defaults) }

        defaults.set("#AAAAAA", forKey: testKey)

        var config = GhosttyConfig()
        config.applySidebarAppearanceToUserDefaults()

        XCTAssertEqual(defaults.string(forKey: testKey), "#AAAAAA",
                       "Should not overwrite UserDefaults when rawSidebarBackground is nil")
    }

    func testApplyToUserDefaultsWritesHexWhenConfigSet() {
        let defaults = UserDefaults.standard
        let keys = ["sidebarTintHex", "sidebarTintHexLight", "sidebarTintHexDark"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                restoreDefaultsValue(original, key: key, defaults: defaults)
            }
        }

        var config = GhosttyConfig()
        config.rawSidebarBackground = "#336699"
        config.resolveSidebarBackground(preferredColorScheme: .light)
        config.applySidebarAppearanceToUserDefaults()

        XCTAssertEqual(defaults.string(forKey: "sidebarTintHex"), "#336699")
        XCTAssertNil(defaults.string(forKey: "sidebarTintHexLight"))
        XCTAssertNil(defaults.string(forKey: "sidebarTintHexDark"))
    }

    func testApplyToUserDefaultsClearsStaleKeysOnSwitchFromDualToSingle() {
        let defaults = UserDefaults.standard
        let keys = ["sidebarTintHex", "sidebarTintHexLight", "sidebarTintHexDark"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                restoreDefaultsValue(original, key: key, defaults: defaults)
            }
        }

        defaults.set("#AAAAAA", forKey: "sidebarTintHexLight")
        defaults.set("#BBBBBB", forKey: "sidebarTintHexDark")

        var config = GhosttyConfig()
        config.rawSidebarBackground = "#222222"
        config.resolveSidebarBackground(preferredColorScheme: .light)
        config.applySidebarAppearanceToUserDefaults()

        XCTAssertEqual(defaults.string(forKey: "sidebarTintHex"), "#222222")
        XCTAssertNil(defaults.string(forKey: "sidebarTintHexLight"),
                     "Stale light key should be cleared")
        XCTAssertNil(defaults.string(forKey: "sidebarTintHexDark"),
                     "Stale dark key should be cleared")
    }

    func testApplyToUserDefaultsOnlyWritesOpacityWhenExplicit() {
        let defaults = UserDefaults.standard
        let keys = ["sidebarTintHex", "sidebarTintHexLight", "sidebarTintHexDark", "sidebarTintOpacity"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                restoreDefaultsValue(original, key: key, defaults: defaults)
            }
        }

        defaults.set(0.18, forKey: "sidebarTintOpacity")

        var config = GhosttyConfig()
        config.rawSidebarBackground = "#336699"
        config.resolveSidebarBackground(preferredColorScheme: .light)
        config.applySidebarAppearanceToUserDefaults()

        XCTAssertEqual(defaults.double(forKey: "sidebarTintOpacity"), 0.18, accuracy: 0.0001,
                       "Should not overwrite opacity when config doesn't set sidebar-tint-opacity")
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

