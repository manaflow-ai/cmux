import XCTest
import AppKit
import WebKit
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarPathFormatterTests: XCTestCase {
    func testShortenedPathReplacesExactHomeDirectory() {
        XCTAssertEqual(
            SidebarPathFormatter.shortenedPath(
                "/Users/example",
                homeDirectoryPath: "/Users/example"
            ),
            "~"
        )
    }

    func testShortenedPathReplacesHomeDirectoryPrefix() {
        XCTAssertEqual(
            SidebarPathFormatter.shortenedPath(
                "/Users/example/projects/cmux",
                homeDirectoryPath: "/Users/example"
            ),
            "~/projects/cmux"
        )
    }

    func testShortenedPathLeavesExternalPathUnchanged() {
        XCTAssertEqual(
            SidebarPathFormatter.shortenedPath(
                "/tmp/cmux",
                homeDirectoryPath: "/Users/example"
            ),
            "/tmp/cmux"
        )
    }
}

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

    func testLoadReadsSymlinkedGhosttyConfigFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-config-symlink-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let originalFixedHome = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        setenv("CFFIXED_USER_HOME", root.path, 1)
        defer {
            if let originalFixedHome {
                setenv("CFFIXED_USER_HOME", originalFixedHome, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
            GhosttyConfig.invalidateLoadCache()
        }

        let ghosttyConfigDir = root.appendingPathComponent(".config/ghostty", isDirectory: true)
        try fileManager.createDirectory(at: ghosttyConfigDir, withIntermediateDirectories: true)

        let dotfilesDir = root.appendingPathComponent("dotfiles/ghostty", isDirectory: true)
        try fileManager.createDirectory(at: dotfilesDir, withIntermediateDirectories: true)

        let targetConfig = dotfilesDir.appendingPathComponent("config", isDirectory: false)
        try "font-size = 15\n".write(to: targetConfig, atomically: true, encoding: .utf8)

        let symlinkedConfig = ghosttyConfigDir.appendingPathComponent("config", isDirectory: false)
        try fileManager.createSymbolicLink(
            atPath: symlinkedConfig.path,
            withDestinationPath: targetConfig.path
        )

        let loaded = GhosttyConfig.load(preferredColorScheme: .dark, useCache: false)

        XCTAssertEqual(loaded.fontSize, CGFloat(15), accuracy: 0.0001)
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

    func testParseBackgroundOpacityReadsConfigValue() {
        var config = GhosttyConfig()
        config.parse("background-opacity = 0.42")
        XCTAssertEqual(config.backgroundOpacity, 0.42, accuracy: 0.0001)
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

    func testLoadThemeResolvesITerm2SolarizedLightAliasToLegacyThemeName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-solarized-light-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        background = #fdf6e3
        foreground = #657b83
        """.write(
            to: themesDir.appendingPathComponent("Solarized Light"),
            atomically: true,
            encoding: .utf8
        )

        var config = GhosttyConfig()
        config.loadTheme(
            "iTerm2 Solarized Light",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil
        )

        XCTAssertEqual(rgb255(config.backgroundColor), RGB(red: 253, green: 246, blue: 227))
    }

    func testLoadThemeResolvesITerm2SolarizedDarkAliasToLegacyThemeName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-solarized-dark-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        background = #002b36
        foreground = #93a1a1
        """.write(
            to: themesDir.appendingPathComponent("Solarized Dark"),
            atomically: true,
            encoding: .utf8
        )

        var config = GhosttyConfig()
        config.loadTheme(
            "iTerm2 Solarized Dark",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil
        )

        XCTAssertEqual(rgb255(config.backgroundColor), RGB(red: 0, green: 43, blue: 54))
    }

    func testLoadCachesPerColorScheme() {
        GhosttyConfig.invalidateLoadCache()
        defer { GhosttyConfig.invalidateLoadCache() }

        var loadCount = 0
        let loadFromDisk: (GhosttyConfig.ColorSchemePreference) -> GhosttyConfig = { scheme in
            loadCount += 1
            var config = GhosttyConfig()
            config.fontFamily = "\(scheme)-\(loadCount)"
            return config
        }

        let lightFirst = GhosttyConfig.load(
            preferredColorScheme: .light,
            loadFromDisk: loadFromDisk
        )
        let lightSecond = GhosttyConfig.load(
            preferredColorScheme: .light,
            loadFromDisk: loadFromDisk
        )
        let darkFirst = GhosttyConfig.load(
            preferredColorScheme: .dark,
            loadFromDisk: loadFromDisk
        )

        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(lightFirst.fontFamily, "light-1")
        XCTAssertEqual(lightSecond.fontFamily, "light-1")
        XCTAssertEqual(darkFirst.fontFamily, "dark-2")
    }

    func testLoadCacheInvalidationForcesReload() {
        GhosttyConfig.invalidateLoadCache()
        defer { GhosttyConfig.invalidateLoadCache() }

        var loadCount = 0
        let loadFromDisk: (GhosttyConfig.ColorSchemePreference) -> GhosttyConfig = { _ in
            loadCount += 1
            var config = GhosttyConfig()
            config.fontFamily = "reload-\(loadCount)"
            return config
        }

        let first = GhosttyConfig.load(
            preferredColorScheme: .dark,
            loadFromDisk: loadFromDisk
        )
        GhosttyConfig.invalidateLoadCache()
        let second = GhosttyConfig.load(
            preferredColorScheme: .dark,
            loadFromDisk: loadFromDisk
        )

        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(first.fontFamily, "reload-1")
        XCTAssertEqual(second.fontFamily, "reload-2")
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

    func testCmuxAppSupportConfigURLsUseReleaseConfigForDebugBundleWithoutCurrentConfig() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let releaseConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config",
                contents: "font-size = 13\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.debug",
                    appSupportDirectory: appSupportDirectory
                ),
                [releaseConfigURL]
            )
        }
    }

    func testCmuxAppSupportConfigURLsPreferCurrentBundleConfigWhenPresent() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config",
                contents: "font-size = 13\n"
            )
            let currentConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app.debug.issue-829",
                filename: "config.ghostty",
                contents: "font-size = 14\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.debug.issue-829",
                    appSupportDirectory: appSupportDirectory
                ),
                [currentConfigURL]
            )
        }
    }

    func testCmuxAppSupportConfigURLsSkipReleaseFallbackForNonDebugBundle() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config",
                contents: "font-size = 13\n"
            )

            XCTAssertTrue(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.example.other-app",
                    appSupportDirectory: appSupportDirectory
                ).isEmpty
            )
        }
    }

    func testCmuxAppSupportConfigURLsIgnoreMissingOrEmptyFiles() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: ""
            )

            XCTAssertTrue(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.debug",
                    appSupportDirectory: appSupportDirectory
                ).isEmpty
            )
        }
    }

    func testDefaultBackgroundUpdateScopePrioritizesSurfaceOverAppAndUnscoped() {
        XCTAssertTrue(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .unscoped,
                incomingScope: .app
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .app,
                incomingScope: .surface
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .surface,
                incomingScope: .surface
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .surface,
                incomingScope: .app
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .surface,
                incomingScope: .unscoped
            )
        )
    }

    func testAppearanceChangeReloadsWhenColorSchemeChanges() {
        XCTAssertTrue(
            GhosttyApp.shouldReloadConfigurationForAppearanceChange(
                previousColorScheme: .dark,
                currentColorScheme: .light
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldReloadConfigurationForAppearanceChange(
                previousColorScheme: nil,
                currentColorScheme: .dark
            )
        )
    }

    func testAppearanceChangeSkipsReloadWhenColorSchemeUnchanged() {
        XCTAssertFalse(
            GhosttyApp.shouldReloadConfigurationForAppearanceChange(
                previousColorScheme: .light,
                currentColorScheme: .light
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldReloadConfigurationForAppearanceChange(
                previousColorScheme: .dark,
                currentColorScheme: .dark
            )
        )
    }

    func testScrollLagCaptureRequiresSustainedLag() {
        XCTAssertFalse(
            GhosttyApp.shouldCaptureScrollLagEvent(
                samples: 4,
                averageMs: 18,
                maxMs: 85,
                thresholdMs: 40,
                nowUptime: 1000,
                lastReportedUptime: nil
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldCaptureScrollLagEvent(
                samples: 10,
                averageMs: 6,
                maxMs: 85,
                thresholdMs: 40,
                nowUptime: 1000,
                lastReportedUptime: nil
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldCaptureScrollLagEvent(
                samples: 10,
                averageMs: 18,
                maxMs: 35,
                thresholdMs: 40,
                nowUptime: 1000,
                lastReportedUptime: nil
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldCaptureScrollLagEvent(
                samples: 10,
                averageMs: 18,
                maxMs: 85,
                thresholdMs: 40,
                nowUptime: 1000,
                lastReportedUptime: nil
            )
        )
    }

    func testScrollLagCaptureRespectsCooldownWindow() {
        XCTAssertFalse(
            GhosttyApp.shouldCaptureScrollLagEvent(
                samples: 12,
                averageMs: 22,
                maxMs: 90,
                thresholdMs: 40,
                nowUptime: 1200,
                lastReportedUptime: 1005,
                cooldown: 300
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldCaptureScrollLagEvent(
                samples: 12,
                averageMs: 22,
                maxMs: 90,
                thresholdMs: 40,
                nowUptime: 1406,
                lastReportedUptime: 1005,
                cooldown: 300
            )
        )
    }

    func testClaudeCodeIntegrationDefaultsToEnabledWhenUnset() {
        let suiteName = "cmux.tests.claude-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertTrue(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))
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

    func testTelemetryDefaultsToEnabledWhenUnset() {
        let suiteName = "cmux.tests.telemetry.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: TelemetrySettings.sendAnonymousTelemetryKey)
        XCTAssertTrue(TelemetrySettings.isEnabled(defaults: defaults))
    }

    func testTelemetryRespectsStoredPreference() {
        let suiteName = "cmux.tests.telemetry.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: TelemetrySettings.sendAnonymousTelemetryKey)
        XCTAssertTrue(TelemetrySettings.isEnabled(defaults: defaults))

        defaults.set(false, forKey: TelemetrySettings.sendAnonymousTelemetryKey)
        XCTAssertFalse(TelemetrySettings.isEnabled(defaults: defaults))
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

    private func withTemporaryAppSupportDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-app-support-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try body(directory)
    }

    private func writeAppSupportConfig(
        appSupportDirectory: URL,
        bundleIdentifier: String,
        filename: String,
        contents: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let bundleDirectory = appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        let configURL = bundleDirectory.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }
}

final class WorkspaceChromeThemeTests: XCTestCase {
    func testResolvedChromeColorsUsesLightGhosttyBackground() {
        guard let backgroundColor = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(from: backgroundColor)
        XCTAssertEqual(colors.backgroundHex, "#FDF6E3")
        XCTAssertNil(colors.borderHex)
    }

    func testResolvedChromeColorsUsesDarkGhosttyBackground() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(from: backgroundColor)
        XCTAssertEqual(colors.backgroundHex, "#272822")
        XCTAssertNil(colors.borderHex)
    }
}

final class WorkspaceAppearanceConfigResolutionTests: XCTestCase {
    func testResolvedAppearanceConfigPrefersGhosttyRuntimeBackgroundOverLoadedConfig() {
        guard let loadedBackground = NSColor(hex: "#112233"),
              let runtimeBackground = NSColor(hex: "#FDF6E3"),
              let loadedForeground = NSColor(hex: "#ABCDEF") else {
            XCTFail("Expected valid test colors")
            return
        }

        var loaded = GhosttyConfig()
        loaded.backgroundColor = loadedBackground
        loaded.foregroundColor = loadedForeground
        loaded.unfocusedSplitOpacity = 0.42

        let resolved = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            loadConfig: { loaded },
            defaultBackground: { runtimeBackground }
        )

        XCTAssertEqual(resolved.backgroundColor.hexString(), "#FDF6E3")
        XCTAssertEqual(resolved.foregroundColor.hexString(), "#ABCDEF")
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
}

@MainActor
final class WorkspaceChromeColorTests: XCTestCase {
    func testBonsplitChromeHexIncludesAlphaWhenTranslucent() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let hex = Workspace.bonsplitChromeHex(backgroundColor: color, backgroundOpacity: 0.5)
        XCTAssertEqual(hex, "#1122337F")
    }

    func testBonsplitChromeHexOmitsAlphaWhenOpaque() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let hex = Workspace.bonsplitChromeHex(backgroundColor: color, backgroundOpacity: 1.0)
        XCTAssertEqual(hex, "#112233")
    }
}

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

final class WorkspaceRemoteDaemonManifestTests: XCTestCase {
    func testParsesEmbeddedRemoteDaemonManifestJSON() throws {
        let manifestJSON = """
        {
          "schemaVersion": 1,
          "appVersion": "0.62.0",
          "releaseTag": "v0.62.0",
          "releaseURL": "https://github.com/manaflow-ai/cmux/releases/tag/v0.62.0",
          "checksumsAssetName": "cmuxd-remote-checksums.txt",
          "checksumsURL": "https://github.com/manaflow-ai/cmux/releases/download/v0.62.0/cmuxd-remote-checksums.txt",
          "entries": [
            {
              "goOS": "linux",
              "goArch": "amd64",
              "assetName": "cmuxd-remote-linux-amd64",
              "downloadURL": "https://github.com/manaflow-ai/cmux/releases/download/v0.62.0/cmuxd-remote-linux-amd64",
              "sha256": "abc123"
            }
          ]
        }
        """

        let manifest = Workspace.remoteDaemonManifest(from: [
            Workspace.remoteDaemonManifestInfoKey: manifestJSON,
        ])

        XCTAssertEqual(manifest?.releaseTag, "v0.62.0")
        XCTAssertEqual(manifest?.entry(goOS: "linux", goArch: "amd64")?.assetName, "cmuxd-remote-linux-amd64")
    }

    func testRemoteDaemonCachePathIsVersionedByPlatform() throws {
        let url = try Workspace.remoteDaemonCachedBinaryURL(
            version: "0.62.0",
            goOS: "linux",
            goArch: "arm64"
        )

        XCTAssertTrue(url.path.contains("/Application Support/cmux/remote-daemons/0.62.0/linux-arm64/"))
        XCTAssertEqual(url.lastPathComponent, "cmuxd-remote")
    }
}

final class RemoteLoopbackHTTPRequestRewriterTests: XCTestCase {
    func testRewritesLoopbackAliasHostHeadersToLocalhost() {
        let original = Data(
            (
                "GET /demo HTTP/1.1\r\n" +
                "Host: cmux-loopback.localtest.me:3000\r\n" +
                "Origin: http://cmux-loopback.localtest.me:3000\r\n" +
                "Referer: http://cmux-loopback.localtest.me:3000/app\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Host: localhost:3000"))
        XCTAssertTrue(text.contains("Origin: http://localhost:3000"))
        XCTAssertTrue(text.contains("Referer: http://localhost:3000/app"))
        XCTAssertFalse(text.contains("cmux-loopback.localtest.me"))
    }

    func testRewritesAbsoluteFormRequestLineForLoopbackAlias() {
        let original = Data(
            (
                "GET http://cmux-loopback.localtest.me:3000/demo HTTP/1.1\r\n" +
                "Host: cmux-loopback.localtest.me:3000\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET http://localhost:3000/demo HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: localhost:3000"))
    }

    func testLeavesNonHTTPPayloadUntouched() {
        let original = Data([0x16, 0x03, 0x01, 0x00, 0x2a, 0x01, 0x00])
        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )
        XCTAssertEqual(rewritten, original)
    }

    func testBuffersSplitLoopbackAliasHeadersUntilFullRequestArrives() {
        var streamRewriter = RemoteLoopbackHTTPRequestStreamRewriter(
            aliasHost: "cmux-loopback.localtest.me"
        )

        let firstChunk = Data(
            (
                "GET /demo HTTP/1.1\r\n" +
                "Host: cmux-loop"
            ).utf8
        )
        let secondChunk = Data(
            (
                "back.localtest.me:3000\r\n" +
                "Origin: http://cmux-loopback.localtest.me:3000\r\n" +
                "Referer: http://cmux-loopback.localtest.me:3000/app\r\n" +
                "\r\n" +
                "body=1"
            ).utf8
        )

        let firstOutput = streamRewriter.rewriteNextChunk(firstChunk, eof: false)
        let secondOutput = streamRewriter.rewriteNextChunk(secondChunk, eof: false)

        XCTAssertTrue(firstOutput.isEmpty)

        let text = String(decoding: secondOutput, as: UTF8.self)
        XCTAssertTrue(text.contains("Host: localhost:3000"))
        XCTAssertTrue(text.contains("Origin: http://localhost:3000"))
        XCTAssertTrue(text.contains("Referer: http://localhost:3000/app"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nbody=1"))
        XCTAssertFalse(text.contains("cmux-loopback.localtest.me"))
    }

    func testFlushesBufferedLoopbackAliasHeadersOnEOFWhenHeadersRemainIncomplete() {
        var streamRewriter = RemoteLoopbackHTTPRequestStreamRewriter(
            aliasHost: "cmux-loopback.localtest.me"
        )

        let firstChunk = Data(
            (
                "GET /demo HTTP/1.1\r\n" +
                "Host: cmux-loop"
            ).utf8
        )
        let secondChunk = Data(
            (
                "back.localtest.me:3000\r\n" +
                "Origin: http://cmux-loopback.localtest.me:3000\r\n" +
                "Referer: http://cmux-loopback.localtest.me:3000/app\r\n" +
                "body=1"
            ).utf8
        )

        let firstOutput = streamRewriter.rewriteNextChunk(firstChunk, eof: false)
        let secondOutput = streamRewriter.rewriteNextChunk(secondChunk, eof: true)
        let thirdOutput = streamRewriter.rewriteNextChunk(Data(), eof: true)

        XCTAssertTrue(firstOutput.isEmpty)

        let text = String(decoding: secondOutput, as: UTF8.self)
        XCTAssertTrue(text.contains("Host: localhost:3000"))
        XCTAssertTrue(text.contains("Origin: http://localhost:3000"))
        XCTAssertTrue(text.contains("Referer: http://localhost:3000/app"))
        XCTAssertTrue(text.hasSuffix("\r\nbody=1"))
        XCTAssertFalse(text.contains("cmux-loopback.localtest.me"))
        XCTAssertTrue(thirdOutput.isEmpty)
    }

    func testRewritesLoopbackResponseHeadersBackToAlias() {
        let original = Data(
            (
                "HTTP/1.1 302 Found\r\n" +
                "Location: http://localhost:3000/login\r\n" +
                "Access-Control-Allow-Origin: http://localhost:3000\r\n" +
                "Set-Cookie: sid=1; Domain=localhost; Path=/\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Location: http://cmux-loopback.localtest.me:3000/login"))
        XCTAssertTrue(text.contains("Access-Control-Allow-Origin: http://cmux-loopback.localtest.me:3000"))
        XCTAssertTrue(text.contains("Set-Cookie: sid=1; Domain=cmux-loopback.localtest.me; Path=/"))
    }
}

final class GhosttyTerminalStartupEnvironmentTests: XCTestCase {
    func testApplyManagedTerminalIdentityEnvironmentOverridesInheritedValues() {
        var environment = [
            "TERM": "xterm-ghostty",
            "COLORTERM": "24bit",
            "TERM_PROGRAM": "Apple_Terminal",
            "CUSTOM_FLAG": "1"
        ]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedTerminalIdentityEnvironment(
            to: &environment,
            protectedKeys: &protectedKeys
        )

        XCTAssertEqual(environment["TERM"], TerminalSurface.managedTerminalType)
        XCTAssertEqual(environment["COLORTERM"], TerminalSurface.managedColorTerm)
        XCTAssertEqual(environment["TERM_PROGRAM"], TerminalSurface.managedTerminalProgram)
        XCTAssertEqual(environment["CUSTOM_FLAG"], "1")
        XCTAssertTrue(protectedKeys.contains("TERM"))
        XCTAssertTrue(protectedKeys.contains("COLORTERM"))
        XCTAssertTrue(protectedKeys.contains("TERM_PROGRAM"))
    }

    func testMergedStartupEnvironmentAllowsSessionReplayAndInitialEnvCMUXKeys() {
        let replayPath = "/tmp/cmux-replay-\(UUID().uuidString)"
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "PATH": "/usr/bin",
                "CMUX_SURFACE_ID": "managed-surface"
            ],
            protectedKeys: ["PATH", "CMUX_SURFACE_ID"],
            additionalEnvironment: [
                SessionScrollbackReplayStore.environmentKey: replayPath
            ],
            initialEnvironmentOverrides: [
                "CMUX_INITIAL_ENV_TOKEN": "token-123"
            ]
        )

        XCTAssertEqual(merged[SessionScrollbackReplayStore.environmentKey], replayPath)
        XCTAssertEqual(merged["CMUX_INITIAL_ENV_TOKEN"], "token-123")
    }

    func testMergedStartupEnvironmentProtectsManagedKeysOnly() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "PATH": "/usr/bin",
                "CMUX_SURFACE_ID": "managed-surface"
            ],
            protectedKeys: ["PATH", "CMUX_SURFACE_ID"],
            additionalEnvironment: [
                "CMUX_SURFACE_ID": "user-surface",
                "CUSTOM_FLAG": "1"
            ],
            initialEnvironmentOverrides: [
                "PATH": "/tmp/bin",
                "CMUX_SURFACE_ID": "override-surface"
            ]
        )

        XCTAssertEqual(merged["PATH"], "/usr/bin")
        XCTAssertEqual(merged["CMUX_SURFACE_ID"], "managed-surface")
        XCTAssertEqual(merged["CUSTOM_FLAG"], "1")
    }

    func testMergedStartupEnvironmentProtectsManagedTerminalIdentity() {
        var baseEnvironment = [
            "PATH": "/usr/bin"
        ]
        var protectedKeys: Set<String> = ["PATH"]
        TerminalSurface.applyManagedTerminalIdentityEnvironment(
            to: &baseEnvironment,
            protectedKeys: &protectedKeys
        )

        let merged = TerminalSurface.mergedStartupEnvironment(
            base: baseEnvironment,
            protectedKeys: protectedKeys,
            additionalEnvironment: [
                "TERM": "xterm-ghostty",
                "COLORTERM": "24bit",
                "TERM_PROGRAM": "Apple_Terminal"
            ],
            initialEnvironmentOverrides: [
                "TERM": "screen-256color",
                "COLORTERM": "false",
                "TERM_PROGRAM": "WarpTerminal"
            ]
        )

        XCTAssertEqual(merged["TERM"], TerminalSurface.managedTerminalType)
        XCTAssertEqual(merged["COLORTERM"], TerminalSurface.managedColorTerm)
        XCTAssertEqual(merged["TERM_PROGRAM"], TerminalSurface.managedTerminalProgram)
    }
}

