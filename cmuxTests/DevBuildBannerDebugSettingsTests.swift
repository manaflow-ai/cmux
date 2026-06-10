import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Sparkle
import CmuxUpdater

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Dev build banner debug settings
final class DevBuildBannerDebugSettingsTests: XCTestCase {
    func testShowSidebarBannerDefaultsToVisible() {
        let suiteName = "DevBuildBannerDebugSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        XCTAssertTrue(DevBuildBannerDebugSettings.showSidebarBanner(defaults: defaults))
    }

    func testShowSidebarBannerRespectsStoredValue() {
        let suiteName = "DevBuildBannerDebugSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        XCTAssertFalse(DevBuildBannerDebugSettings.showSidebarBanner(defaults: defaults))

        defaults.set(true, forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        XCTAssertTrue(DevBuildBannerDebugSettings.showSidebarBanner(defaults: defaults))
    }
}


