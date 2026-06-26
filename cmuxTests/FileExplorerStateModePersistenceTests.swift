import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileExplorerStateModePersistenceTests: XCTestCase {
    private let modeKey = "rightSidebar.mode"
    private let customSidebarNameKey = "rightSidebar.customSidebarName"
    private let feedEnabledKey = RightSidebarBetaFeatureSettings.feedEnabledKey
    private let dockEnabledKey = RightSidebarBetaFeatureSettings.dockEnabledKey

    func testDisabledFeedStoredModeFallsBackToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
            defaults.set(false, forKey: feedEnabledKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)
        }
    }

    func testEnabledFeedStoredModeSurvives() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
            defaults.set(true, forKey: feedEnabledKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .feed)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.feed.rawValue)
        }
    }

    func testModeSetterClampsUnavailableBetaModes() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: feedEnabledKey)
            defaults.set(false, forKey: dockEnabledKey)
            let state = FileExplorerState()

            state.mode = .feed
            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)

            defaults.set(true, forKey: dockEnabledKey)
            state.mode = .dock
            XCTAssertEqual(state.mode, .dock)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.dock.rawValue)

            defaults.set(false, forKey: dockEnabledKey)
            state.refreshModeAvailability()
            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)
        }
    }

    func testStoredCustomSidebarModeFallsBackToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.customSidebar.rawValue, forKey: modeKey)
            defaults.set("status-board", forKey: customSidebarNameKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)
        }
    }

    func testCLIArgumentNormalizerMapsVaultAndSessionsToSessions() {
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "files"), .files)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "find"), .find)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "vault"), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "sessions"), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "feed"), .feed)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "dock"), .dock)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "notes"), .notes)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: " Vault "), .sessions)
        XCTAssertNil(RightSidebarMode.from(cliArgument: "custom-sidebar"))
        XCTAssertNil(RightSidebarMode.from(cliArgument: "custom"))
        XCTAssertNil(RightSidebarMode.from(cliArgument: "unknown"))
    }

    private func withSavedRightSidebarModeDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: modeKey)
        let previousCustomSidebarName = defaults.object(forKey: customSidebarNameKey)
        let previousFeedEnabled = defaults.object(forKey: feedEnabledKey)
        let previousDockEnabled = defaults.object(forKey: dockEnabledKey)
        defer {
            restore(previousMode, forKey: modeKey)
            restore(previousCustomSidebarName, forKey: customSidebarNameKey)
            restore(previousFeedEnabled, forKey: feedEnabledKey)
            restore(previousDockEnabled, forKey: dockEnabledKey)
        }
        body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