@MainActor
final class BrowserPanelPopupContextTests: XCTestCase {
    func testFloatingPopupInheritsOpenerBrowserContext() throws {
        let panel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        let popupWebView = try XCTUnwrap(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        XCTAssertTrue(
            popupWebView.configuration.processPool === panel.webView.configuration.processPool
        )
        XCTAssertTrue(
            popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore
        )
    }

    func testFloatingPopupInheritsRemoteWorkspaceWebsiteDataStore() throws {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        let popupWebView = try XCTUnwrap(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        XCTAssertTrue(
            popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore
        )
        XCTAssertFalse(popupWebView.configuration.websiteDataStore === WKWebsiteDataStore.default())
    }
}

@MainActor
final class BrowserPanelRemoteStoreTests: XCTestCase {
    func testRemoteWorkspacePanelsShareWorkspaceScopedWebsiteDataStore() {
        let localPanel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        let remoteWorkspaceId = UUID()
        let firstRemotePanel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        let secondRemotePanel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )

        XCTAssertTrue(localPanel.webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertFalse(firstRemotePanel.webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(
            firstRemotePanel.webView.configuration.websiteDataStore ===
                secondRemotePanel.webView.configuration.websiteDataStore
        )
    }

    func testRemoteWorkspaceDefersInitialNavigationUntilProxyEndpointIsReady() {
        let remoteWorkspaceId = UUID()
        let url = URL(string: "http://localhost:3000/demo")!
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            initialURL: url,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertNil(panel.webView.url)

        panel.setRemoteProxyEndpoint(BrowserProxyEndpoint(host: "127.0.0.1", port: 9876))

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.url == nil, RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertEqual(panel.webView.url?.host, "cmux-loopback.localtest.me")
    }

    func testRemoteWorkspaceKeepsHTTPSLoopbackUnaliased() {
        let remoteWorkspaceId = UUID()
        let url = URL(string: "https://localhost:3443/demo")!
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            initialURL: url,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertNil(panel.webView.url)

        panel.setRemoteProxyEndpoint(BrowserProxyEndpoint(host: "127.0.0.1", port: 9876))

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.url == nil, RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertEqual(panel.webView.url?.host, "localhost")
    }

    func testBrowserMoveIntoRemoteWorkspaceRebuildsWebsiteDataStoreScope() throws {
        let source = Workspace()
        let sourcePaneId = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let sourceBrowser = try XCTUnwrap(source.newBrowserSurface(inPane: sourcePaneId, focus: false))
        let localStore = sourceBrowser.webView.configuration.websiteDataStore
        XCTAssertTrue(localStore === WKWebsiteDataStore.default())

        let destination = Workspace()
        destination.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: 22,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64001,
                relayID: "relay-store-dest",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-store-dest.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let destinationPaneId = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let destinationBrowser = try XCTUnwrap(destination.newBrowserSurface(inPane: destinationPaneId, focus: false))
        let destinationStore = destinationBrowser.webView.configuration.websiteDataStore
        XCTAssertFalse(destinationStore === WKWebsiteDataStore.default())

        let detached = try XCTUnwrap(source.detachSurface(panelId: sourceBrowser.id))
        let attachedPanelId = try XCTUnwrap(
            destination.attachDetachedSurface(detached, inPane: destinationPaneId, focus: false)
        )
        let movedBrowser = try XCTUnwrap(destination.panels[attachedPanelId] as? BrowserPanel)

        XCTAssertTrue(movedBrowser.webView.configuration.websiteDataStore === destinationStore)
        XCTAssertFalse(movedBrowser.webView.configuration.websiteDataStore === localStore)
    }

    func testBrowserMoveOutOfRemoteWorkspaceRestoresDefaultWebsiteDataStore() throws {
        let source = Workspace()
        source.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: 22,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64002,
                relayID: "relay-store-source",
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-store-source.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let sourcePaneId = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let movedBrowser = try XCTUnwrap(source.newBrowserSurface(inPane: sourcePaneId, focus: false))
        let remainingRemoteBrowser = try XCTUnwrap(source.newBrowserSurface(inPane: sourcePaneId, focus: false))
        let remoteStore = remainingRemoteBrowser.webView.configuration.websiteDataStore
        XCTAssertFalse(remoteStore === WKWebsiteDataStore.default())

        let destination = Workspace()
        let destinationPaneId = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let detached = try XCTUnwrap(source.detachSurface(panelId: movedBrowser.id))
        let attachedPanelId = try XCTUnwrap(
            destination.attachDetachedSurface(detached, inPane: destinationPaneId, focus: false)
        )
        let attachedBrowser = try XCTUnwrap(destination.panels[attachedPanelId] as? BrowserPanel)

        XCTAssertTrue(attachedBrowser.webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(remainingRemoteBrowser.webView.configuration.websiteDataStore === remoteStore)
        XCTAssertFalse(remainingRemoteBrowser.webView.configuration.websiteDataStore === attachedBrowser.webView.configuration.websiteDataStore)
    }

    func testNewTerminalSurfaceStaysRemoteWhileBrowserPanelsKeepWorkspaceRemote() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let initialTerminalId = try XCTUnwrap(workspace.focusedPanelId)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64000,
            relayID: "relay-test",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(configuration, autoConnect: false)
        _ = workspace.newBrowserSurface(inPane: paneId, url: URL(string: "https://example.com"), focus: false)

        workspace.markRemoteTerminalSessionEnded(surfaceId: initialTerminalId, relayPort: configuration.relayPort)

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)

        _ = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
    }
}

final class WorkspaceRemoteConfigurationTransportKeyTests: XCTestCase {
    func testProxyBrokerTransportKeyIgnoresControlPath() {
        let first = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "Compression=yes",
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-64000-%C",
            ],
            localProxyPort: 9000,
            relayPort: 64000,
            relayID: "relay-a",
            relayToken: "token-a",
            localSocketPath: "/tmp/cmux-a.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let second = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "Compression=yes",
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-64001-%C",
            ],
            localProxyPort: 9000,
            relayPort: 64001,
            relayID: "relay-b",
            relayToken: "token-b",
            localSocketPath: "/tmp/cmux-b.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        XCTAssertEqual(first.proxyBrokerTransportKey, second.proxyBrokerTransportKey)
    }
}

