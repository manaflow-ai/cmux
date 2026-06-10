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


final class WindowTransparencyDecisionTests: XCTestCase {
    private let sidebarBlendModeKey = "sidebarBlendMode"
    private let bgGlassEnabledKey = "bgGlassEnabled"

    func testTranslucentOpacityForcesClearWindowBackgroundOutsideSidebarBlendModePath() {
        withTemporaryWindowBackgroundDefaults {
            let defaults = UserDefaults.standard
            defaults.set("withinWindow", forKey: sidebarBlendModeKey)
            defaults.set(false, forKey: bgGlassEnabledKey)

            XCTAssertFalse(cmuxShouldUseTransparentBackgroundWindow())
            XCTAssertTrue(cmuxShouldUseClearWindowBackground(for: 0.80))
            XCTAssertFalse(cmuxShouldUseClearWindowBackground(for: 1.0))
        }
    }

    func testGlassEnabledDecisionIgnoresGlassImplementationAvailability() {
        XCTAssertTrue(
            cmuxShouldApplyWindowGlass(
                sidebarBlendMode: "behindWindow",
                bgGlassEnabled: true,
                glassEffectAvailable: false
            )
        )
        XCTAssertTrue(
            cmuxShouldApplyWindowGlass(
                sidebarBlendMode: "behindWindow",
                bgGlassEnabled: true,
                glassEffectAvailable: true
            )
        )
        XCTAssertFalse(
            cmuxShouldApplyWindowGlass(
                sidebarBlendMode: "withinWindow",
                bgGlassEnabled: true,
                glassEffectAvailable: true
            )
        )
        XCTAssertFalse(
            cmuxShouldApplyWindowGlass(
                sidebarBlendMode: "behindWindow",
                bgGlassEnabled: false,
                glassEffectAvailable: true
            )
        )
    }

    func testBehindWindowGlassPathKeepsTransparentWindowEnabled() {
        withTemporaryWindowBackgroundDefaults {
            let defaults = UserDefaults.standard
            defaults.set("behindWindow", forKey: sidebarBlendModeKey)
            defaults.set(true, forKey: bgGlassEnabledKey)

            XCTAssertTrue(cmuxShouldUseTransparentBackgroundWindow())
            XCTAssertTrue(cmuxShouldUseClearWindowBackground(for: 1.0))
        }
    }

    func testGhosttyGlassStyleForcesClearWindowBackgroundAtOpaqueOpacity() {
        withTemporaryWindowBackgroundDefaults {
            let defaults = UserDefaults.standard
            defaults.set("withinWindow", forKey: sidebarBlendModeKey)
            defaults.set(false, forKey: bgGlassEnabledKey)

            XCTAssertFalse(cmuxShouldUseTransparentBackgroundWindow())
            XCTAssertTrue(cmuxShouldUseClearWindowBackground(for: 1.0, usesGhosttyGlassStyle: true))
        }
    }

    private func withTemporaryWindowBackgroundDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let originalBlendMode = defaults.object(forKey: sidebarBlendModeKey)
        let originalGlassEnabled = defaults.object(forKey: bgGlassEnabledKey)
        defer {
            restoreDefaultsValue(originalBlendMode, key: sidebarBlendModeKey, defaults: defaults)
            restoreDefaultsValue(originalGlassEnabled, key: bgGlassEnabledKey, defaults: defaults)
        }
        body()
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

