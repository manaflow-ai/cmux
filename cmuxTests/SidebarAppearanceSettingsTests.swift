import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Sidebar appearance & settings
final class SidebarActiveForegroundColorTests: XCTestCase {
    func testLightAppearanceUsesBlackWithRequestedOpacity() {
        guard let lightAppearance = NSAppearance(named: .aqua),
              let color = sidebarActiveForegroundNSColor(
                  opacity: 0.8,
                  appAppearance: lightAppearance
              ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.8, accuracy: 0.001)
    }

    func testDarkAppearanceUsesWhiteWithRequestedOpacity() {
        guard let darkAppearance = NSAppearance(named: .darkAqua),
              let color = sidebarActiveForegroundNSColor(
                  opacity: 0.65,
                  appAppearance: darkAppearance
              ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }
}


final class SidebarBranchLayoutSettingsTests: XCTestCase {
    func testDefaultUsesVerticalLayout() {
        let suiteName = "SidebarBranchLayoutSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))
    }

    func testStoredPreferenceOverridesDefault() {
        let suiteName = "SidebarBranchLayoutSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: SidebarBranchLayoutSettings.key)
        XCTAssertFalse(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))

        defaults.set(true, forKey: SidebarBranchLayoutSettings.key)
        XCTAssertTrue(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))
    }
}


final class SidebarActiveTabIndicatorSettingsTests: XCTestCase {
    func testDefaultStyleWhenUnset() {
        let suiteName = "SidebarActiveTabIndicatorSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(
            SidebarActiveTabIndicatorSettings.current(defaults: defaults),
            SidebarActiveTabIndicatorSettings.defaultStyle
        )
    }

    func testStoredStyleParsesAndInvalidFallsBack() {
        let suiteName = "SidebarActiveTabIndicatorSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(SidebarActiveTabIndicatorStyle.leftRail.rawValue, forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(SidebarActiveTabIndicatorSettings.current(defaults: defaults), .leftRail)

        defaults.set("rail", forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(SidebarActiveTabIndicatorSettings.current(defaults: defaults), .leftRail)

        defaults.set("not-a-style", forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(
            SidebarActiveTabIndicatorSettings.current(defaults: defaults),
            SidebarActiveTabIndicatorSettings.defaultStyle
        )
    }
}

@Suite
struct SidebarTabItemFontScaleTests {
    @Test func defaultSidebarFontScaleIsUnitScale() {
        let scale = SidebarTabItemFontScale.scale(for: GhosttyConfig.defaultSidebarFontSize)

        #expect(abs(scale - 1) <= 0.0001)
    }

    @Test func sidebarFontScaleIsProportionalToDefaultSidebarSize() {
        let scale = SidebarTabItemFontScale.scale(for: 18)

        #expect(abs(scale - (18 / GhosttyConfig.defaultSidebarFontSize)) <= 0.0001)
    }

    @Test func sidebarFontScaleClampsSmallSizes() {
        let scale = SidebarTabItemFontScale.scale(for: 4)

        #expect(abs(scale - (GhosttyConfig.minSidebarFontSize / GhosttyConfig.defaultSidebarFontSize)) <= 0.0001)
    }

    @Test func sidebarFontScaleClampsLargeSizes() {
        let scale = SidebarTabItemFontScale.scale(for: 48)

        #expect(abs(scale - (GhosttyConfig.maxSidebarFontSize / GhosttyConfig.defaultSidebarFontSize)) <= 0.0001)
    }

    @Test func sidebarFontScaleFallsBackToDefaultForNonFiniteValue() {
        let scale = SidebarTabItemFontScale.scale(for: CGFloat.nan)

        #expect(abs(scale - 1) <= 0.0001)
    }
}