final class WorkspaceRemoteSSHCleanupTests: XCTestCase {
    func testOrphanedCMUXRemoteSSHPIDsMatchesOnlyParentOneRelayAndDaemonTransports() {
        let psOutput = """
          101 1 /usr/bin/ssh -N -T -S none -o ControlPath=/tmp/cmux-ssh-501-56080-%C -R 127.0.0.1:56080:127.0.0.1:64048 cmux-macmini
          102 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
          103 999 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56081:127.0.0.1:64049 cmux-macmini
          104 1 /usr/bin/ssh -tt cmux-macmini
          105 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56082:127.0.0.1:64050 other-host
          106 1 /usr/bin/ssh -T -S none cmux-macmini /bin/sh
        """

        XCTAssertEqual(
            WorkspaceRemoteSessionController.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini"
            ),
            [101, 102]
        )
    }

    func testOrphanedCMUXRemoteSSHPIDsCanRestrictCleanupToSpecificRelayPort() {
        let psOutput = """
          201 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56080:127.0.0.1:64048 cmux-macmini
          202 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56081:127.0.0.1:64049 cmux-macmini
          203 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
        """

        XCTAssertEqual(
            WorkspaceRemoteSessionController.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                relayPort: 56081
            ),
            [202]
        )
    }
}

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

