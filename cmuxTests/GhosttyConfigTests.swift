import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyConfigTests: XCTestCase {
    private struct RGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    func testResolveThemeNamePrefersLightEntryForPairedTheme() {
        let resolved = GhosttyConfig.resolveThemeName(
            from: "light:Builtin Solarized Light,dark:Builtin Solarized Dark",
            preferredColorScheme: .light
        )

        XCTAssertEqual(resolved, "Builtin Solarized Light")
    }

    func testResolveThemeNamePrefersDarkEntryForPairedTheme() {
        let resolved = GhosttyConfig.resolveThemeName(
            from: "light:Builtin Solarized Light,dark:Builtin Solarized Dark",
            preferredColorScheme: .dark
        )

        XCTAssertEqual(resolved, "Builtin Solarized Dark")
    }

    func testThemeNameCandidatesIncludeBuiltinAliasForms() {
        let candidates = GhosttyConfig.themeNameCandidates(from: "Builtin Solarized Light")
        XCTAssertEqual(candidates.first, "Builtin Solarized Light")
        XCTAssertTrue(candidates.contains("Solarized Light"))
        XCTAssertTrue(candidates.contains("iTerm2 Solarized Light"))
    }

    func testThemeNameCandidatesMapSolarizedDarkToITerm2Alias() {
        let candidates = GhosttyConfig.themeNameCandidates(from: "Builtin Solarized Dark")
        XCTAssertTrue(candidates.contains("Solarized Dark"))
        XCTAssertTrue(candidates.contains("iTerm2 Solarized Dark"))
    }

    func testThemeSearchPathsIncludeXDGDataDirsThemes() {
        let pathA = "/tmp/cmux-theme-a"
        let pathB = "/tmp/cmux-theme-b"
        let paths = GhosttyConfig.themeSearchPaths(
            forThemeName: "Solarized Light",
            environment: ["XDG_DATA_DIRS": "\(pathA):\(pathB)"],
            bundleResourceURL: nil
        )

        XCTAssertTrue(paths.contains("\(pathA)/ghostty/themes/Solarized Light"))
        XCTAssertTrue(paths.contains("\(pathB)/ghostty/themes/Solarized Light"))
    }

    func testLoadThemeResolvesPairedThemeValueByColorScheme() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-theme-pair-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        background = #fdf6e3
        foreground = #657b83
        """.write(
            to: themesDir.appendingPathComponent("Light Theme"),
            atomically: true,
            encoding: .utf8
        )

        try """
        background = #002b36
        foreground = #93a1a1
        """.write(
            to: themesDir.appendingPathComponent("Dark Theme"),
            atomically: true,
            encoding: .utf8
        )

        var lightConfig = GhosttyConfig()
        lightConfig.loadTheme(
            "light:Light Theme,dark:Dark Theme",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil,
            preferredColorScheme: .light
        )
        XCTAssertEqual(rgb255(lightConfig.backgroundColor), RGB(red: 253, green: 246, blue: 227))

        var darkConfig = GhosttyConfig()
        darkConfig.loadTheme(
            "light:Light Theme,dark:Dark Theme",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil,
            preferredColorScheme: .dark
        )
        XCTAssertEqual(rgb255(darkConfig.backgroundColor), RGB(red: 0, green: 43, blue: 54))
    }

    func testLoadThemeResolvesBuiltinAliasFromGhosttyResourcesDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-themes-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let themePath = themesDir.appendingPathComponent("Solarized Light")
        let themeContents = """
        background = #fdf6e3
        foreground = #657b83
        """
        try themeContents.write(to: themePath, atomically: true, encoding: .utf8)

        var config = GhosttyConfig()
        config.loadTheme(
            "Builtin Solarized Light",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil
        )

        XCTAssertEqual(rgb255(config.backgroundColor), RGB(red: 253, green: 246, blue: 227))
    }

    func testLegacyConfigFallbackUsesLegacyFileWhenConfigGhosttyIsEmpty() {
        XCTAssertTrue(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 0,
                legacyConfigFileSize: 42
            )
        )
    }

    func testLegacyConfigFallbackSkipsWhenNewFileMissingOrLegacyEmpty() {
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: nil,
                legacyConfigFileSize: 42
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 10,
                legacyConfigFileSize: 42
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 0,
                legacyConfigFileSize: 0
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 0,
                legacyConfigFileSize: nil
            )
        )
    }

    func testClaudeCodeIntegrationDefaultsToDisabledWhenUnset() {
        let suiteName = "cmux.tests.claude-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertFalse(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))
    }

    func testClaudeCodeIntegrationRespectsStoredPreference() {
        let suiteName = "cmux.tests.claude-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertTrue(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))

        defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertFalse(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))
    }

    private func rgb255(_ color: NSColor) -> RGB {
        let srgb = color.usingColorSpace(.sRGB)!
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(
            red: Int(round(red * 255)),
            green: Int(round(green * 255)),
            blue: Int(round(blue * 255))
        )
    }
}
