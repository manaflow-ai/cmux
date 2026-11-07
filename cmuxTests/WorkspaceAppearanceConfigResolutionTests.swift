import AppKit
import Bonsplit
import CmuxFoundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceAppearanceConfigResolutionTests: XCTestCase {
    func testResolvedAppearanceConfigPrefersGhosttyRuntimeAppearanceOverLoadedConfig() {
        guard let loadedBackground = NSColor(hex: "#112233"),
              let runtimeBackground = NSColor(hex: "#FDF6E3"),
              let loadedForeground = NSColor(hex: "#EEEEEE"),
              let runtimeForeground = NSColor(hex: "#4A4543"),
              let loadedCursor = NSColor(hex: "#DDDDDD"),
              let runtimeCursor = NSColor(hex: "#3A3432"),
              let loadedCursorText = NSColor(hex: "#111111"),
              let runtimeCursorText = NSColor(hex: "#F7F7F7"),
              let loadedSelectionBackground = NSColor(hex: "#222222"),
              let runtimeSelectionBackground = NSColor(hex: "#A5A2A2"),
              let loadedSelectionForeground = NSColor(hex: "#EEEEEE"),
              let runtimeSelectionForeground = NSColor(hex: "#4A4543") else {
            XCTFail("Expected valid test colors")
            return
        }

        var loaded = GhosttyConfig()
        loaded.backgroundColor = loadedBackground
        loaded.foregroundColor = loadedForeground
        loaded.cursorColor = loadedCursor
        loaded.cursorTextColor = loadedCursorText
        loaded.selectionBackground = loadedSelectionBackground
        loaded.selectionForeground = loadedSelectionForeground
        loaded.unfocusedSplitOpacity = 0.42

        let resolved = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            loadConfig: { loaded },
            defaultBackground: { runtimeBackground },
            defaultForeground: { runtimeForeground },
            defaultCursor: { runtimeCursor },
            defaultCursorText: { runtimeCursorText },
            defaultSelectionBackground: { runtimeSelectionBackground },
            defaultSelectionForeground: { runtimeSelectionForeground }
        )

        XCTAssertEqual(resolved.backgroundColor.hexString(), "#FDF6E3")
        XCTAssertEqual(resolved.foregroundColor.hexString(), "#4A4543")
        XCTAssertEqual(resolved.cursorColor.hexString(), "#3A3432")
        XCTAssertEqual(resolved.cursorTextColor.hexString(), "#F7F7F7")
        XCTAssertEqual(resolved.selectionBackground.hexString(), "#A5A2A2")
        XCTAssertEqual(resolved.selectionForeground.hexString(), "#4A4543")
        XCTAssertEqual(resolved.unfocusedSplitOpacity, 0.42, accuracy: 0.0001)
    }

    func testResolvedAppearanceConfigPrefersExplicitBackgroundOverride() {
        guard let loadedBackground = NSColor(hex: "#112233"),
              let runtimeBackground = NSColor(hex: "#FDF6E3"),
              let explicitOverride = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test colors")
            return
        }

        var loaded = GhosttyConfig()
        loaded.backgroundColor = loadedBackground

        let resolved = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            backgroundOverride: explicitOverride,
            loadConfig: { loaded },
            defaultBackground: { runtimeBackground }
        )

        XCTAssertEqual(resolved.backgroundColor.hexString(), "#272822")
    }

    @MainActor
    func testSurfaceTabBarLayoutReachesBonsplitAndReappliesOnChange() throws {
        typealias Layout = SurfaceTabBarLayoutSettings
        let suiteName = "cmux-surface-tab-bar-layout-workspace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = Layout(defaults: defaults)

        let workspace = Workspace(title: "Tests")
        defer { workspace.teardownAllPanels() }
        // Settle colors and font first so the second apply can only change through layout.
        workspace.applyGhosttyChrome(from: GhosttyConfig(), reason: "test-surface-tab-bar-layout", tabBarLayout: layout)
        var appearance = workspace.bonsplitController.configuration.appearance
        XCTAssertEqual(appearance.tabWidthMode, .fixed)
        XCTAssertEqual(appearance.tabMaxWidth, Layout.defaultMaxTabWidth)
        XCTAssertEqual(appearance.tabBarHeight, WindowChromeMetrics.bonsplitTabBarHeight)

        defaults.set(Layout.WidthMode.fill.rawValue, forKey: Layout.widthModeKey)
        defaults.set(320.0, forKey: Layout.maxTabWidthKey)
        defaults.set(36.0, forKey: Layout.heightKey)
        workspace.applyGhosttyChrome(from: GhosttyConfig(), reason: "test-surface-tab-bar-layout", tabBarLayout: layout)

        appearance = workspace.bonsplitController.configuration.appearance
        XCTAssertEqual(appearance.tabWidthMode, .fill)
        XCTAssertEqual(appearance.tabMaxWidth, 320)
        XCTAssertEqual(appearance.tabBarHeight, 36)
    }
}