final class WorkspaceRemoteDaemonPendingCallRegistryTests: XCTestCase {
    func testSupportsMultiplePendingCallsResolvedOutOfOrder() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()
        let first = registry.register()
        let second = registry.register()

        XCTAssertTrue(registry.resolve(id: second.id, payload: [
            "ok": true,
            "result": ["stream_id": "second"],
        ]))

        switch registry.wait(for: second, timeout: 0.1) {
        case .response(let response):
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual((response["result"] as? [String: String])?["stream_id"], "second")
        default:
            XCTFail("second pending call should complete independently")
        }

        XCTAssertTrue(registry.resolve(id: first.id, payload: [
            "ok": true,
            "result": ["stream_id": "first"],
        ]))

        switch registry.wait(for: first, timeout: 0.1) {
        case .response(let response):
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual((response["result"] as? [String: String])?["stream_id"], "first")
        default:
            XCTFail("first pending call should remain pending until its own response arrives")
        }
    }

    func testFailAllSignalsEveryPendingCall() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()
        let first = registry.register()
        let second = registry.register()

        registry.failAll("daemon transport stopped")

        switch registry.wait(for: first, timeout: 0.1) {
        case .failure(let message):
            XCTAssertEqual(message, "daemon transport stopped")
        default:
            XCTFail("first pending call should receive shared failure")
        }

        switch registry.wait(for: second, timeout: 0.1) {
        case .failure(let message):
            XCTAssertEqual(message, "daemon transport stopped")
        default:
            XCTFail("second pending call should receive shared failure")
        }
    }
}

final class WindowBackgroundSelectionGateTests: XCTestCase {
    func testShouldApplyWindowBackgroundUsesOwningWindowSelectionWhenAvailable() {
        let tabId = UUID()
        let activeSelectedTabId = UUID()

        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: true,
                owningSelectedTabId: tabId,
                activeSelectedTabId: activeSelectedTabId
            )
        )
    }

    func testShouldApplyWindowBackgroundRejectsWhenOwningSelectionDiffers() {
        let tabId = UUID()

        XCTAssertFalse(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: true,
                owningSelectedTabId: UUID(),
                activeSelectedTabId: tabId
            )
        )
    }

    func testShouldApplyWindowBackgroundAllowsWhenOwningManagerSelectionIsTemporarilyNil() {
        let tabId = UUID()

        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: true,
                owningSelectedTabId: nil,
                activeSelectedTabId: UUID()
            )
        )
    }

    func testShouldApplyWindowBackgroundFallsBackToActiveSelection() {
        let tabId = UUID()

        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: tabId
            )
        )
        XCTAssertFalse(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: UUID()
            )
        )
    }

    func testShouldApplyWindowBackgroundAllowsWhenNoSelectionContext() {
        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: UUID(),
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: nil
            )
        )
        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: nil,
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: nil
            )
        )
        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: nil,
                owningManagerExists: true,
                owningSelectedTabId: UUID(),
                activeSelectedTabId: UUID()
            )
        )
    }
}

