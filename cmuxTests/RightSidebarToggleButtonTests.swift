import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers `rightSidebar.toggleButton`: placement layout rules and the
/// cmux.json path from file to the stored setting.
@MainActor
@Suite struct RightSidebarToggleButtonTests {
    private let key = SettingCatalog().rightSidebar.toggleButton

    // MARK: - Layout

    @Test func defaultPlacementIsTitlebarCorner() {
        #expect(key.defaultValue == .titlebar)
        #expect(key.id == "rightSidebar.toggleButton")
    }

    @Test func titlebarCornerButtonShowsOnlyWhileSidebarIsHidden() {
        let hidden = RightSidebarToggleButtonLayout.resolve(
            placement: .titlebar, isMinimalMode: false, isRightSidebarVisible: false
        )
        let shown = RightSidebarToggleButtonLayout.resolve(
            placement: .titlebar, isMinimalMode: false, isRightSidebarVisible: true
        )
        // The mode bar close button takes over the same corner while shown.
        #expect(hidden.showsCornerButton)
        #expect(!shown.showsCornerButton)
        #expect(hidden.modeBarCloseButtonUsesSidebarGlyph)
        #expect(shown.modeBarCloseButtonUsesSidebarGlyph)
        // Standard mode keeps the corner in the titlebar band, above every tab bar.
        #expect(hidden.tabBarTrailingInset == 0)
    }

    @Test func minimalModeTitlebarCornerReservesTabBarSpaceOnlyWhileSidebarIsHidden() {
        let hidden = RightSidebarToggleButtonLayout.resolve(
            placement: .titlebar, isMinimalMode: true, isRightSidebarVisible: false
        )
        let shown = RightSidebarToggleButtonLayout.resolve(
            placement: .titlebar, isMinimalMode: true, isRightSidebarVisible: true
        )
        #expect(hidden.tabBarTrailingInset == RightSidebarToggleButtonLayout.tabBarLaneWidth)
        #expect(shown.tabBarTrailingInset == 0)
    }

    @Test func paneTabBarPlacementAlwaysReservesTabBarSpace() {
        for minimal in [false, true] {
            for visible in [false, true] {
                let layout = RightSidebarToggleButtonLayout.resolve(
                    placement: .paneTabBar, isMinimalMode: minimal, isRightSidebarVisible: visible
                )
                #expect(layout.showsPaneTabBarButton)
                #expect(!layout.showsCornerButton)
                #expect(layout.tabBarTrailingInset == RightSidebarToggleButtonLayout.tabBarLaneWidth)
            }
        }
    }

    @Test func everyVisiblePlacementKeepsAButtonWhileSidebarIsHidden() {
        for placement in RightSidebarToggleButtonPlacement.allCases where placement != .hidden {
            for minimal in [false, true] {
                let layout = RightSidebarToggleButtonLayout.resolve(
                    placement: placement, isMinimalMode: minimal, isRightSidebarVisible: false
                )
                let hostCount = [layout.showsCornerButton, layout.showsPaneTabBarButton, layout.showsSidebarFooterButton]
                    .filter { $0 }.count
                #expect(hostCount == 1, "placement=\(placement) minimal=\(minimal)")
            }
        }
    }

    @Test func hiddenPlacementDrawsNoPersistentButtonAndReservesNothing() {
        let layout = RightSidebarToggleButtonLayout.resolve(
            placement: .hidden, isMinimalMode: true, isRightSidebarVisible: false
        )
        #expect(!layout.showsCornerButton)
        #expect(!layout.showsPaneTabBarButton)
        #expect(!layout.showsSidebarFooterButton)
        #expect(!layout.modeBarCloseButtonUsesSidebarGlyph)
        #expect(layout.tabBarTrailingInset == 0)
    }

    // MARK: - cmux.json

    @Test func settingsFileAppliesPlacementAndKeepsExtensionKeys() throws {
        let (defaults, configURL, cleanup) = try makeFixture()
        defer { cleanup() }
        try """
        { "rightSidebar": { "toggleButton": "paneTabBar", "width": 320 } }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        _ = makeStore(configURL: configURL, defaults: defaults)

        #expect(key.value(in: defaults) == .paneTabBar)
    }

    @Test func settingsFileIgnoresUnknownPlacement() throws {
        let (defaults, configURL, cleanup) = try makeFixture()
        defer { cleanup() }
        try """
        { "rightSidebar": { "toggleButton": "edgeHandle" } }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        _ = makeStore(configURL: configURL, defaults: defaults)

        #expect(!key.hasStoredValue(in: defaults))
        #expect(key.value(in: defaults) == .titlebar)
    }

    @Test func paletteCommandWritesThePlacement() throws {
        let (defaults, _, cleanup) = try makeFixture()
        defer { cleanup() }
        for placement in RightSidebarToggleButtonPlacement.allCases {
            placement.apply(defaults: defaults)
            #expect(key.value(in: defaults) == placement)
        }
        let commandIds = Set(ContentView.commandPaletteRightSidebarToggleButtonContributions().map(\.commandId))
        #expect(commandIds.count == RightSidebarToggleButtonPlacement.allCases.count)
    }

    @Test func supportedPathsAndTemplateExposeTheSetting() {
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("rightSidebar.toggleButton"))
        #expect(CmuxSettingsFileStore.defaultTemplate().contains("\"toggleButton\""))
    }

    private func makeFixture() throws -> (UserDefaults, URL, () -> Void) {
        let suiteName = "RightSidebarToggleButtonTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("right-sidebar-toggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json", isDirectory: false)
        return (defaults, configURL, {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func makeStore(configURL: URL, defaults: UserDefaults) -> CmuxSettingsFileStore {
        CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            startWatching: false
        )
    }
}