final class NotificationBurstCoalescerTests: XCTestCase {
    func testSignalsInSameBurstFlushOnce() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "flush once")
        expectation.expectedFulfillmentCount = 1
        var flushCount = 0

        DispatchQueue.main.async {
            for _ in 0..<8 {
                coalescer.signal {
                    flushCount += 1
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(flushCount, 1)
    }

    func testLatestActionWinsWithinBurst() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "latest action flushed")
        var value = 0

        DispatchQueue.main.async {
            coalescer.signal {
                value = 1
            }
            coalescer.signal {
                value = 2
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(value, 2)
    }

    func testSignalsAcrossBurstsFlushMultipleTimes() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "flush twice")
        expectation.expectedFulfillmentCount = 2
        var flushCount = 0

        DispatchQueue.main.async {
            coalescer.signal {
                flushCount += 1
                expectation.fulfill()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                coalescer.signal {
                    flushCount += 1
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(flushCount, 2)
    }
}

final class GhosttyDefaultBackgroundNotificationDispatcherTests: XCTestCase {
    func testSignalCoalescesBurstToLatestBackground() {
        guard let dark = NSColor(hex: "#272822"),
              let light = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test colors")
            return
        }

        let expectation = expectation(description: "coalesced notification")
        expectation.expectedFulfillmentCount = 1
        var postedUserInfos: [[AnyHashable: Any]] = []

        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0.01,
            postNotification: { userInfo in
                postedUserInfos.append(userInfo)
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            dispatcher.signal(backgroundColor: dark, opacity: 0.95, eventId: 1, source: "test.dark")
            dispatcher.signal(backgroundColor: light, opacity: 0.75, eventId: 2, source: "test.light")
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(postedUserInfos.count, 1)
        XCTAssertEqual(
            (postedUserInfos[0][GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString(),
            "#FDF6E3"
        )
        XCTAssertEqual(
            postedOpacity(from: postedUserInfos[0][GhosttyNotificationKey.backgroundOpacity]),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            (postedUserInfos[0][GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value,
            2
        )
        XCTAssertEqual(
            postedUserInfos[0][GhosttyNotificationKey.backgroundSource] as? String,
            "test.light"
        )
    }

    func testSignalAcrossSeparateBurstsPostsMultipleNotifications() {
        guard let dark = NSColor(hex: "#272822"),
              let light = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test colors")
            return
        }

        let expectation = expectation(description: "two notifications")
        expectation.expectedFulfillmentCount = 2
        var postedHexes: [String] = []

        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0.01,
            postNotification: { userInfo in
                let hex = (userInfo[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil"
                postedHexes.append(hex)
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            dispatcher.signal(backgroundColor: dark, opacity: 1.0, eventId: 1, source: "test.dark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                dispatcher.signal(backgroundColor: light, opacity: 1.0, eventId: 2, source: "test.light")
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(postedHexes, ["#272822", "#FDF6E3"])
    }

    private func postedOpacity(from value: Any?) -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        XCTFail("Expected background opacity payload")
        return -1
    }
}

final class RecentlyClosedBrowserStackTests: XCTestCase {
    func testPopReturnsEntriesInLIFOOrder() {
        var stack = RecentlyClosedBrowserStack(capacity: 20)
        stack.push(makeSnapshot(index: 1))
        stack.push(makeSnapshot(index: 2))
        stack.push(makeSnapshot(index: 3))

        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 2)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 1)
        XCTAssertNil(stack.pop())
    }

    func testPushDropsOldestEntriesWhenCapacityExceeded() {
        var stack = RecentlyClosedBrowserStack(capacity: 3)
        for index in 1...5 {
            stack.push(makeSnapshot(index: index))
        }

        XCTAssertEqual(stack.pop()?.originalTabIndex, 5)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 4)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertNil(stack.pop())
    }

    private func makeSnapshot(index: Int) -> ClosedBrowserPanelRestoreSnapshot {
        ClosedBrowserPanelRestoreSnapshot(
            workspaceId: UUID(),
            url: URL(string: "https://example.com/\(index)"),
            profileID: nil,
            originalPaneId: UUID(),
            originalTabIndex: index,
            fallbackSplitOrientation: .horizontal,
            fallbackSplitInsertFirst: false,
            fallbackAnchorPaneId: UUID()
        )
    }
}

final class SocketControlSettingsTests: XCTestCase {
    func testMigrateModeSupportsExpandedSocketModes() {
        XCTAssertEqual(SocketControlSettings.migrateMode("off"), .off)
        XCTAssertEqual(SocketControlSettings.migrateMode("cmuxOnly"), .cmuxOnly)
        XCTAssertEqual(SocketControlSettings.migrateMode("automation"), .automation)
        XCTAssertEqual(SocketControlSettings.migrateMode("password"), .password)
        XCTAssertEqual(SocketControlSettings.migrateMode("allow-all"), .allowAll)

        // Legacy aliases
        XCTAssertEqual(SocketControlSettings.migrateMode("notifications"), .automation)
        XCTAssertEqual(SocketControlSettings.migrateMode("full"), .allowAll)
    }

    func testSocketModePermissions() {
        XCTAssertEqual(SocketControlMode.off.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.cmuxOnly.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.automation.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.password.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.allowAll.socketFilePermissions, 0o666)
    }

    func testInvalidEnvSocketModeDoesNotOverrideUserMode() {
        XCTAssertNil(
            SocketControlSettings.envOverrideMode(
                environment: ["CMUX_SOCKET_MODE": "definitely-not-a-mode"]
            )
        )
        XCTAssertEqual(
            SocketControlSettings.effectiveMode(
                userMode: .password,
                environment: ["CMUX_SOCKET_MODE": "definitely-not-a-mode"]
            ),
            .password
        )
    }

    func testStableReleaseIgnoresAmbientSocketOverrideByDefault() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }

    func testNightlyReleaseUsesDedicatedDefaultAndIgnoresAmbientSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.nightly",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, "/tmp/cmux-nightly.sock")
    }

    func testDebugBundleHonorsSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-my-tag.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.my-tag",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-my-tag.sock")
    }

    func testStagingBundleHonorsSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-staging-my-tag.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.staging.my-tag",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-staging-my-tag.sock")
    }

    func testStableReleaseCanOptInToSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-forced.sock",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-forced.sock")
    }

    func testDefaultSocketPathByChannel() {
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            SocketControlSettings.stableDefaultSocketPath
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.nightly",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-nightly.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.debug.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-debug.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.staging.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-staging.sock"
        )
    }

    func testStableReleaseFallsBackToUserScopedSocketWhenStablePathOwnedByDifferentUser() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 0) }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testStableReleaseFallsBackToUserScopedSocketWhenStablePathIsBlockedByNonSocketEntry() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .other(ownerUserID: 501) }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testUntaggedDebugBundleBlockedWithoutLaunchTag() {
        XCTAssertTrue(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testUntaggedDebugBundleAllowedWithLaunchTag() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["CMUX_TAG": "tests-v1"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testTaggedDebugBundleAllowedWithoutLaunchTag() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug.tests-v1",
                isDebugBuild: true
            )
        )
    }

    func testReleaseBuildIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: false
            )
        )
    }

    func testXCTestLaunchIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testXCTestInjectBundleLaunchIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["XCInjectBundle": "/tmp/fake.xctest"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testXCTestDyldLaunchIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["DYLD_INSERT_LIBRARIES": "/usr/lib/libXCTestBundleInject.dylib"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testXCUITestLaunchEnvironmentIgnoresLaunchTagGate() {
        // XCUITest launches the app as a separate process without XCTest env vars.
        // The app receives CMUX_UI_TEST_* vars via XCUIApplication.launchEnvironment.
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["CMUX_UI_TEST_MODE": "1"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }
}

final class UITestLaunchManifestTests: XCTestCase {
    func testManifestPathReadsArgumentValue() {
        XCTAssertEqual(
            UITestLaunchManifest.manifestPath(
                from: ["cmux", "-cmuxUITestLaunchManifest", "/tmp/cmux-ui-test-launch.json"]
            ),
            "/tmp/cmux-ui-test-launch.json"
        )
    }

    func testManifestPathReturnsNilWithoutValue() {
        XCTAssertNil(
            UITestLaunchManifest.manifestPath(
                from: ["cmux", "-cmuxUITestLaunchManifest"]
            )
        )
    }

    func testApplyIfPresentDecodesEnvironmentPayload() {
        let payload = """
        {"environment":{"CMUX_TAG":"ui-tests-display","CMUX_SOCKET_PATH":"/tmp/cmux-ui-tests.sock"}}
        """.data(using: .utf8)!
        var applied: [String: String] = [:]

        UITestLaunchManifest.applyIfPresent(
            arguments: ["cmux", UITestLaunchManifest.argumentName, "/tmp/cmux-ui-test-launch.json"],
            loadData: { _ in payload },
            applyEnvironment: { key, value in
                applied[key] = value
            }
        )

        XCTAssertEqual(applied["CMUX_TAG"], "ui-tests-display")
        XCTAssertEqual(applied["CMUX_SOCKET_PATH"], "/tmp/cmux-ui-tests.sock")
    }
}

final class PostHogAnalyticsPropertiesTests: XCTestCase {
    func testDailyActivePropertiesIncludeVersionAndBuild() {
        let properties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "didBecomeActive",
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        XCTAssertEqual(properties["day_utc"] as? String, "2026-02-21")
        XCTAssertEqual(properties["reason"] as? String, "didBecomeActive")
        XCTAssertEqual(properties["app_version"] as? String, "0.31.0")
        XCTAssertEqual(properties["app_build"] as? String, "230")
    }

    func testSuperPropertiesIncludePlatformVersionAndBuild() {
        let properties = PostHogAnalytics.superProperties(
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        XCTAssertEqual(properties["platform"] as? String, "cmuxterm")
        XCTAssertEqual(properties["app_version"] as? String, "0.31.0")
        XCTAssertEqual(properties["app_build"] as? String, "230")
    }

    func testHourlyActivePropertiesIncludeVersionAndBuild() {
        let properties = PostHogAnalytics.hourlyActiveProperties(
            hourUTC: "2026-02-21T14",
            reason: "didBecomeActive",
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        XCTAssertEqual(properties["hour_utc"] as? String, "2026-02-21T14")
        XCTAssertEqual(properties["reason"] as? String, "didBecomeActive")
        XCTAssertEqual(properties["app_version"] as? String, "0.31.0")
        XCTAssertEqual(properties["app_build"] as? String, "230")
    }

    func testHourlyPropertiesOmitVersionFieldsWhenUnavailable() {
        let properties = PostHogAnalytics.hourlyActiveProperties(
            hourUTC: "2026-02-21T14",
            reason: "activeTimer",
            infoDictionary: [:]
        )

        XCTAssertEqual(properties["hour_utc"] as? String, "2026-02-21T14")
        XCTAssertEqual(properties["reason"] as? String, "activeTimer")
        XCTAssertNil(properties["app_version"])
        XCTAssertNil(properties["app_build"])
    }

    func testPropertiesOmitVersionFieldsWhenUnavailable() {
        let superProperties = PostHogAnalytics.superProperties(infoDictionary: [:])
        XCTAssertEqual(superProperties["platform"] as? String, "cmuxterm")
        XCTAssertNil(superProperties["app_version"])
        XCTAssertNil(superProperties["app_build"])

        let dailyProperties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "activeTimer",
            infoDictionary: [:]
        )
        XCTAssertEqual(dailyProperties["day_utc"] as? String, "2026-02-21")
        XCTAssertEqual(dailyProperties["reason"] as? String, "activeTimer")
        XCTAssertNil(dailyProperties["app_version"])
        XCTAssertNil(dailyProperties["app_build"])
    }

    func testFlushPolicyIncludesDailyAndHourlyActiveEvents() {
        XCTAssertTrue(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_daily_active"))
        XCTAssertTrue(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_hourly_active"))
        XCTAssertFalse(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_other_event"))
    }
}

final class GhosttyMouseFocusTests: XCTestCase {
    func testShouldRequestFirstResponderForMouseFocusWhenEnabledAndWindowIsActive() {
        XCTAssertTrue(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: false
            )
        )
    }

    func testShouldNotRequestFirstResponderWhenFocusFollowsMouseDisabled() {
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: false,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: false
            )
        )
    }

    func testShouldNotRequestFirstResponderDuringMouseDrag() {
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 1,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: false
            )
        )
    }

    func testShouldNotRequestFirstResponderWhenViewCannotSafelyReceiveFocus() {
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: false,
                hiddenInHierarchy: false
            )
        )
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: true
            )
        )
    }

    // MARK: - CJK Font Fallback

    private func withTempConfig(
        _ contents: String,
        body: (String) -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("config")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        body(file.path)
    }

    // MARK: cjkFontMappings

    func testCJKFontMappingsReturnsHiraginoWithKanaForJapanese() {
        let mappings = GhosttyApp.cjkFontMappings(preferredLanguages: ["ja-JP", "en-US"])!
        let fonts = Set(mappings.map(\.1))
        let ranges = mappings.map(\.0)

        XCTAssertTrue(fonts.contains("Hiragino Sans"))
        XCTAssertTrue(ranges.contains("U+3040-U+309F"), "Should include Hiragana")
        XCTAssertTrue(ranges.contains("U+30A0-U+30FF"), "Should include Katakana")
        XCTAssertTrue(ranges.contains("U+4E00-U+9FFF"), "Should include CJK Ideographs")
        XCTAssertFalse(ranges.contains("U+AC00-U+D7AF"), "Should NOT include Hangul")
    }

    func testCJKFontMappingsReturnsNilForKoreanOnly() {
        // Korean is not auto-mapped — Ghostty's native CTFontCreateForString
        // fallback selects a better-matching font for Hangul.
        XCTAssertNil(GhosttyApp.cjkFontMappings(preferredLanguages: ["ko-KR"]))
    }

    func testCJKFontMappingsReturnsPingFangForChinese() {
        let mappingsTW = GhosttyApp.cjkFontMappings(preferredLanguages: ["zh-Hant-TW"])!
        XCTAssertTrue(mappingsTW.contains { $0.1 == "PingFang TC" })

        let mappingsCN = GhosttyApp.cjkFontMappings(preferredLanguages: ["zh-Hans-CN"])!
        XCTAssertTrue(mappingsCN.contains { $0.1 == "PingFang SC" })

        let mappingsHK = GhosttyApp.cjkFontMappings(preferredLanguages: ["zh-HK"])!
        XCTAssertTrue(mappingsHK.contains { $0.1 == "PingFang TC" })
    }

    func testCJKFontMappingsReturnsNilForNonCJKLanguages() {
        XCTAssertNil(GhosttyApp.cjkFontMappings(preferredLanguages: ["en-US", "fr-FR"]))
        XCTAssertNil(GhosttyApp.cjkFontMappings(preferredLanguages: []))
    }

    func testCJKFontMappingsMultiLanguageSkipsKorean() {
        // When both ja and ko are preferred, only Japanese mappings are generated.
        // Korean is left to Ghostty's native CTFontCreateForString fallback.
        let mappings = GhosttyApp.cjkFontMappings(preferredLanguages: ["ja-JP", "ko-KR"])!

        let hiraginoRanges = mappings.filter { $0.1 == "Hiragino Sans" }.map(\.0)

        XCTAssertTrue(hiraginoRanges.contains("U+3040-U+309F"), "Hiragana → Hiragino")
        XCTAssertTrue(hiraginoRanges.contains("U+4E00-U+9FFF"), "Shared CJK → first lang font")
        XCTAssertFalse(mappings.contains { $0.1 == "Apple SD Gothic Neo" }, "No Korean font mapping")
        XCTAssertFalse(hiraginoRanges.contains("U+AC00-U+D7AF"), "Hangul NOT in Hiragino")
    }

    // MARK: autoInjectedCJKFontMappings

    func testAutoInjectedCJKFontMappingsSkipsRangesCoveredByConfiguredPrimaryFont() throws {
        let coveredRanges: Set<String> = [
            "U+3000-U+303F",
            "U+4E00-U+9FFF",
            "U+F900-U+FAFF",
            "U+FF00-U+FFEF",
            "U+3400-U+4DBF",
        ]

        try withTempConfig("font-family = Sarasa Mono K\n") { path in
            XCTAssertNil(
                GhosttyApp.autoInjectedCJKFontMappings(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path],
                    rangeCoverageProbe: { fontFamily, range in
                        XCTAssertEqual(fontFamily, "Sarasa Mono K")
                        return coveredRanges.contains(range)
                    }
                )
            )
        }
    }

    func testAutoInjectedCJKFontMappingsKeepsOnlyUncoveredRanges() throws {
        let coveredRanges: Set<String> = [
            "U+3000-U+303F",
            "U+4E00-U+9FFF",
            "U+F900-U+FAFF",
            "U+FF00-U+FFEF",
            "U+3400-U+4DBF",
        ]

        try withTempConfig("font-family = Example CJK Mono\n") { path in
            let mappings = GhosttyApp.autoInjectedCJKFontMappings(
                preferredLanguages: ["ja-JP"],
                configPaths: [path],
                rangeCoverageProbe: { _, range in
                    coveredRanges.contains(range)
                }
            )!

            XCTAssertEqual(Set(mappings.map(\.0)), Set(["U+3040-U+309F", "U+30A0-U+30FF"]))
            XCTAssertEqual(Set(mappings.map(\.1)), Set(["Hiragino Sans"]))
        }
    }

    // MARK: userConfigContainsCJKCodepointMap

    func testUserConfigContainsCJKCodepointMapDetectsPresence() throws {
        try withTempConfig("font-family = Menlo\nfont-codepoint-map = U+3000-U+9FFF=Hiragino Sans\n") { path in
            XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path]))
        }
    }

    func testUserConfigContainsCJKCodepointMapReturnsFalseWhenAbsent() throws {
        try withTempConfig("font-family = Menlo\nfont-size = 14\n") { path in
            XCTAssertFalse(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path]))
        }
    }

    func testUserConfigContainsCJKCodepointMapIgnoresComments() throws {
        try withTempConfig("# font-codepoint-map = U+3000-U+9FFF=Hiragino Sans\n") { path in
            XCTAssertFalse(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path]))
        }
    }

    func testUserConfigContainsCJKCodepointMapReturnsFalseForMissingFiles() {
        let path = NSTemporaryDirectory() + "cmux-nonexistent-\(UUID().uuidString)/config"
        XCTAssertFalse(
            GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path])
        )
    }

    func testUserConfigContainsCJKCodepointMapFollowsConfigFileIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-codepoint-map = U+3000-U+9FFF=Hiragino Sans\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = Menlo\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [main.path]))
    }

    func testUserConfigContainsCJKCodepointMapFollowsRelativeIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-codepoint-map = U+4E00-U+9FFF=Hiragino Sans\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "config-file = fonts.conf\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [main.path]))
    }

    func testUserConfigContainsCJKCodepointMapHandlesOptionalInclude() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-opt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-codepoint-map = U+4E00-U+9FFF=Hiragino Sans\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "config-file = ?\(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [main.path]))
    }

    func testUserConfigContainsCJKCodepointMapHandlesCyclicIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-cycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.conf")
        let fileB = dir.appendingPathComponent("b.conf")
        try "config-file = \(fileB.path)\n"
            .write(to: fileA, atomically: true, encoding: .utf8)
        try "config-file = \(fileA.path)\n"
            .write(to: fileB, atomically: true, encoding: .utf8)

        // Should not hang; should return false since neither file has font-codepoint-map
        XCTAssertFalse(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [fileA.path]))
    }

    func testUserConfigContainsCJKCodepointMapRespectsReset() throws {
        try withTempConfig("""
        font-codepoint-map = U+4E00-U+9FFF=Hiragino Sans
        font-codepoint-map =
        """) { path in
            XCTAssertFalse(
                GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path])
            )
        }
    }

    // MARK: userConfigHasExplicitFontFamilyFallbackChain

    func testUserConfigHasExplicitFontFamilyFallbackChainDetectsMultipleEntries() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        font-family = LXGW WenKai Mono TC
        """) { path in
            XCTAssertTrue(
                GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [path])
            )
        }
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainFollowsConfigFileIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [main.path])
        )
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainRespectsFontFamilyReset() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        font-family =
        font-family = LXGW WenKai Mono TC
        """) { path in
            XCTAssertFalse(
                GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [path])
            )
        }
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainIgnoresDuplicateFamilies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-duplicate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\n"
            .write(to: legacy, atomically: true, encoding: .utf8)

        let preferred = dir.appendingPathComponent("config.ghostty")
        try "font-family = JetBrains Mono\n"
            .write(to: preferred, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(
                configPaths: [legacy.path, preferred.path]
            )
        )
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainMatchesGhosttyIncludeLoadOrder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        let reset = dir.appendingPathComponent("config.ghostty")
        try "font-family =\n"
            .write(to: reset, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(
                configPaths: [main.path, reset.path]
            )
        )
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainRespectsConfigFileReset() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-config-file-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        let reset = dir.appendingPathComponent("config.ghostty")
        try "config-file =\n"
            .write(to: reset, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(
                configPaths: [main.path, reset.path]
            )
        )
    }

    // MARK: shouldInjectCJKFontFallback

    func testShouldInjectCJKFontFallbackSkipsExplicitMultiFontFallbackChain() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        font-family = LXGW WenKai Mono TC
        """) { path in
            XCTAssertFalse(
                GhosttyApp.shouldInjectCJKFontFallback(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path]
                )
            )
        }
    }

    func testShouldInjectCJKFontFallbackAllowsSingleFontWithoutExplicitOverrides() throws {
        try withTempConfig("font-family = JetBrains Mono\n") { path in
            XCTAssertTrue(
                GhosttyApp.shouldInjectCJKFontFallback(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path]
                )
            )
        }
    }

    func testShouldInjectCJKFontFallbackSkipsConfiguredFontThatAlreadyCoversMappedRanges() throws {
        let coveredRanges: Set<String> = [
            "U+3000-U+303F",
            "U+4E00-U+9FFF",
            "U+F900-U+FAFF",
            "U+FF00-U+FFEF",
            "U+3400-U+4DBF",
        ]

        try withTempConfig("font-family = Sarasa Mono K\n") { path in
            XCTAssertFalse(
                GhosttyApp.shouldInjectCJKFontFallback(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path],
                    rangeCoverageProbe: { fontFamily, range in
                        XCTAssertEqual(fontFamily, "Sarasa Mono K")
                        return coveredRanges.contains(range)
                    }
                )
            )
        }
    }

    func testLoadedCJKScanPathsSkipsReleaseAppSupportWhenTaggedConfigExists() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-app-support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let taggedDir = appSupport.appendingPathComponent("com.example.cmux-dev", isDirectory: true)
        try FileManager.default.createDirectory(at: taggedDir, withIntermediateDirectories: true)
        let taggedConfig = taggedDir.appendingPathComponent("config", isDirectory: false)
        try "font-family = JetBrains Mono\n"
            .write(to: taggedConfig, atomically: true, encoding: .utf8)

        let releaseDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseDir, withIntermediateDirectories: true)
        let releaseConfig = releaseDir.appendingPathComponent("config", isDirectory: false)
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: releaseConfig, atomically: true, encoding: .utf8)

        let paths = GhosttyApp.loadedCJKScanPaths(
            currentBundleIdentifier: "com.example.cmux-dev",
            appSupportDirectory: appSupport
        )

        XCTAssertTrue(paths.contains(taggedConfig.path))
        XCTAssertFalse(paths.contains(releaseConfig.path))
        XCTAssertTrue(
            GhosttyApp.shouldInjectCJKFontFallback(
                preferredLanguages: ["zh-Hans-CN"],
                configPaths: paths
            )
        )
    }
}

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

final class ZshShellIntegrationHandoffTests: XCTestCase {
    func testGhosttyPromptHooksLoadWhenCmuxRequestsZshIntegration() throws {
        let output = try runInteractiveZsh(cmuxLoadGhosttyIntegration: true)

        XCTAssertTrue(output.contains("PRECMD=1"), output)
        XCTAssertTrue(output.contains("PREEXEC=1"), output)
        XCTAssertTrue(output.contains("PRECMDS=_ghostty_precmd"), output)
    }

    func testGhosttyPromptHooksDoNotLoadWithoutCmuxHandoffFlag() throws {
        let output = try runInteractiveZsh(cmuxLoadGhosttyIntegration: false)

        XCTAssertTrue(output.contains("PRECMD=0"), output)
        XCTAssertTrue(output.contains("PREEXEC=0"), output)
    }

    func testGhosttySemanticPatchRetriesAfterDeferredInitCreatesLiveHooks() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: true,
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_patch_ghostty_semantic_redraw
            (( $+functions[_ghostty_deferred_init] )) && _ghostty_deferred_init >/dev/null 2>&1
            _cmux_patch_ghostty_semantic_redraw
            print -r -- "PRECMD_BODY=${functions[_ghostty_precmd]}"
            print -r -- "PREEXEC_BODY=${functions[_ghostty_preexec]}"
            """
        )

        XCTAssertTrue(output.contains("PRECMD_BODY="), output)
        XCTAssertTrue(output.contains("PREEXEC_BODY="), output)
        XCTAssertTrue(output.contains("133;A;redraw=last;cl=line"), output)
    }

    func testShellIntegrationWinchGuardDoesNotPrintSpacerLineOnResize() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- BEFORE
            TRAPWINCH
            print -r -- AFTER
            """
        )

        XCTAssertEqual(output, "BEFORE\nAFTER", output)
    }

    func testShellIntegrationPreservesStartupTermForThemeSelectionBeforeRestoringManagedTerm() throws {
        let output = try runPromptInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "CMD=$TERM|${CMUX_ZSH_RESTORE_TERM-unset}" >> "$CMUX_TEST_OUTPUT"
            """,
            userZshRCContents: """
            export CMUX_STARTUP_THEME_TERM="$TERM"
            if [[ $TERM = (*256color|*rxvt*) ]]; then
              export CMUX_STARTUP_THEME_BRANCH=extended
            else
              export CMUX_STARTUP_THEME_BRANCH=basic
            fi

            cmux_test_ready() {
              [[ -e "$CMUX_TEST_READY" ]] && return 0
              print -r -- "PRE=$CMUX_STARTUP_THEME_TERM|$CMUX_STARTUP_THEME_BRANCH|$TERM|${CMUX_ZSH_RESTORE_TERM-unset}" > "$CMUX_TEST_OUTPUT"
              : > "$CMUX_TEST_READY"
              precmd_functions=(${precmd_functions:#cmux_test_ready})
            }
            precmd_functions+=(cmux_test_ready)
            """
        )

        XCTAssertEqual(
            output,
            "PRE=xterm-ghostty|basic|xterm-ghostty|xterm-256color\nCMD=xterm-256color|unset",
            output
        )
    }

    func testShellIntegrationDoesNotSpoofManagedTermForInteractiveCommandMode() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "$CMUX_STARTUP_TERM|$TERM|${CMUX_ZSH_RESTORE_TERM-unset}"
            """,
            userZshRCContents: """
            export CMUX_STARTUP_TERM="$TERM"
            """
        )

        XCTAssertEqual(output, "xterm-256color|xterm-256color|unset", output)
    }

    func testShellIntegrationDoesNotSpoofManagedTermWhenIntegrationDisabled() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: false,
            command: """
            print -r -- "$CMUX_STARTUP_TERM|$TERM|${CMUX_ZSH_RESTORE_TERM-unset}"
            """,
            userZshRCContents: """
            export CMUX_STARTUP_TERM="$TERM"
            """
        )

        XCTAssertEqual(output, "xterm-256color|xterm-256color|unset", output)
    }

    func testShellIntegrationDoesNotSpoofManagedTermWhenUserZshEnvDisablesIntegration() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "$CMUX_STARTUP_TERM|$TERM|${CMUX_ZSH_RESTORE_TERM-unset}|${CMUX_SHELL_INTEGRATION:-unset}"
            """,
            userZshEnvContents: """
            export CMUX_SHELL_INTEGRATION=0
            """,
            userZshRCContents: """
            export CMUX_STARTUP_TERM="$TERM"
            """
        )

        XCTAssertEqual(output, "xterm-256color|xterm-256color|unset|0", output)
    }

    func testShellIntegrationDoesNotRegisterPromptTimeTermRestoreHooks() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "${(j:,:)precmd_functions}"
            """
        )

        XCTAssertEqual(
            output,
            "_cmux_precmd,_cmux_fix_path",
            output
        )
    }

    func testShellIntegrationRestoresManagedTermDuringPreexec() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_preexec 'echo $TERM'
            print -r -- "$TERM|${CMUX_ZSH_RESTORE_TERM-unset}"
            """,
            extraEnvironment: [
                "TERM": "xterm-ghostty",
                "CMUX_ZSH_RESTORE_TERM": "xterm-256color",
            ]
        )

        XCTAssertEqual(
            output,
            "xterm-256color|unset",
            output
        )
    }

    func testShellIntegrationPublishesOnlyWorkspaceScopedCmuxEnvironmentToTmuxServerAutomatically() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-tmux-publish-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("tmux.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              exit 0
            fi
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        _ = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: "_cmux_preexec tmux; print -r -- READY",
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "/tmp/cmux-current.sock",
                "CMUX_TAG": "feat-tmux-notification-attention-state",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("set-environment -g CMUX_TAG feat-tmux-notification-attention-state"), log)
        XCTAssertTrue(log.contains("set-environment -g CMUX_SOCKET_PATH /tmp/cmux-current.sock"), log)
        XCTAssertTrue(log.contains("set-environment -g CMUX_WORKSPACE_ID 11111111-1111-1111-1111-111111111111"), log)
        XCTAssertFalse(log.contains("set-environment -g CMUX_SURFACE_ID"), log)
        XCTAssertFalse(log.contains("set-environment -g CMUX_PANEL_ID"), log)
    }

    func testShellIntegrationClearsStaleSurfaceScopedTmuxEnvironmentAutomatically() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-tmux-clear-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("tmux.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              printf '%s\\n' 'CMUX_SURFACE_ID=99999999-9999-9999-9999-999999999999'
              printf '%s\\n' 'CMUX_PANEL_ID=99999999-9999-9999-9999-999999999999'
              exit 0
            fi
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        _ = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: "_cmux_preexec tmux; print -r -- READY",
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "/tmp/cmux-current.sock",
                "CMUX_TAG": "feat-tmux-notification-attention-state",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("set-environment -gu CMUX_SURFACE_ID"), log)
        XCTAssertTrue(log.contains("set-environment -gu CMUX_PANEL_ID"), log)
    }

    func testShellIntegrationRefreshesWorkspaceScopedCmuxEnvironmentFromTmuxWithoutOverwritingSurfaceScope() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-tmux-refresh-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              printf '%s\\n' 'CMUX_SOCKET_PATH=/tmp/cmux-current.sock'
              printf '%s\\n' 'CMUX_TAG=feat-tmux-notification-attention-state'
              printf '%s\\n' 'CMUX_WORKSPACE_ID=11111111-1111-1111-1111-111111111111'
              printf '%s\\n' 'CMUX_SURFACE_ID=99999999-9999-9999-9999-999999999999'
              printf '%s\\n' 'CMUX_TAB_ID=11111111-1111-1111-1111-111111111111'
              printf '%s\\n' 'CMUX_PANEL_ID=99999999-9999-9999-9999-999999999999'
              exit 0
            fi
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: "_cmux_precmd; print -r -- \"$CMUX_TAG|$CMUX_SOCKET_PATH|$CMUX_WORKSPACE_ID|$CMUX_SURFACE_ID|$CMUX_PANEL_ID\"",
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "TMUX": "/tmp/tmux-stale,123,0",
                "CMUX_SOCKET_PATH": "/tmp/cmux-stale.sock",
                "CMUX_TAG": "feat-tmux-integration-experiments",
                "CMUX_WORKSPACE_ID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TAB_ID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertEqual(
            output,
            "feat-tmux-notification-attention-state|/tmp/cmux-current.sock|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222|22222222-2222-2222-2222-222222222222"
        )
    }

    func testShellIntegrationReportsTTYFromTmuxWithoutUsingPanelScope() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _CMUX_TTY_NAME=ttys999
            print -r -- "$(_cmux_report_tty_payload)"
            """,
            extraEnvironment: [
                "TMUX": "/tmp/tmux-current,123,0",
                "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_PANEL_ID": "99999999-9999-9999-9999-999999999999",
            ]
        )

        XCTAssertEqual(output, "report_tty ttys999 --tab=11111111-1111-1111-1111-111111111111")
    }

    func testShellIntegrationRelayReportTTYUsesWorkspaceIDInZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-report-tty-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_NAME=ttys777
            _cmux_report_tty_via_relay
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys777","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            output
        )
    }

    func testShellIntegrationRelayPortsKickOmitsSurfaceIDUntilAvailableInZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-kick-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _cmux_ports_kick_via_relay refresh
            repeat 20; do
              [[ -s "\(logPath.path)" ]] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh"}"#),
            output
        )
        XCTAssertFalse(output.contains("surface_id"), output)
    }

    func testShellIntegrationRelayPromptRefreshUsesRefreshReasonInZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-precmd-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=-999
            _cmux_precmd
            repeat 20; do
              [[ -s "\(logPath.path)" ]] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            output
        )
    }

    func testShellIntegrationRelayReportTTYUsesWorkspaceIDInBash() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-report-tty-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_NAME=ttys888
            _cmux_report_tty_via_relay
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys888","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
    }

    func testShellIntegrationRelayPreexecWorksBeforeSurfaceIDExistsInBash() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-preexec-no-surface-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_NAME=ttys889
            _CMUX_TTY_REPORTED=0
            _cmux_preexec_command "python3 -m http.server 8899"
            for _cmux_i in $(seq 1 20); do
              [ -s "\(logPath.path)" ] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "",
            ]
        )

        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys889"}"#),
            result.stdout
        )
        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"command"}"#),
            result.stdout
        )
        XCTAssertFalse(result.stdout.contains(#""surface_id""#), result.stdout)
    }

    func testShellIntegrationRelayPromptRefreshUsesRefreshReasonInBashWithoutPromptNoise() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-prompt-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=-999
            _cmux_prompt_command
            for _cmux_i in $(seq 1 20); do
              [ -s "\(logPath.path)" ] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertFalse(result.stderr.contains("_cmux_report_tmux_state"), result.stderr)
        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
    }

    private func runInteractiveZsh(cmuxLoadGhosttyIntegration: Bool) throws -> String {
        try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: cmuxLoadGhosttyIntegration,
            cmuxLoadShellIntegration: false,
            command: "(( $+functions[_ghostty_deferred_init] )) && _ghostty_deferred_init >/dev/null 2>&1; " +
                "print -r -- \"PRECMD=${+functions[_ghostty_precmd]} " +
                "PREEXEC=${+functions[_ghostty_preexec]} PRECMDS=${(j:,:)precmd_functions}\""
        )
    }

    private func runInteractiveZsh(
        cmuxLoadGhosttyIntegration: Bool,
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:],
        userZshEnvContents: String? = nil,
        userZshRCContents: String? = nil
    ) throws -> String {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let userZdotdir = root.appendingPathComponent("zdotdir")
        try fileManager.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
        var userZshEnvFileContents = "\n"
        if let path = extraEnvironment["PATH"] {
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            userZshEnvFileContents = "export PATH=\"\(escaped)\"\n"
        }
        if let userZshEnvContents {
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
            userZshEnvFileContents.append(userZshEnvContents)
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
        }
        try userZshEnvFileContents.write(
            to: userZdotdir.appendingPathComponent(".zshenv"),
            atomically: true,
            encoding: .utf8
        )
        if let userZshRCContents {
            try userZshRCContents.write(
                to: userZdotdir.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cmuxZdotdir = repoRoot.appendingPathComponent("Resources/shell-integration")
        let ghosttyResources = repoRoot.appendingPathComponent("ghostty/src")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-i",
            "-c", command
        ]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "ZDOTDIR": cmuxZdotdir.path,
            "CMUX_ZSH_ZDOTDIR": userZdotdir.path,
            "CMUX_SHELL_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": ghosttyResources.path,
        ]
        if cmuxLoadGhosttyIntegration {
            process.environment?["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        }
        if cmuxLoadShellIntegration {
            process.environment?["CMUX_SHELL_INTEGRATION"] = "1"
            process.environment?["CMUX_SHELL_INTEGRATION_DIR"] = cmuxZdotdir.path
            process.environment?["CMUX_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
            process.environment?["CMUX_TAB_ID"] = "tab-test"
            process.environment?["CMUX_PANEL_ID"] = "panel-test"
        }
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Timed out waiting for zsh to exit")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, error)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runPromptInteractiveZsh(
        cmuxLoadGhosttyIntegration: Bool,
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:],
        userZshEnvContents: String? = nil,
        userZshRCContents: String? = nil
    ) throws -> String {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-prompt-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let userZdotdir = root.appendingPathComponent("zdotdir")
        try fileManager.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
        var userZshEnvFileContents = "\n"
        if let path = extraEnvironment["PATH"] {
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            userZshEnvFileContents = "export PATH=\"\(escaped)\"\n"
        }
        if let userZshEnvContents {
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
            userZshEnvFileContents.append(userZshEnvContents)
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
        }
        try userZshEnvFileContents.write(
            to: userZdotdir.appendingPathComponent(".zshenv"),
            atomically: true,
            encoding: .utf8
        )
        if let userZshRCContents {
            try userZshRCContents.write(
                to: userZdotdir.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cmuxZdotdir = repoRoot.appendingPathComponent("Resources/shell-integration")
        let ghosttyResources = repoRoot.appendingPathComponent("ghostty/src")
        let readyPath = root.appendingPathComponent("ready", isDirectory: false)
        let outputPath = root.appendingPathComponent("output.log", isDirectory: false)

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            let message = "openpty failed: \(String(cString: strerror(errno)))"
            XCTFail(message)
            throw NSError(
                domain: "ZshShellIntegrationHandoffTests",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i"]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "ZDOTDIR": cmuxZdotdir.path,
            "CMUX_ZSH_ZDOTDIR": userZdotdir.path,
            "CMUX_SHELL_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": ghosttyResources.path,
            "CMUX_TEST_READY": readyPath.path,
            "CMUX_TEST_OUTPUT": outputPath.path,
        ]
        if cmuxLoadGhosttyIntegration {
            process.environment?["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        }
        if cmuxLoadShellIntegration {
            process.environment?["CMUX_SHELL_INTEGRATION"] = "1"
            process.environment?["CMUX_SHELL_INTEGRATION_DIR"] = cmuxZdotdir.path
            process.environment?["CMUX_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
            process.environment?["CMUX_TAB_ID"] = "tab-test"
            process.environment?["CMUX_PANEL_ID"] = "panel-test"
        }
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let terminalOutputLock = NSLock()
        var terminalOutputData = Data()
        masterHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            terminalOutputLock.lock()
            terminalOutputData.append(data)
            terminalOutputLock.unlock()
        }
        defer { masterHandle.readabilityHandler = nil }

        func terminalOutputSnapshot() -> String {
            terminalOutputLock.lock()
            defer { terminalOutputLock.unlock() }
            return String(data: terminalOutputData, encoding: .utf8) ?? ""
        }

        try process.run()
        slaveHandle.closeFile()

        let readyDeadline = Date().addingTimeInterval(5)
        while !fileManager.fileExists(atPath: readyPath.path) && Date() < readyDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if !fileManager.fileExists(atPath: readyPath.path) {
            process.terminate()
            process.waitUntilExit()
            let terminalOutput = terminalOutputSnapshot()
            let message = "Timed out waiting for interactive zsh prompt: \(terminalOutput)"
            XCTFail(message)
            throw NSError(
                domain: "ZshShellIntegrationHandoffTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        masterHandle.write(Data((command + "\nexit\n").utf8))

        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < exitDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            let terminalOutput = terminalOutputSnapshot()
            let message = "Timed out waiting for interactive zsh to exit: \(terminalOutput)"
            XCTFail(message)
            throw NSError(
                domain: "ZshShellIntegrationHandoffTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let terminalOutput = terminalOutputSnapshot()
        XCTAssertEqual(process.terminationStatus, 0, terminalOutput)
        return (try? String(contentsOf: outputPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func runInteractiveBash(
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> (stdout: String, stderr: String) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationPath = repoRoot.appendingPathComponent("Resources/shell-integration/cmux-bash-integration.bash")
        let rcfilePath = root.appendingPathComponent(".bashrc")
        let rcfileContents: String = {
            guard cmuxLoadShellIntegration else { return ":\n" }
            return """
            . "\(integrationPath.path)"
            """
        }()
        try rcfileContents.write(to: rcfilePath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "--noprofile",
            "--rcfile", rcfilePath.path,
            "-i",
            "-c", command
        ]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/bash",
            "USER": NSUserName(),
        ]
        if cmuxLoadShellIntegration {
            process.environment?["CMUX_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
            process.environment?["CMUX_TAB_ID"] = "tab-test"
            process.environment?["CMUX_PANEL_ID"] = "panel-test"
        }
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Timed out waiting for bash to exit")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, error)
        return (
            stdout: output.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func writeExecutableScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix socket"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind Unix socket"]
            )
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on Unix socket"]
            )
        }

        return fd
    }
}

final class BrowserInstallDetectorTests: XCTestCase {
    func testDetectInstalledBrowsersUsesBundleIdAndProfileData() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try createFile(
            at: home
                .appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"),
            contents: Data()
        )
        try createFile(
            at: home
                .appendingPathComponent("Library/Application Support/Firefox/Profiles/dev.default-release/cookies.sqlite"),
            contents: Data()
        )

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { bundleIdentifier in
                if bundleIdentifier == "com.google.Chrome" {
                    return URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
                }
                return nil
            },
            applicationSearchDirectories: []
        )

        guard let chrome = detected.first(where: { $0.descriptor.id == "google-chrome" }) else {
            XCTFail("Expected Chrome to be detected")
            return
        }
        guard let firefox = detected.first(where: { $0.descriptor.id == "firefox" }) else {
            XCTFail("Expected Firefox to be detected from profile data")
            return
        }

        XCTAssertNotNil(chrome.appURL)
        XCTAssertEqual(firefox.profileURLs.count, 1)
        XCTAssertNil(firefox.appURL)
    }

    func testDetectInstalledBrowsersReturnsEmptyWhenNoSignalsExist() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: []
        )

        XCTAssertTrue(detected.isEmpty)
    }

    func testUngoogledChromiumRequiresAppSignal() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try createFile(
            at: home
                .appendingPathComponent("Library/Application Support/Chromium/Default/History"),
            contents: Data()
        )

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: []
        )

        XCTAssertTrue(detected.contains(where: { $0.descriptor.id == "chromium" }))
        XCTAssertFalse(detected.contains(where: { $0.descriptor.id == "ungoogled-chromium" }))
    }

    func testDetectInstalledBrowsersDiscoversHeliumProfilesFromChromiumLayout() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let heliumRoot = home.appendingPathComponent("Library/Application Support/net.imput.helium", isDirectory: true)
        try createFile(
            at: heliumRoot.appendingPathComponent("Default/History"),
            contents: Data()
        )
        try createFile(
            at: heliumRoot.appendingPathComponent("Profile 1/Cookies"),
            contents: Data()
        )
        try createFile(
            at: heliumRoot.appendingPathComponent("Local State"),
            contents: Data(
                """
                {
                  "profile": {
                    "info_cache": {
                      "Default": {
                        "name": "Personal"
                      },
                      "Profile 1": {
                        "name": "Work"
                      }
                    }
                  }
                }
                """.utf8
            )
        )

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: []
        )

        guard let helium = detected.first(where: { $0.descriptor.id == "helium" }) else {
            XCTFail("Expected Helium to be detected")
            return
        }

        XCTAssertEqual(helium.family, .chromium)
        XCTAssertEqual(helium.profiles.map(\.displayName), ["Personal", "Work"])
        XCTAssertEqual(
            helium.profiles.map(\.rootURL.lastPathComponent),
            ["Default", "Profile 1"]
        )
    }

    func testDetectInstalledBrowsersDiscoversSafariProfiles() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try createFile(
            at: home.appendingPathComponent("Library/Safari/History.db"),
            contents: Data()
        )
        try createFile(
            at: home.appendingPathComponent(
                "Library/Safari/Profiles/Work/History.db"
            ),
            contents: Data()
        )
        try createFile(
            at: home.appendingPathComponent(
                "Library/Containers/com.apple.Safari/Data/Library/Safari/Profiles/Travel/History.db"
            ),
            contents: Data()
        )

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: []
        )

        guard let safari = detected.first(where: { $0.descriptor.id == "safari" }) else {
            XCTFail("Expected Safari to be detected")
            return
        }

        XCTAssertEqual(Set(safari.profiles.map(\.displayName)), Set(["Default", "Work", "Travel"]))
        XCTAssertEqual(
            safari.profiles
                .map { $0.rootURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false) }
                .sorted(),
            [
                home.appendingPathComponent("Library/Safari", isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
                home.appendingPathComponent("Library/Safari/Profiles/Work", isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
                home.appendingPathComponent(
                    "Library/Containers/com.apple.Safari/Data/Library/Safari/Profiles/Travel",
                    isDirectory: true
                ).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
            ].sorted()
        )
    }

    private func makeTemporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-browser-detect-\(UUID().uuidString)")
    }

    private func createFile(at url: URL, contents: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }
}

final class BrowserImportScopeTests: XCTestCase {
    func testFromSelectionCookiesOnly() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: true,
            includeHistory: false,
            includeAdditionalData: false
        )
        XCTAssertEqual(scope, .cookiesOnly)
    }

    func testFromSelectionHistoryOnly() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: false,
            includeHistory: true,
            includeAdditionalData: false
        )
        XCTAssertEqual(scope, .historyOnly)
    }

    func testFromSelectionCookiesAndHistory() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: true,
            includeHistory: true,
            includeAdditionalData: false
        )
        XCTAssertEqual(scope, .cookiesAndHistory)
    }

    func testFromSelectionEverything() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: false,
            includeHistory: false,
            includeAdditionalData: true
        )
        XCTAssertEqual(scope, .everything)
    }

    func testFromSelectionRejectsEmptySelection() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: false,
            includeHistory: false,
            includeAdditionalData: false
        )
        XCTAssertNil(scope)
    }
}
