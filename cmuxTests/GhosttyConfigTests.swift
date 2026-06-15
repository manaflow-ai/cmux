@preconcurrency import XCTest
import CmuxSettings
import CmuxBrowser
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import CmuxRemoteWorkspace
import CmuxSocketControl
import CmuxFoundation
import AppKit
import CmuxFoundation
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
// The app target still declares legacy duplicates of these CmuxSettings
// value types; with CmuxSettings imported unconditionally the names are
// ambiguous. These tests exercise the app-side paths, so pin the app types.
private typealias BrowserThemeMode = cmux_DEV.BrowserThemeMode
#elseif canImport(cmux)
@testable import cmux
private typealias BrowserThemeMode = cmux.BrowserThemeMode
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

    func testLaunchGhosttyResourcesPreferCurrentBundleOverInheritedEnvironment() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-resources-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let inheritedResources = root.appendingPathComponent("inherited/ghostty", isDirectory: true)
        let bundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try fileManager.createDirectory(
            at: inheritedResources.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: bundledGhostty.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )

        let resolved = cmuxApp.resolvedGhosttyResourcesDirectory(
            currentValue: inheritedResources.path,
            bundleResourceURL: bundleResources,
            ghosttyAppResources: root.appendingPathComponent("missing", isDirectory: true).path,
            fileManager: fileManager
        )

        XCTAssertEqual(resolved, bundledGhostty.path)
    }

    func testLaunchGhosttyResourcesKeepInheritedEnvironmentWhenBundleHasNoResources() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-resource-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let inheritedResources = root.appendingPathComponent("inherited/ghostty", isDirectory: true)
        let emptyBundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        try fileManager.createDirectory(at: inheritedResources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: emptyBundleResources, withIntermediateDirectories: true)

        let resolved = cmuxApp.resolvedGhosttyResourcesDirectory(
            currentValue: inheritedResources.path,
            bundleResourceURL: emptyBundleResources,
            ghosttyAppResources: root.appendingPathComponent("missing", isDirectory: true).path,
            fileManager: fileManager
        )

        XCTAssertEqual(resolved, inheritedResources.path)
    }

    func testLaunchGhosttyResourcesKeepInheritedEnvironmentWhenBundleLacksThemes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-incomplete-resource-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let inheritedResources = root.appendingPathComponent("inherited/ghostty", isDirectory: true)
        let bundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try fileManager.createDirectory(
            at: inheritedResources.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: bundledGhostty, withIntermediateDirectories: true)

        let resolved = cmuxApp.resolvedGhosttyResourcesDirectory(
            currentValue: inheritedResources.path,
            bundleResourceURL: bundleResources,
            ghosttyAppResources: root.appendingPathComponent("missing", isDirectory: true).path,
            fileManager: fileManager
        )

        XCTAssertEqual(resolved, inheritedResources.path)
    }

    func testLaunchGhosttyResourcesUseIncompleteBundleOnlyAsLastFallback() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-incomplete-resource-last-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try fileManager.createDirectory(at: bundledGhostty, withIntermediateDirectories: true)

        let resolved = cmuxApp.resolvedGhosttyResourcesDirectory(
            currentValue: root.appendingPathComponent("missing-inherited", isDirectory: true).path,
            bundleResourceURL: bundleResources,
            ghosttyAppResources: root.appendingPathComponent("missing-app", isDirectory: true).path,
            fileManager: fileManager
        )

        XCTAssertEqual(resolved, bundledGhostty.path)
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

    func testThemeSearchPathsIncludeCmuxUserThemesDirectory() {
        let paths = GhosttyConfig.themeSearchPaths(
            forThemeName: "Zag Light",
            environment: [:],
            bundleResourceURL: nil
        )

        XCTAssertTrue(
            paths.contains(
                "\(NSHomeDirectory())/Library/Application Support/com.cmuxterm.app/themes/Zag Light"
            )
        )
    }

    func testThemeSearchPathsIncludeCmuxUserThemesDirectoryFromFixedHome() {
        let fixedHome = "/tmp/cmux-fixed-home-\(UUID().uuidString)"
        let paths = GhosttyConfig.themeSearchPaths(
            forThemeName: "Zag Light",
            environment: ["CFFIXED_USER_HOME": fixedHome],
            bundleResourceURL: nil
        )

        XCTAssertTrue(
            paths.contains(
                "\(fixedHome)/Library/Application Support/com.cmuxterm.app/themes/Zag Light"
            )
        )
    }

    func testThemesListIncludesCmuxUserThemesDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-user-theme-list-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let themesDirectory = root
            .appendingPathComponent("Library/Application Support/com.cmuxterm.app/themes", isDirectory: true)
        try fileManager.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        try "background = #ffffff\nforeground = #1f2328\n".write(
            to: themesDirectory.appendingPathComponent("Zag Light", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let configURL = themesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("config.ghostty", isDirectory: false)
        try "theme = Zag Light\n".write(to: configURL, atomically: true, encoding: .utf8)

        let result = runCLI(
            try bundledCLIPath(),
            arguments: ["--json", "themes", "list"],
            environment: ["CFFIXED_USER_HOME": root.path],
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.output)
        XCTAssertEqual(result.status, 0, result.output)

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )
        let themes = try XCTUnwrap(payload["themes"] as? [[String: Any]])
        XCTAssertTrue(themes.contains { ($0["name"] as? String) == "Zag Light" }, result.output)
        let current = try XCTUnwrap(payload["current"] as? [String: Any])
        XCTAssertEqual(current["light"] as? String, "Zag Light")
        XCTAssertEqual(current["dark"] as? String, "Zag Light")
        XCTAssertEqual(current["source_path"] as? String, configURL.path)
    }

    func testCmuxDefaultThemeConfigContentsSkipsInvalidUTF8Candidate() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-managed-theme-search-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let firstDataDir = root.appendingPathComponent("first", isDirectory: true)
        let secondDataDir = root.appendingPathComponent("second", isDirectory: true)
        let firstThemeDir = firstDataDir.appendingPathComponent("ghostty/themes", isDirectory: true)
        let secondThemeDir = secondDataDir.appendingPathComponent("ghostty/themes", isDirectory: true)
        try fileManager.createDirectory(at: firstThemeDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondThemeDir, withIntermediateDirectories: true)

        let firstTheme = firstThemeDir.appendingPathComponent("Apple System Colors Light", isDirectory: false)
        try Data([0xff, 0xfe]).write(to: firstTheme)

        let secondTheme = secondThemeDir.appendingPathComponent("Apple System Colors Light", isDirectory: false)
        let expected = "foreground = #123456\n"
        try expected.write(to: secondTheme, atomically: true, encoding: .utf8)

        let contents = GhosttyConfig.cmuxDefaultThemeConfigContents(
            preferredColorScheme: .light,
            environment: ["XDG_DATA_DIRS": "\(firstDataDir.path):\(secondDataDir.path)"],
            bundleResourceURL: nil
        )

        XCTAssertEqual(contents, expected)
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

    func testColorParseFlagsOnlyTrackValuesResolvedBySwiftParser() {
        var namedColorConfig = GhosttyConfig()
        namedColorConfig.parse("background = black\nforeground = #ddeeff\n")

        XCTAssertFalse(namedColorConfig.hasParsedBackgroundColor)
        XCTAssertTrue(namedColorConfig.hasParsedForegroundColor)
        XCTAssertEqual(namedColorConfig.foregroundColor.hexString(), "#DDEEFF")

        var hexColorConfig = GhosttyConfig()
        hexColorConfig.parse("background = #aabbcc\n")

        XCTAssertTrue(hexColorConfig.hasParsedBackgroundColor)
        XCTAssertEqual(hexColorConfig.backgroundColor.hexString(), "#AABBCC")

        var namedOverrideConfig = GhosttyConfig()
        namedOverrideConfig.parse("background = #334455\nbackground = black\nforeground = #ddeeff\nforeground = white\n")

        XCTAssertFalse(namedOverrideConfig.hasParsedBackgroundColor)
        XCTAssertFalse(namedOverrideConfig.hasParsedForegroundColor)

        var invalidScalarOverrideConfig = GhosttyConfig()
        invalidScalarOverrideConfig.parse("background-opacity = 0.42\nbackground-opacity = invalid\nbackground-blur = true\nbackground-blur = maybe\n")

        XCTAssertFalse(invalidScalarOverrideConfig.hasParsedBackgroundOpacity)
        XCTAssertFalse(invalidScalarOverrideConfig.hasParsedBackgroundBlur)

        var highOpacityConfig = GhosttyConfig()
        highOpacityConfig.parse("background-opacity = 2\n")

        XCTAssertTrue(highOpacityConfig.hasParsedBackgroundOpacity)
        XCTAssertEqual(highOpacityConfig.backgroundOpacity, 1.0, accuracy: 0.0001)

        var lowOpacityConfig = GhosttyConfig()
        lowOpacityConfig.parse("background-opacity = -1\n")

        XCTAssertTrue(lowOpacityConfig.hasParsedBackgroundOpacity)
        XCTAssertEqual(lowOpacityConfig.backgroundOpacity, 0.0, accuracy: 0.0001)
    }

    func testLoadReadsBackgroundFromRecursiveConfigFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-config-recursive-background-\(UUID().uuidString)")
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

        try "background = #123456\nforeground = #abcdef\n".write(
            to: ghosttyConfigDir.appendingPathComponent("appearance.conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "config-file = appearance.conf\n".write(
            to: ghosttyConfigDir.appendingPathComponent("config.ghostty", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let loaded = GhosttyConfig.load(preferredColorScheme: .dark, useCache: false)

        XCTAssertEqual(loaded.backgroundColor.hexString(), "#123456")
        XCTAssertEqual(loaded.foregroundColor.hexString(), "#ABCDEF")
    }

    func testLoadDoesNotReparseTopLevelConfigReferencedByConfigFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-config-top-level-cycle-\(UUID().uuidString)")
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
        let configFile = ghosttyConfigDir.appendingPathComponent("config.ghostty", isDirectory: false)

        try """
        background = #111111
        config-file = \(configFile.path)
        foreground = #222222
        """
        .write(to: configFile, atomically: true, encoding: .utf8)

        let loaded = GhosttyConfig.load(preferredColorScheme: .dark, useCache: false)

        XCTAssertEqual(loaded.backgroundColor.hexString(), "#111111")
        XCTAssertEqual(loaded.foregroundColor.hexString(), "#222222")
    }

    func testLoadAllowsRecursiveConfigFileToReloadTopLevelConfigAsFinalOverride() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-config-top-level-reload-\(UUID().uuidString)")
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
        let legacyConfig = ghosttyConfigDir.appendingPathComponent("config", isDirectory: false)
        try "background = #111111\n".write(to: legacyConfig, atomically: true, encoding: .utf8)
        try """
        background = #222222
        config-file = \(legacyConfig.path)
        """
        .write(
            to: ghosttyConfigDir.appendingPathComponent("config.ghostty", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let loaded = GhosttyConfig.load(preferredColorScheme: .dark, useCache: false)

        XCTAssertEqual(loaded.backgroundColor.hexString(), "#111111")
    }

    func testLoadReadsOptionalQuotedConfigFilePath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-config-optional-quoted-\(UUID().uuidString)")
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

        try "background = #334455\nforeground = #ddeeff\n".write(
            to: ghosttyConfigDir.appendingPathComponent("appearance theme.conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "config-file = ?\"appearance theme.conf\"\n".write(
            to: ghosttyConfigDir.appendingPathComponent("config.ghostty", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let loaded = GhosttyConfig.load(preferredColorScheme: .dark, useCache: false)

        XCTAssertEqual(loaded.backgroundColor.hexString(), "#334455")
        XCTAssertEqual(loaded.foregroundColor.hexString(), "#DDEEFF")
    }

    func testLoadIgnoresLegacyAppSupportConfigWhenConfigGhosttyIsNonEmpty() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-app-support-legacy-skip-\(UUID().uuidString)")
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

        let ghosttyConfigDir = root
            .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty", isDirectory: true)
        try fileManager.createDirectory(at: ghosttyConfigDir, withIntermediateDirectories: true)
        try "background = #112233\n".write(
            to: ghosttyConfigDir.appendingPathComponent("config", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "font-size = 13\n".write(
            to: ghosttyConfigDir.appendingPathComponent("config.ghostty", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let loaded = GhosttyConfig.load(preferredColorScheme: .dark, useCache: false)

        XCTAssertEqual(loaded.fontSize, CGFloat(13), accuracy: 0.0001)
        XCTAssertNotEqual(loaded.backgroundColor.hexString(), "#112233")
    }

    func testLoadUsesLegacyAppSupportConfigWhenConfigGhosttyIsEmpty() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-app-support-legacy-fallback-\(UUID().uuidString)")
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

        let ghosttyConfigDir = root
            .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty", isDirectory: true)
        try fileManager.createDirectory(at: ghosttyConfigDir, withIntermediateDirectories: true)
        try "background = #112233\n".write(
            to: ghosttyConfigDir.appendingPathComponent("config", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: ghosttyConfigDir.appendingPathComponent("config.ghostty", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let loaded = GhosttyConfig.load(preferredColorScheme: .dark, useCache: false)

        XCTAssertEqual(loaded.backgroundColor.hexString(), "#112233")
    }

    func testLoadAppliesThemeBeforeLaterCursorColorOverride() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-theme-order-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesDir = root.appendingPathComponent("resources", isDirectory: true)
        let themesDir = resourcesDir.appendingPathComponent("themes", isDirectory: true)
        let configDir = root.appendingPathComponent(".config/ghostty", isDirectory: true)
        try fileManager.createDirectory(at: themesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)

        let environmentKeys: [String] = ["CFFIXED_USER_HOME", "GHOSTTY_RESOURCES_DIR"]
        let originalEnvironment = environmentKeys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        }
        setenv("CFFIXED_USER_HOME", root.path, 1)
        setenv("GHOSTTY_RESOURCES_DIR", resourcesDir.path, 1)
        defer {
            for (key, value) in originalEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            GhosttyConfig.invalidateLoadCache()
        }

        try "cursor-color = #e0d000\ncursor-text = #000000\n".write(
            to: themesDir.appendingPathComponent("Yellow Cursor"),
            atomically: true,
            encoding: .utf8
        )
        try "theme = Yellow Cursor\ncursor-color = #ffffff\ncursor-text = #111111\n".write(
            to: configDir.appendingPathComponent("config.ghostty"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = GhosttyConfig.load(preferredColorScheme: .dark, useCache: false)
        XCTAssertEqual(rgb255(loaded.cursorColor), RGB(red: 255, green: 255, blue: 255))
        XCTAssertEqual(rgb255(loaded.cursorTextColor), RGB(red: 17, green: 17, blue: 17))
    }

    func testLoadThemeReadsAbsoluteThemeFilePath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-absolute-theme-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let themeFile = root.appendingPathComponent("theme.conf", isDirectory: false)
        try "background = #223344\nforeground = #ddeeff\n".write(
            to: themeFile,
            atomically: true,
            encoding: .utf8
        )

        var config = GhosttyConfig()
        config.loadTheme(
            themeFile.path,
            environment: [:],
            bundleResourceURL: nil,
            preferredColorScheme: .dark
        )

        XCTAssertEqual(config.backgroundColor.hexString(), "#223344")
        XCTAssertEqual(config.foregroundColor.hexString(), "#DDEEFF")
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

    func testParseBackgroundBlurReadsMacOSGlassClear() {
        var config = GhosttyConfig()
        config.parse("background-blur = macos-glass-clear")
        XCTAssertEqual(config.backgroundBlur, .macosGlassClear)
    }

    func testParseBackgroundBlurReadsMacOSGlassRegular() {
        var config = GhosttyConfig()
        config.parse("background-blur = macos-glass-regular")
        XCTAssertEqual(config.backgroundBlur, .macosGlassRegular)
    }

    func testParseBackgroundBlurIgnoresMalformedValues() {
        var config = GhosttyConfig()
        config.parse("""
        background-blur = macos-glass-clear
        background-blur = not-a-blur
        """)
        XCTAssertEqual(config.backgroundBlur, .macosGlassClear)
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

    func testLegacyConfigFallbackDoesNotReloadLegacyFileWhenConfigGhosttyIsMissing() {
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: nil,
                legacyConfigFileSize: 42
            )
        )
    }

    func testLegacyConfigScanPathsIncludeLegacyFileWhenConfigGhosttyIsMissing() {
        XCTAssertTrue(
            GhosttyApp.shouldIncludeLegacyGhosttyConfigInScanPaths(
                newConfigFileSize: nil,
                legacyConfigFileSize: 42
            )
        )
    }

    func testLegacyConfigFallbackSkipsWhenNewFileHasContentsOrLegacyEmpty() {
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

    func testUnparsedAppearanceFallbackIgnoresNativeLegacyBaselineWhenCurrentConfigExists() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-native-legacy-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        try "background = #112233\n"
            .write(to: ghosttyDir.appendingPathComponent("config", isDirectory: false), atomically: true, encoding: .utf8)
        try "background = black\n"
            .write(to: ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false), atomically: true, encoding: .utf8)

        XCTAssertTrue(
            GhosttyApp.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
                appSupportDirectory: appSupport
            )
        )
    }

    func testUnparsedAppearanceDirectiveIsTrackedSeparatelyFromParsedHexColor() {
        var config = GhosttyConfig()

        config.parse("background = black\nforeground = #ddeeff\n")

        XCTAssertTrue(config.hasBackgroundColorDirective)
        XCTAssertFalse(config.hasParsedBackgroundColor)
        XCTAssertTrue(config.hasForegroundColorDirective)
        XCTAssertTrue(config.hasParsedForegroundColor)
        XCTAssertEqual(config.foregroundColor.hexString(), "#DDEEFF")
    }

    func testUnparsedAppearanceFallbackKeepsNativeLegacyBaselineWhenCurrentConfigIsMissingOrEmpty() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-native-legacy-baseline-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        let currentConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        try "background = #112233\n"
            .write(to: ghosttyDir.appendingPathComponent("config", isDirectory: false), atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
                appSupportDirectory: appSupport
            )
        )

        try "".write(to: currentConfig, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
                appSupportDirectory: appSupport
            )
        )
    }

    func testDefaultBackgroundUpdateScopePrioritizesSurfaceOverAppAndUnscoped() {
        let cases: [(GhosttyDefaultBackgroundUpdateScope, GhosttyDefaultBackgroundUpdateScope, Bool)] = [
            (.unscoped, .app, true),
            (.app, .surface, true),
            (.surface, .surface, true),
            (.surface, .app, false),
            (.surface, .unscoped, false),
        ]
        for (currentScope, incomingScope, expected) in cases {
            XCTAssertEqual(
                GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                    currentScope: currentScope,
                    incomingScope: incomingScope
                ),
                expected
            )
        }
    }

    func testAppearanceChangeReloadsWhenColorSchemeChanges() {
        XCTAssertTrue(GhosttyApp.shouldReloadConfigurationForAppearanceChange(previousColorScheme: .dark, currentColorScheme: .light))
        XCTAssertTrue(GhosttyApp.shouldReloadConfigurationForAppearanceChange(previousColorScheme: nil, currentColorScheme: .dark))
    }

    func testAppearanceChangeSkipsReloadWhenColorSchemeUnchanged() {
        XCTAssertFalse(GhosttyApp.shouldReloadConfigurationForAppearanceChange(previousColorScheme: .light, currentColorScheme: .light))
        XCTAssertFalse(GhosttyApp.shouldReloadConfigurationForAppearanceChange(previousColorScheme: .dark, currentColorScheme: .dark))
    }

    func testAppearanceSynchronizationPlanSkipsRuntimeUpdateWhenColorSchemeIsUnchanged() {
        let plan = GhosttyApp.appearanceSynchronizationPlan(
            previousColorScheme: .light,
            currentColorScheme: .light
        )

        switch plan {
        case .unchanged:
            XCTAssertFalse(plan.shouldReloadConfiguration)
        case .reload:
            XCTFail("Unchanged appearance should not produce a reload plan")
        }
    }

    func testAppearanceSynchronizationPlanUpdatesGhosttyRuntimeWhenReloading() {
        let cases: [
            (
                previous: GhosttyConfig.ColorSchemePreference?,
                current: GhosttyConfig.ColorSchemePreference,
                runtime: ghostty_color_scheme_e
            )
        ] = [
            (nil, .dark, GHOSTTY_COLOR_SCHEME_DARK),
            (.dark, .light, GHOSTTY_COLOR_SCHEME_LIGHT),
            (.light, .dark, GHOSTTY_COLOR_SCHEME_DARK),
        ]

        for testCase in cases {
            let plan = GhosttyApp.appearanceSynchronizationPlan(
                previousColorScheme: testCase.previous,
                currentColorScheme: testCase.current
            )

            switch plan {
            case .unchanged:
                XCTFail("Changed appearance should produce a reload plan")
            case let .reload(colorScheme, runtimeColorScheme):
                XCTAssertEqual(colorScheme, testCase.current)
                XCTAssertEqual(runtimeColorScheme, testCase.runtime)
                XCTAssertTrue(plan.shouldReloadConfiguration)
            }
        }
    }

    func testTerminalRuntimeColorSchemeFollowsResolvedThemeBackground() {
        XCTAssertEqual(
            GhosttyApp.terminalRuntimeColorSchemePreference(
                forBackgroundColor: NSColor(hex: "#F7F7F7")!
            ),
            .light
        )
        XCTAssertEqual(
            GhosttyApp.terminalRuntimeColorSchemePreference(
                forBackgroundColor: NSColor(hex: "#090300")!
            ),
            .dark
        )
    }

    func testRuntimeColorSchemeSynchronizationDecisionOnlySkipsReentrantCalls() {
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeSynchronizationDecision(
                applied: nil,
                requested: GHOSTTY_COLOR_SCHEME_DARK,
                isSynchronizing: false
            ),
            .apply
        )
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeSynchronizationDecision(
                applied: GHOSTTY_COLOR_SCHEME_DARK,
                requested: GHOSTTY_COLOR_SCHEME_DARK,
                isSynchronizing: false
            ),
            .apply
        )
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeSynchronizationDecision(
                applied: GHOSTTY_COLOR_SCHEME_LIGHT,
                requested: GHOSTTY_COLOR_SCHEME_DARK,
                isSynchronizing: true
            ),
            .skipReentrant
        )
    }

    func testRuntimeColorSchemeForCmuxSingleThemeReloadKeepsResolvedSchemeDuringConfigLoad() {
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeForConfigLoad(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadFinalSource,
                requestedColorScheme: .dark,
                effectiveTerminalColorScheme: .light,
                cmuxThemeValue: "light:3024 Day,dark:3024 Day"
            ),
            .light
        )
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeForConfigLoad(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource,
                requestedColorScheme: .dark,
                effectiveTerminalColorScheme: .light,
                cmuxThemeValue: "3024 Day"
            ),
            .light
        )
    }

    func testRuntimeColorSchemeForPairedThemeReloadUsesAppearanceDuringConfigLoad() {
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeForConfigLoad(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadFinalSource,
                requestedColorScheme: .dark,
                effectiveTerminalColorScheme: .light,
                cmuxThemeValue: "light:3024 Day,dark:3024 Night"
            ),
            .dark
        )
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeForConfigLoad(
                source: "socket.reload_config",
                requestedColorScheme: .dark,
                effectiveTerminalColorScheme: .light,
                cmuxThemeValue: "light:3024 Day,dark:3024 Day"
            ),
            .dark
        )
    }

    func testScrollLagCaptureRequiresSustainedLag() {
        let cases: [(samples: Int, averageMs: Double, maxMs: Double, expected: Bool)] = [
            (4, 18, 85, false),
            (10, 6, 85, false),
            (10, 18, 35, false),
            (10, 18, 85, true),
        ]
        for testCase in cases {
            XCTAssertEqual(
                GhosttyApp.shouldCaptureScrollLagEvent(
                    samples: testCase.samples,
                    averageMs: testCase.averageMs,
                    maxMs: testCase.maxMs,
                    thresholdMs: 40,
                    nowUptime: 1000,
                    lastReportedUptime: nil
                ),
                testCase.expected
            )
        }
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

        defaults.removeObject(forKey: IntegrationsCatalogSection().claudeCodeHooksEnabled.userDefaultsKey)
        XCTAssertTrue(AgentIntegrationSettingsStore(defaults: defaults).claudeCodeHooksEnabled)
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

        defaults.set(true, forKey: IntegrationsCatalogSection().claudeCodeHooksEnabled.userDefaultsKey)
        XCTAssertTrue(AgentIntegrationSettingsStore(defaults: defaults).claudeCodeHooksEnabled)

        defaults.set(false, forKey: IntegrationsCatalogSection().claudeCodeHooksEnabled.userDefaultsKey)
        XCTAssertFalse(AgentIntegrationSettingsStore(defaults: defaults).claudeCodeHooksEnabled)
    }

    func testKiroIntegrationDefaultsToEnabledWithStandardNotificationsWhenUnset() {
        let suiteName = "cmux.tests.kiro-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: IntegrationsCatalogSection().kiroHooksEnabled.userDefaultsKey)
        defaults.removeObject(forKey: IntegrationsCatalogSection().kiroNotificationLevel.userDefaultsKey)
        XCTAssertTrue(AgentIntegrationSettingsStore(defaults: defaults).kiroHooksEnabled)
        XCTAssertEqual(AgentIntegrationSettingsStore(defaults: defaults).kiroNotificationLevel, .standard)
    }

    func testKiroIntegrationRespectsStoredPreferenceAndNotificationLevel() {
        let suiteName = "cmux.tests.kiro-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: IntegrationsCatalogSection().kiroHooksEnabled.userDefaultsKey)
        defaults.set(KiroNotificationLevel.verbose.rawValue, forKey: IntegrationsCatalogSection().kiroNotificationLevel.userDefaultsKey)
        XCTAssertFalse(AgentIntegrationSettingsStore(defaults: defaults).kiroHooksEnabled)
        XCTAssertEqual(AgentIntegrationSettingsStore(defaults: defaults).kiroNotificationLevel, .verbose)

        defaults.set("unsupported", forKey: IntegrationsCatalogSection().kiroNotificationLevel.userDefaultsKey)
        XCTAssertEqual(AgentIntegrationSettingsStore(defaults: defaults).kiroNotificationLevel, .standard)
    }

    func testSubagentNotificationSuppressionDefaultsToEnabledWhenUnset() {
        let suiteName = "cmux.tests.subagent-notifications.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
        XCTAssertTrue(AgentIntegrationSettingsStore(defaults: defaults).suppressesSubagentNotifications)
    }

    func testSubagentNotificationSuppressionRespectsStoredPreference() {
        let suiteName = "cmux.tests.subagent-notifications.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
        XCTAssertTrue(AgentIntegrationSettingsStore(defaults: defaults).suppressesSubagentNotifications)

        defaults.set(false, forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
        XCTAssertFalse(AgentIntegrationSettingsStore(defaults: defaults).suppressesSubagentNotifications)
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

        let telemetry = AppCatalogSection().sendAnonymousTelemetry
        defaults.removeObject(forKey: telemetry.userDefaultsKey)
        XCTAssertTrue(telemetry.value(in: defaults))
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

        let telemetry = AppCatalogSection().sendAnonymousTelemetry
        defaults.set(true, forKey: telemetry.userDefaultsKey)
        XCTAssertTrue(telemetry.value(in: defaults))

        defaults.set(false, forKey: telemetry.userDefaultsKey)
        XCTAssertFalse(telemetry.value(in: defaults))
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

    private struct CLIResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func runCLI(
        _ cliPath: String,
        arguments: [String],
        environment overrides: [String: String],
        timeout: TimeInterval
    ) -> CLIResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            environment[key] = value
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return CLIResult(status: -1, output: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CLIResult(status: process.terminationStatus, output: output, timedOut: timedOut)
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
        XCTAssertEqual(colors.tabBarBackgroundHex, "#FDF6E3")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#FDF6E3")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
        XCTAssertEqual(colors.borderHex, "#DED7C442")
    }

    func testResolvedChromeColorsUsesDarkGhosttyBackground() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(from: backgroundColor)
        XCTAssertEqual(colors.backgroundHex, "#272822")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#272822")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#272822")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
        XCTAssertEqual(colors.borderHex, "#4F504A5B")
    }

    func testResolvedChromeColorsKeepSemanticBackgroundButClearLocalBackdropsWhenSharingWindowBackdrop() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(
            from: backgroundColor,
            sharesWindowBackdrop: true
        )
        XCTAssertEqual(colors.backgroundHex, "#272822")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#00000000")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#00000000")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
        XCTAssertEqual(colors.borderHex, "#4F504A5B")
    }

    func testResolvedChromeColorsKeepPaneClearForRendererOwnedBackgrounds() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(
            from: backgroundColor,
            renderingMode: .ghosttyRendererOwnedBackgroundImage
        )
        XCTAssertEqual(colors.backgroundHex, "#272822")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#272822")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#272822")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
        XCTAssertEqual(colors.borderHex, "#4F504A5B")
    }
}

final class WindowChromeSeparatorColorTests: XCTestCase {
    func testDarkChromeSeparatorMatchesBonsplitDerivation() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let color = WindowChromeSeparatorColor.color(forChromeBackground: backgroundColor)
        let rgba = rgbaComponents(color)

        XCTAssertEqual(rgba.red, CGFloat(39.0 / 255.0) + CGFloat(0.16), accuracy: 0.0001)
        XCTAssertEqual(rgba.green, CGFloat(40.0 / 255.0) + CGFloat(0.16), accuracy: 0.0001)
        XCTAssertEqual(rgba.blue, CGFloat(34.0 / 255.0) + CGFloat(0.16), accuracy: 0.0001)
        XCTAssertEqual(rgba.alpha, CGFloat(0.36), accuracy: 0.0001)
    }

    func testLightChromeSeparatorMatchesBonsplitDerivation() {
        guard let backgroundColor = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test color")
            return
        }

        let color = WindowChromeSeparatorColor.color(forChromeBackground: backgroundColor)
        let rgba = rgbaComponents(color)

        XCTAssertEqual(rgba.red, CGFloat(253.0 / 255.0) - CGFloat(0.12), accuracy: 0.0001)
        XCTAssertEqual(rgba.green, CGFloat(246.0 / 255.0) - CGFloat(0.12), accuracy: 0.0001)
        XCTAssertEqual(rgba.blue, CGFloat(227.0 / 255.0) - CGFloat(0.12), accuracy: 0.0001)
        XCTAssertEqual(rgba.alpha, CGFloat(0.26), accuracy: 0.0001)
    }

    private func rgbaComponents(_ color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
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

    func testBonsplitChromeHexKeepsBackdropWhenSharingWindowBackdrop() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let hex = Workspace.bonsplitChromeHex(
            backgroundColor: color,
            backgroundOpacity: 0.5,
            sharesWindowBackdrop: true
        )
        XCTAssertEqual(hex, "#1122337F")
    }

    func testBonsplitChromeColorsKeepPaneClearWhenTerminalUsesHostLayerBackground() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let colors = Workspace.bonsplitChromeColors(
            backgroundColor: color,
            backgroundOpacity: 0.5,
            renderingMode: .windowHostBackdrop
        )

        XCTAssertEqual(colors.backgroundHex, "#1122337F")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#1122337F")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#1122337F")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
    }

    func testBonsplitChromeColorsKeepSemanticBackgroundButClearLocalBackdropsWhenSharingWindowBackdrop() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let colors = Workspace.bonsplitChromeColors(
            backgroundColor: color,
            backgroundOpacity: 0.5,
            sharesWindowBackdrop: true,
            renderingMode: .windowHostBackdrop
        )

        XCTAssertEqual(colors.backgroundHex, "#1122337F")
        XCTAssertEqual(colors.tabBarBackgroundHex, "#00000000")
        XCTAssertEqual(colors.splitButtonBackdropHex, "#00000000")
        XCTAssertEqual(colors.paneBackgroundHex, "#00000000")
    }
}

// WindowTransparencyDecisionTests was deleted: its subjects (the free functions
// cmuxShouldUseTransparentBackgroundWindow / cmuxShouldUseClearWindowBackground /
// cmuxShouldApplyWindowGlass) were lifted out of the app target into
// CmuxWorkspaceWindow's WindowBackgroundPolicy by the window-chrome tranche, and
// equivalent coverage now lives in
// Packages/CmuxWorkspaceWindow/Tests/CmuxWorkspaceWindowTests/WindowBackgroundPolicyTests.swift.
// The stale app-side test was left referencing the removed symbols, which broke
// the cmuxTests compile on the Swift 6 depot toolchain.

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

        let manifest = WorkspaceRemoteDaemonManifest(infoDictionary: [
            WorkspaceRemoteDaemonManifest.infoDictionaryKey: manifestJSON,
        ])

        XCTAssertEqual(manifest?.releaseTag, "v0.62.0")
        XCTAssertEqual(manifest?.entry(goOS: "linux", goArch: "amd64")?.assetName, "cmuxd-remote-linux-amd64")
    }

    func testRemoteDaemonCachePathIsVersionedByPlatform() throws {
        let repository = RemoteDaemonManifestRepository(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let url = try repository.cachedBinaryURL(
            version: "0.62.0",
            goOS: "linux",
            goArch: "arm64"
        )

        XCTAssertTrue(url.path.contains("/.local/state/cmux/remote-daemons/0.62.0/linux-arm64/"))
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

    func testRewritesLoopbackSubdomainAliasHostHeadersToOriginalLocalhostSubdomain() {
        let original = Data(
            (
                "GET /demo HTTP/1.1\r\n" +
                "Host: api.cmux-loopback.localtest.me:3000\r\n" +
                "Origin: http://api.cmux-loopback.localtest.me:3000\r\n" +
                "Referer: http://api.cmux-loopback.localtest.me:3000/app\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Host: api.localhost:3000"))
        XCTAssertTrue(text.contains("Origin: http://api.localhost:3000"))
        XCTAssertTrue(text.contains("Referer: http://api.localhost:3000/app"))
        XCTAssertFalse(text.contains("api.cmux-loopback.localtest.me"))
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

    func testRewritesLoopbackSubdomainResponseHeadersBackToAliasSubdomain() {
        let original = Data(
            (
                "HTTP/1.1 302 Found\r\n" +
                "Location: http://api.localhost:3000/login\r\n" +
                "Access-Control-Allow-Origin: http://api.localhost:3000\r\n" +
                "Set-Cookie: sid=1; Domain=api.localhost; Path=/\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Location: http://api.cmux-loopback.localtest.me:3000/login"))
        XCTAssertTrue(text.contains("Access-Control-Allow-Origin: http://api.cmux-loopback.localtest.me:3000"))
        XCTAssertTrue(text.contains("Set-Cookie: sid=1; Domain=api.cmux-loopback.localtest.me; Path=/"))
    }

    func testRewritesLeadingDotLoopbackCookieDomainsBackToAliasDomains() {
        let original = Data(
            (
                "HTTP/1.1 200 OK\r\n" +
                "Set-Cookie: root=1; Domain=.localhost; Path=/\r\n" +
                "Set-Cookie: api=1; Domain=.api.localhost; Path=/\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Set-Cookie: root=1; Domain=.cmux-loopback.localtest.me; Path=/"))
        XCTAssertTrue(text.contains("Set-Cookie: api=1; Domain=.api.cmux-loopback.localtest.me; Path=/"))
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
final class BrowserPanelWebViewLifecycleTests: XCTestCase {
    func testHiddenDiscardPolicyReadsUserDefaults() throws {
        let suiteName = "cmux.browserHiddenDiscardPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let hasEnabledEnvironmentOverride =
            ProcessInfo.processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_ENABLED"] != nil
        let hasDelayEnvironmentOverride =
            ProcessInfo.processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_DELAY_SECONDS"] != nil

        if !hasEnabledEnvironmentOverride {
            XCTAssertEqual(
                BrowserHiddenWebViewDiscardPolicy.isEnabled(defaults: defaults),
                BrowserHiddenWebViewDiscardPolicy.defaultEnabled
            )
        }
        if !hasDelayEnvironmentOverride {
            XCTAssertEqual(
                BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: defaults),
                BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay
            )
        }

        defaults.set(false, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.set(42.5, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)

        if !hasEnabledEnvironmentOverride {
            XCTAssertEqual(defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey) as? Bool, false)
            XCTAssertFalse(BrowserHiddenWebViewDiscardPolicy.isEnabled(defaults: defaults))
        }
        if !hasDelayEnvironmentOverride {
            XCTAssertEqual(BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: defaults), 42.5)

            defaults.set(7200, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            XCTAssertEqual(
                BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: defaults),
                BrowserHiddenWebViewDiscardPolicy.maximumHiddenDelay
            )

            defaults.set(-1, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            XCTAssertEqual(
                BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: defaults),
                BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay
            )
        }
    }

    func testLifecycleDistinguishesDeferredURLFromNewTab() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.test/")!,
            renderInitialNavigation: false,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertEqual(panel.webViewLifecycleState, .deferredURL)

        panel.noteWebViewVisibility(true, reason: "test.visible")

        XCTAssertEqual(panel.webViewLifecycleState, .deferredURL)
    }

    func testBackgroundInitialNavigationOwnsHeadlessWebKitHostBeforeViewAppears() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertTrue(panel.shouldRenderWebView)
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
        XCTAssertTrue(panel.hasBackgroundPreloadHost)
        XCTAssertNotNil(panel.webView.window)
        XCTAssertEqual(panel.webView.window?.isVisible, true)
        XCTAssertLessThan(panel.webView.window?.frame.minX ?? 0, -9_000)
    }

    func testBackgroundInitialNavigationDoesNotExposeHiddenHostAsModalParent() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertTrue(panel.hasBackgroundPreloadHost)
        XCTAssertNotNil(panel.webView.window)
        XCTAssertNil(browserInteractiveModalHostWindow(for: panel.webView))
    }

    func testBackgroundPreloadHostStaysOpenUntilWebViewHasRealWindow() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertTrue(panel.hasBackgroundPreloadHost)
        panel.webView.removeFromSuperview()

        XCTAssertNil(panel.webView.window)

        panel.releaseBackgroundPreloadHostIfAttachedToRealWindow(reason: "test.detached")

        XCTAssertTrue(panel.hasBackgroundPreloadHost)
    }

    func testBackgroundPreloadIsConsumedByInitialNavigation() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertTrue(panel.hasBackgroundPreloadHost)

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let realHostWindow = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer {
            realHostWindow.contentView = nil
            realHostWindow.close()
        }
        let contentView = NSView(frame: frame)
        realHostWindow.contentView = contentView
        panel.webView.removeFromSuperview()
        contentView.addSubview(panel.webView)

        panel.releaseBackgroundPreloadHostIfAttachedToRealWindow(reason: "test.realWindow")

        XCTAssertFalse(panel.hasBackgroundPreloadHost)

        panel.webView.removeFromSuperview()
        realHostWindow.contentView = nil
        panel.navigate(to: URL(string: "about:blank#second")!)

        XCTAssertFalse(panel.hasBackgroundPreloadHost)
    }

    func testLifecycleTracksVisibleHiddenAndClosingStates() {
        let hiddenAt = Date(timeIntervalSince1970: 100)
        let duplicateHiddenAt = hiddenAt.addingTimeInterval(10)
        let now = hiddenAt.addingTimeInterval(11.25)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.test/")!,
            isRemoteWorkspace: false
        )

        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)

        panel.noteWebViewVisibility(true, reason: "test.visible", now: hiddenAt)
        XCTAssertEqual(panel.webViewLifecycleState, .liveVisible)

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: hiddenAt)
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
        panel.noteWebViewVisibility(
            false,
            reason: "test.hidden.duplicate",
            now: duplicateHiddenAt,
            recordIfUnchanged: true
        )

        let payload = panel.webViewLifecycleTopPayload(now: now)
        XCTAssertEqual(payload["state"] as? String, "live_hidden")
        XCTAssertEqual(payload["visible_in_ui"] as? Bool, false)
        XCTAssertEqual(payload["should_render"] as? Bool, true)
        XCTAssertEqual(payload["last_visibility_change_reason"] as? String, "test.hidden")
        XCTAssertEqual(payload["hidden_duration_ms"] as? Int, 11250)

        panel.close()
        XCTAssertEqual(panel.webViewLifecycleState, .closing)
    }

    func testDiscardReplacesHiddenWebViewAndRestoresOnDemand() {
        let discardedAt = Date(timeIntervalSince1970: 200)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.isLoading,
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        let originalWebView = panel.webView

        XCTAssertTrue(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        XCTAssertFalse(panel.webView === originalWebView)
        XCTAssertFalse(panel.shouldRenderWebView)
        XCTAssertEqual(panel.webViewLifecycleState, .discarded)

        let discardedPayload = panel.webViewLifecycleTopPayload(now: discardedAt)
        XCTAssertEqual(discardedPayload["state"] as? String, "discarded")
        XCTAssertEqual(discardedPayload["last_discard_reason"] as? String, "test.discard")
        XCTAssertNotNil(discardedPayload["discarded_at"] as? String)

        var observedStates: [BrowserWebViewLifecycleState] = []
        var cancellable: AnyCancellable?
        cancellable = panel.$webViewLifecycleState.sink { state in
            observedStates.append(state)
        }
        defer { cancellable?.cancel() }

        XCTAssertTrue(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore"))
        XCTAssertTrue(panel.shouldRenderWebView)
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
        XCTAssertFalse(observedStates.contains(.newTab), "Restore emitted unexpected states: \(observedStates)")

        panel.noteWebViewVisibility(true, reason: "test.visible")
        XCTAssertEqual(panel.webViewLifecycleState, .liveVisible)
    }

    /// Regression guard for the issue #5303 render loop: `BrowserPanelView.onAppear`
    /// re-fired on every CoreAnimation commit and re-asserted webview visibility,
    /// which restored + re-navigated the webview repeatedly. Once the webview is live
    /// and visible, redundant visibility notifications (the shape a spurious appear
    /// produces) must be no-ops: no lifecycle churn and no webview replacement, so no
    /// re-navigation is issued.
    func testRedundantVisibleNotificationsDoNotChurnLiveWebView() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.isLoading,
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")

        panel.noteWebViewVisibility(true, reason: "test.visible.first")
        XCTAssertEqual(panel.webViewLifecycleState, .liveVisible)

        let webViewAfterFirst = panel.webView
        let instanceIDAfterFirst = panel.webViewInstanceID
        let reasonAfterFirst = panel.webViewLastVisibilityChangeReason
        let changeAtAfterFirst = panel.webViewLastVisibilityChangeAt

        var observedStates: [BrowserWebViewLifecycleState] = []
        var cancellable: AnyCancellable?
        cancellable = panel.$webViewLifecycleState.dropFirst().sink { state in
            observedStates.append(state)
        }
        defer { cancellable?.cancel() }

        // Simulate `.onAppear` re-firing many times in one commit storm.
        for index in 0..<32 {
            panel.noteWebViewVisibility(true, reason: "test.visible.spurious-\(index)")
        }

        XCTAssertEqual(panel.webViewLifecycleState, .liveVisible)
        XCTAssertTrue(observedStates.isEmpty, "Redundant visible notes churned lifecycle: \(observedStates)")
        XCTAssertTrue(panel.webView === webViewAfterFirst, "A live webview must not be replaced by redundant visibility notes")
        XCTAssertEqual(panel.webViewInstanceID, instanceIDAfterFirst)
        XCTAssertEqual(
            panel.webViewLastVisibilityChangeReason,
            reasonAfterFirst,
            "Redundant visible notes must early-return without recording a new transition"
        )
        XCTAssertEqual(panel.webViewLastVisibilityChangeAt, changeAtAfterFirst)
    }

    func testRestoredHistoryBackDoesNotEmitNewTabLifecycleState() {
        let discardedAt = Date(timeIntervalSince1970: 300)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.isLoading,
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: ["https://example.test/back"],
            forwardHistoryURLStrings: [],
            currentURLString: "https://example.test/current"
        )
        XCTAssertTrue(panel.canGoBack)

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        XCTAssertTrue(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        XCTAssertEqual(panel.webViewLifecycleState, .discarded)

        var observedStates: [BrowserWebViewLifecycleState] = []
        var cancellable: AnyCancellable?
        cancellable = panel.$webViewLifecycleState.sink { state in
            observedStates.append(state)
        }
        defer { cancellable?.cancel() }

        panel.goBack()

        XCTAssertFalse(observedStates.contains(.newTab), "Back restore emitted unexpected states: \(observedStates)")
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
    }
}

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
        XCTAssertEqual(defaults.string(forKey: BrowserSearchSettingsStore.searchEngineKey), BrowserSearchSettingsStore.defaultSearchEngine.rawValue)
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

final class BrowserNewTabNavigationSeedTests: XCTestCase {
    func testPreservesOriginalRequestHeadersMethodBodyAndBypassHost() throws {
        let url = try XCTUnwrap(URL(string: "https://www.linkedin.com/redir/redirect?url=https%3A%2F%2Fexample.com"))
        let body = Data("payload=1".utf8)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("https://www.linkedin.com/feed/", forHTTPHeaderField: "Referer")
        request.setValue("keep-me", forHTTPHeaderField: "X-Cmux-Test")

        let seed = try XCTUnwrap(
            browserNewTabNavigationSeed(
                from: request,
                bypassInsecureHTTPHostOnce: "www.linkedin.com"
            )
        )

        // This covers the pure seeding helper only. WebKit may still rewrite
        // programmatic loads when the request is replayed in the destination tab.
        XCTAssertEqual(seed.url, url)
        XCTAssertEqual(seed.bypassInsecureHTTPHostOnce, "www.linkedin.com")
        XCTAssertEqual(seed.initialRequest.httpMethod, "POST")
        XCTAssertEqual(seed.initialRequest.httpBody, body)
        XCTAssertEqual(
            seed.initialRequest.value(forHTTPHeaderField: "Referer"),
            "https://www.linkedin.com/feed/"
        )
        XCTAssertEqual(
            seed.initialRequest.value(forHTTPHeaderField: "X-Cmux-Test"),
            "keep-me"
        )
        XCTAssertEqual(seed.initialRequest.cachePolicy, .reloadIgnoringLocalCacheData)
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

    func testRemoteWorkspacePreservesLocalhostSubdomainWhenAliasingLoopbackURL() {
        let remoteWorkspaceId = UUID()
        let url = URL(string: "http://api.localhost:3000/demo")!
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
        XCTAssertEqual(panel.webView.url?.host, "api.cmux-loopback.localtest.me")
    }

    func testRemoteWorkspaceRuntimeBridgeAliasesMultipleLoopbackPortsFromSamePage() async throws {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        let baseURL = try XCTUnwrap(URL(string: "http://cmux-loopback.localtest.me:3000/"))

        panel.webView.loadHTMLString(
            "<!doctype html><html><body>remote loopback bridge</body></html>",
            baseURL: baseURL
        )
        try await waitForBrowserWebViewLoad(panel.webView)

        let result = try await panel.evaluateJavaScript(
            """
            (() => {
              const rewrite = window.__cmuxRewriteRemoteLoopbackURL;
              if (typeof rewrite !== 'function') {
                return 'missing bridge';
              }
              return JSON.stringify([
                rewrite('http://localhost:3000/frontend'),
                rewrite('http://localhost:8000/api'),
                rewrite('http://api.localhost:8000/v1'),
                rewrite('ws://localhost:5173/hmr'),
                rewrite('wss://localhost:5173/hmr'),
                rewrite('https://localhost:9443/secure')
              ]);
            })()
            """
        ) as? String

        XCTAssertEqual(
            result,
            #"["http://cmux-loopback.localtest.me:3000/frontend","http://cmux-loopback.localtest.me:8000/api","http://api.cmux-loopback.localtest.me:8000/v1","ws://cmux-loopback.localtest.me:5173/hmr","wss://localhost:5173/hmr","https://localhost:9443/secure"]"#
        )
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

    private func waitForBrowserWebViewLoad(_ webView: WKWebView, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while webView.isLoading {
            if Date() >= deadline {
                XCTFail("Timed out waiting for browser web view to finish loading")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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

    func testProxyBrokerTransportKeyIgnoresEphemeralAgentSocketPath() {
        let first = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "ForwardAgent=yes",
                "ControlMaster=auto",
            ],
            localProxyPort: 9000,
            relayPort: 64000,
            relayID: "relay-a",
            relayToken: "token-a",
            localSocketPath: "/tmp/cmux-a.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            agentSocketPath: "/tmp/cmux-agent-a.sock"
        )
        let second = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "ForwardAgent=yes",
                "ControlMaster=auto",
            ],
            localProxyPort: 9000,
            relayPort: 64000,
            relayID: "relay-b",
            relayToken: "token-b",
            localSocketPath: "/tmp/cmux-b.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            agentSocketPath: "/tmp/cmux-agent-b.sock"
        )

        XCTAssertEqual(first.proxyBrokerTransportKey, second.proxyBrokerTransportKey)
    }

    func testPersistentPTYIdentityRequiresSameRelayPort() {
        let first = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "Compression=yes",
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-64000-%C",
            ],
            localProxyPort: nil,
            relayPort: 64000,
            relayID: "relay-a",
            relayToken: "token-a",
            localSocketPath: "/tmp/cmux-a.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test-slot"
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
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-b",
            relayToken: "token-b",
            localSocketPath: "/tmp/cmux-b.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test-slot"
        )

        XCTAssertFalse(first.hasSamePersistentPTYIdentity(as: second))
        XCTAssertFalse(second.hasSamePersistentPTYIdentity(as: first))
    }

    func testPersistentPTYIdentityIgnoresEphemeralAgentSocketPath() {
        let first = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "ForwardAgent=yes",
                "ControlMaster=auto",
            ],
            localProxyPort: nil,
            relayPort: 64000,
            relayID: "relay-a",
            relayToken: "token-a",
            localSocketPath: "/tmp/cmux-a.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            agentSocketPath: "/tmp/cmux-agent-a.sock",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test-slot"
        )
        let second = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "ForwardAgent=yes",
                "ControlMaster=auto",
            ],
            localProxyPort: nil,
            relayPort: 64000,
            relayID: "relay-b",
            relayToken: "token-b",
            localSocketPath: "/tmp/cmux-b.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            agentSocketPath: "/tmp/cmux-agent-b.sock",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test-slot"
        )

        XCTAssertTrue(first.hasSamePersistentPTYIdentity(as: second))
        XCTAssertTrue(second.hasSamePersistentPTYIdentity(as: first))
    }
}

final class WorkspaceRemoteSSHCleanupTests: XCTestCase {
    func testOrphanedCMUXRemoteSSHPIDsMatchesOnlyParentOneRelayAndDaemonTransports() {
        let psOutput = """
          101 1 /usr/bin/ssh -N -T -S none -o ControlPath=/tmp/cmux-ssh-501-56080-%C -R 127.0.0.1:56080:127.0.0.1:64048 cmux-macmini
          102 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
          107 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-test''
          103 999 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56081:127.0.0.1:64049 cmux-macmini
          104 1 /usr/bin/ssh -tt cmux-macmini
          105 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56082:127.0.0.1:64050 other-host
          106 1 /usr/bin/ssh -T -S none cmux-macmini /bin/sh
        """

        XCTAssertEqual(
            RemoteSessionCoordinator.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini"
            ),
            [101, 102, 107]
        )
    }

    func testOrphanedCMUXRemoteSSHPIDsCanRestrictCleanupToSpecificRelayPort() {
        let psOutput = """
          201 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56080:127.0.0.1:64048 cmux-macmini
          202 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56081:127.0.0.1:64049 cmux-macmini
          203 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
          204 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-test''
          205 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-other''
        """

        XCTAssertEqual(
            RemoteSessionCoordinator.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                relayPort: 56081,
                persistentDaemonSlot: "ssh-test"
            ),
            [202, 204]
        )

        XCTAssertEqual(
            RemoteSessionCoordinator.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                relayPort: 56081
            ),
            [202]
        )
    }

    func testOrphanedCMUXRemoteSSHPIDsMatchesBackslashEscapedPersistentDaemonSlot() {
        let psOutput = """
          211 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec '\''.cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote'\'' '\''serve'\'' '\''--stdio'\'' '\''--persistent'\'' '\''--slot'\'' '\''ssh-test'\'''
          212 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec '\''.cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote'\'' '\''serve'\'' '\''--stdio'\'' '\''--persistent'\'' '\''--slot'\'' '\''ssh-other'\'''
        """

        XCTAssertEqual(
            RemoteSessionCoordinator.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                relayPort: 56081,
                persistentDaemonSlot: "ssh-test"
            ),
            [211]
        )
    }

    func testOrphanedCMUXRemoteSSHPIDsMatchesEqualsQuotedPersistentDaemonSlot() {
        let psOutput = """
          221 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote serve --stdio --persistent --slot='ssh-test''
          222 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote serve --stdio --persistent --slot="ssh-other"'
        """

        XCTAssertEqual(
            RemoteSessionCoordinator.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                relayPort: 56081,
                persistentDaemonSlot: "ssh-test"
            ),
            [221]
        )
    }

    func testOrphanedCMUXRemoteSSHPIDsWithSlotAndNoRelayKeepsGenericCleanup() {
        let psOutput = """
          301 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56080:127.0.0.1:64048 cmux-macmini
          302 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
          303 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-test''
          304 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-other''
          305 1 /usr/bin/ssh -T -S none -o RequestTTY=no other-host sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
        """

        XCTAssertEqual(
            RemoteSessionCoordinator.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                persistentDaemonSlot: "ssh-test"
            ),
            [301, 302, 303]
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
        let registry = RemoteDaemonPendingCallRegistry()
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
        let registry = RemoteDaemonPendingCallRegistry()
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

final class RecentlyClosedBrowserStackTests: XCTestCase {
    func testPopReturnsEntriesInLIFOOrder() {
        var stack = RecentlyClosedBrowserStack<ClosedBrowserPanelRestoreSnapshot>(capacity: 20)
        stack.push(makeSnapshot(index: 1))
        stack.push(makeSnapshot(index: 2))
        stack.push(makeSnapshot(index: 3))

        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 2)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 1)
        XCTAssertNil(stack.pop())
    }

    func testPushDropsOldestEntriesWhenCapacityExceeded() {
        var stack = RecentlyClosedBrowserStack<ClosedBrowserPanelRestoreSnapshot>(capacity: 3)
        for index in 1...5 {
            stack.push(makeSnapshot(index: index))
        }

        XCTAssertEqual(stack.pop()?.originalTabIndex, 5)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 4)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertNil(stack.pop())
    }

    func testRemoveSnapshotsDropsOnlyEntriesForGivenWorkspaceId() {
        let workspaceA = UUID()
        let workspaceB = UUID()
        var stack = RecentlyClosedBrowserStack<ClosedBrowserPanelRestoreSnapshot>(capacity: 20)
        stack.push(makeSnapshot(index: 1, workspaceId: workspaceA))
        stack.push(makeSnapshot(index: 2, workspaceId: workspaceB))
        stack.push(makeSnapshot(index: 3, workspaceId: workspaceA))
        stack.push(makeSnapshot(index: 4, workspaceId: workspaceB))

        stack.removeSnapshots(forWorkspaceId: workspaceA)

        XCTAssertEqual(stack.pop()?.originalTabIndex, 4)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 2)
        XCTAssertNil(stack.pop())
    }

    private func makeSnapshot(index: Int, workspaceId: UUID = UUID()) -> ClosedBrowserPanelRestoreSnapshot {
        ClosedBrowserPanelRestoreSnapshot(
            workspaceId: workspaceId,
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
                "CMUX_TAG": "stray-tag",
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }

    func testTaggedDebugLaunchUsesTagDefaultWhenNoOverrideIsProvided() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_TAG": "my-tag",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug",
            isDebugBuild: true
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-my-tag.sock")
    }

    func testTaggedDebugLaunchStillHonorsSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_TAG": "my-tag",
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-forced.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug",
            isDebugBuild: true
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-forced.sock")
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

    func testTaggedDebugBundleKeepsMatchingSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-my-tag.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.my-tag",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-my-tag.sock")
    }

    func testTaggedDebugBundleIgnoresSocketOverrideInheritedFromDifferentCmuxBundle() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
                "CMUX_SOCKET_PATH": "/tmp/cmux-nightly.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.issue.4355.cmux.themes.set.state.dependent",
            isDebugBuild: true
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-issue-4355-cmux-themes-set-state-dependent.sock")
    }

    func testTaggedDebugBundleIgnoresMismatchedInheritedSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-nightly.sock",
                "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.fix-grok-notifications",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-fix-grok-notifications.sock")
    }

    func testTaggedDebugBundleCanOptInToMismatchedSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-nightly.sock",
                "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.fix-grok-notifications",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-nightly.sock")
    }

    func testTaggedDebugBundleRefusesStableSocketOverrideEvenWithOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": SocketControlSettings.stableDefaultSocketPath,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock")
    }

    func testTaggedDebugBundleRefusesUserScopedStableSocketOverrideEvenWithOptInFlag() {
        let aliases = [
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501),
            SocketControlSettings.legacyUserScopedStableSocketPath(currentUserID: 501),
            "/private/tmp/cmux-501.sock",
        ]

        for alias in aliases {
            let path = SocketControlSettings.socketPath(
                environment: [
                    "CMUX_SOCKET_PATH": alias,
                    "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                ],
                bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
                isDebugBuild: false,
                currentUserID: 501
            )

            XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock", alias)
        }
    }

    func testTaggedDebugBundleRefusesCanonicalLegacyStableSocketAliasEvenWithOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/private/tmp/cmux.sock",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock")
    }

    func testSocketPathMatchingTreatsPrivateTmpLegacyStableAliasAsSamePath() {
        XCTAssertTrue(
            SocketControlSettings.pathsMatch(
                SocketControlSettings.legacyStableDefaultSocketPath,
                "/private/tmp/cmux.sock"
            )
        )
    }

    func testTaggedDebugBundleRefusesCaseVariantStableSocketAliasesEvenWithOptInFlag() {
        let aliases = [
            "/tmp/CMUX.sock",
            "/private/tmp/CMUX.sock",
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
                .replacingOccurrences(of: "cmux-501.sock", with: "CMUX-501.sock"),
            SocketControlSettings.legacyUserScopedStableSocketPath(currentUserID: 501)
                .replacingOccurrences(of: "cmux-501.sock", with: "CMUX-501.sock"),
        ]

        for alias in aliases {
            let path = SocketControlSettings.socketPath(
                environment: [
                    "CMUX_SOCKET_PATH": alias,
                    "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                ],
                bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
                isDebugBuild: false,
                currentUserID: 501
            )

            XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock", alias)
        }
    }

    func testTaggedDebugBundleRefusesLeafSymlinkToStableSocketEvenWithOptInFlag() throws {
        let alias = "/tmp/cmux-stable-alias-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: alias)
        try FileManager.default.createSymbolicLink(
            atPath: alias,
            withDestinationPath: SocketControlSettings.stableDefaultSocketPath
        )
        defer { try? FileManager.default.removeItem(atPath: alias) }

        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": alias,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock")
    }

    func testTaggedDebugBundleRefusesExcessiveSymlinkChainEvenWithOptInFlag() throws {
        let root = "/tmp/cmux-stable-chain-\(UUID().uuidString)"
        let aliases = (0...64).map { "\(root)-\($0).sock" }
        for alias in aliases {
            try? FileManager.default.removeItem(atPath: alias)
        }
        defer {
            for alias in aliases {
                try? FileManager.default.removeItem(atPath: alias)
            }
        }

        try FileManager.default.createSymbolicLink(
            atPath: aliases[64],
            withDestinationPath: SocketControlSettings.stableDefaultSocketPath
        )
        for index in stride(from: 63, through: 0, by: -1) {
            try FileManager.default.createSymbolicLink(
                atPath: aliases[index],
                withDestinationPath: aliases[index + 1]
            )
        }

        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": aliases[0],
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock")
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
                bundleIdentifier: "com.cmuxterm.app.nightly.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-nightly-tag.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.debug.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-debug-tag.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.staging.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-staging-tag.sock"
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

    func testInitialStableLaunchFallsBackToUserScopedSocketWhenSameUserStablePathExists() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialStableLaunchTreatsPrivateTmpLegacyStableAliasAsStablePath() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: "/private/tmp/cmux.sock",
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { socketPath in
                XCTAssertEqual(socketPath, "/private/tmp/cmux.sock")
                return .socket(ownerUserID: 501)
            }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialStableLaunchDoesNotProbeSameUserStableSocketLiveness() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { _ in
                XCTFail("Existing startup sockets should fall back without liveness probing on the main thread")
                return true
            }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialStableLaunchDoesNotProbeSameUserStableSocketReclaimability() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                XCTFail("Existing startup sockets should fall back without reclaimability probing: \(socketPath)")
                return false
            }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialStableLaunchKeepsUserScopedPreferredPathWithoutProbing() {
        let userScopedPath = SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: userScopedPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { socketPath in
                XCTFail("User-scoped startup path should not be re-inspected: \(socketPath)")
                return .socket(ownerUserID: 501)
            },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                XCTFail("User-scoped startup path should not be reclaimed: \(socketPath)")
                return false
            }
        )

        XCTAssertEqual(path, userScopedPath)
    }

    func testInitialStableLaunchFallsBackToUserScopedSocketWhenMissingStablePathCannotBeReserved() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                XCTAssertEqual(socketPath, SocketControlSettings.stableDefaultSocketPath)
                return false
            }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialSocketPathDoesNotProbeForTaggedDebugBuild() {
        let debugPath = "/tmp/cmux-debug-tag.sock"
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: debugPath,
            bundleIdentifier: "com.cmuxterm.app.debug.tag",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in
                XCTFail("Tagged debug builds must not inspect the stable socket")
                return .socket(ownerUserID: 501)
            }
        )

        XCTAssertEqual(path, debugPath)
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

    func testResolvedInjectedCJKFontNamePinsRegularWeightForHiraginoSans() throws {
        guard let plain = GhosttyApp.discoveredCTFont(named: "Hiragino Sans"),
              let pinned = GhosttyApp.discoveredCTFont(
                  named: GhosttyApp.resolvedInjectedCJKFontName(named: "Hiragino Sans")
              ) else {
            throw XCTSkip("Hiragino Sans is unavailable on this runner")
        }

        let plainFullName = CTFontCopyFullName(plain) as String
        let pinnedFullName = CTFontCopyFullName(pinned) as String

        XCTAssertEqual(CTFontCopyFamilyName(pinned) as String, "Hiragino Sans")
        XCTAssertFalse(pinnedFullName.contains(" W0"))
        if plainFullName.contains(" W0") {
            XCTAssertNotEqual(
                CTFontCopyPostScriptName(plain) as String,
                CTFontCopyPostScriptName(pinned) as String
            )
        }
    }

    func testResolvedInjectedCJKFontNameLeavesPingFangSCStable() throws {
        guard GhosttyApp.discoveredCTFont(named: "PingFang SC") != nil else {
            throw XCTSkip("PingFang SC is unavailable on this runner")
        }

        XCTAssertEqual(
            GhosttyApp.resolvedInjectedCJKFontName(named: "PingFang SC"),
            "PingFang SC"
        )
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

    func testLoadedCJKScanPathsIncludesNativeGhosttyAppSupportWhenTaggedConfigExists() throws {
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
        let releaseConfigGhostty = releaseDir.appendingPathComponent("config.ghostty", isDirectory: false)
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: releaseConfig, atomically: true, encoding: .utf8)

        let paths = GhosttyApp.loadedCJKScanPaths(
            currentBundleIdentifier: "com.example.cmux-dev",
            appSupportDirectory: appSupport
        )

        XCTAssertTrue(paths.contains(taggedConfig.path))
        XCTAssertTrue(paths.contains(releaseConfig.path))
        XCTAssertTrue(paths.contains(releaseConfigGhostty.path))
        XCTAssertFalse(
            GhosttyApp.shouldInjectCJKFontFallback(
                preferredLanguages: ["zh-Hans-CN"],
                configPaths: paths
            )
        )
    }

    func testShouldApplyManagedDefaultAppearanceScansNativeGhosttyAppSupport() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-appearance-app-support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        let nativeConfig = ghosttyDir.appendingPathComponent("config", isDirectory: false)
        let currentConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        try "theme = Dracula\n"
            .write(to: nativeConfig, atomically: true, encoding: .utf8)
        try "".write(to: currentConfig, atomically: true, encoding: .utf8)

        let paths = GhosttyApp.loadedGhosttyConfigScanPaths(
            currentBundleIdentifier: "com.example.cmux-dev",
            appSupportDirectory: appSupport
        )

        XCTAssertTrue(paths.contains(nativeConfig.path))
        XCTAssertFalse(GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: paths))
    }

    func testLoadedGhosttyConfigScanPathsSkipsNativeLegacyConfigWhenCurrentConfigIsNonEmpty() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-appearance-app-support-current-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        let legacyConfig = ghosttyDir.appendingPathComponent("config", isDirectory: false)
        let currentConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        try "theme = Dracula\n"
            .write(to: legacyConfig, atomically: true, encoding: .utf8)
        try "font-size = 13\n"
            .write(to: currentConfig, atomically: true, encoding: .utf8)

        let paths = GhosttyApp.loadedGhosttyConfigScanPaths(
            currentBundleIdentifier: "com.example.cmux-dev",
            appSupportDirectory: appSupport
        )

        XCTAssertTrue(paths.contains(currentConfig.path))
        XCTAssertFalse(paths.contains(legacyConfig.path))
        XCTAssertTrue(GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: paths))
    }

    // MARK: shouldApplyManagedDefaultAppearance

    func testShouldApplyManagedDefaultAppearanceAllowsNonAppearanceConfig() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        background-opacity = 0.92
        """) { path in
            XCTAssertTrue(
                GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: [path])
            )
        }
    }

    func testShouldApplyManagedDefaultAppearanceSkipsExplicitTheme() throws {
        try withTempConfig("theme = Catppuccin Mocha\n") { path in
            XCTAssertFalse(
                GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: [path])
            )
        }
    }

    func testShouldApplyManagedDefaultAppearanceSkipsExplicitTerminalColorDirective() throws {
        try withTempConfig("background = #101010\n") { path in
            XCTAssertFalse(
                GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: [path])
            )
        }
    }

    func testConditionalThemeOverrideResolvesSplitThemeForPreferredScheme() throws {
        try withTempConfig("theme = light:Catppuccin Latte,dark:Apple System Colors\n") { path in
            XCTAssertEqual(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .dark,
                    configPaths: [path]
                ),
                "theme = Apple System Colors"
            )
        }
    }

    func testConditionalThemeOverrideResolvesLightSplitThemeForPreferredScheme() throws {
        try withTempConfig("theme = light:Catppuccin Latte,dark:Apple System Colors\n") { path in
            XCTAssertEqual(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .light,
                    configPaths: [path]
                ),
                "theme = Catppuccin Latte"
            )
        }
    }

    func testConditionalThemeOverrideSkipsPlainSingleTheme() throws {
        try withTempConfig("theme = Catppuccin Mocha\n") { path in
            XCTAssertNil(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .dark,
                    configPaths: [path]
                )
            )
        }
    }

    // Regression: https://github.com/manaflow-ai/cmux/issues/3459
    // `cmux themes set` always encodes the selection with conditional
    // `light:...,dark:...` syntax, even when both sides are identical. Ghostty
    // mis-applies that conditional syntax (background lands but foreground/palette
    // stay at the white defaults), so cmux must inject the resolved plain theme
    // even when the light and dark sides resolve to the same theme.
    func testConditionalThemeOverrideResolvesSameThemePair() throws {
        try withTempConfig("theme = light:Catppuccin Mocha,dark:Catppuccin Mocha\n") { path in
            XCTAssertEqual(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .dark,
                    configPaths: [path]
                ),
                "theme = Catppuccin Mocha"
            )
        }
    }

    // Regression: https://github.com/manaflow-ai/cmux/issues/3459
    // Exact repro from the issue body: selecting a single light theme for both
    // sides must force ghostty to apply the light theme's dark-on-light
    // foreground instead of leaving the default white foreground.
    func testConditionalThemeOverrideResolvesIdenticalLightThemePairFromCLIEncoding() throws {
        try withTempConfig("theme = light:GitHub Light Default,dark:GitHub Light Default\n") { path in
            XCTAssertEqual(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .light,
                    configPaths: [path]
                ),
                "theme = GitHub Light Default"
            )
            XCTAssertEqual(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .dark,
                    configPaths: [path]
                ),
                "theme = GitHub Light Default"
            )
        }
    }

    // Regression: https://github.com/manaflow-ai/cmux/issues/3459
    // `cmux themes set --light X` encodes `theme = light:X`, which ghostty treats
    // as conditional config. cmux injects the resolved plain theme for the
    // explicitly named light side, but must NOT force it onto dark appearances
    // (the dark side is unset and should keep the inherited/default dark theme).
    func testConditionalThemeOverrideResolvesExplicitSideOnlyForOneSidedTheme() throws {
        try withTempConfig("theme = light:Catppuccin Latte\n") { path in
            XCTAssertEqual(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .light,
                    configPaths: [path]
                ),
                "theme = Catppuccin Latte"
            )
            XCTAssertNil(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .dark,
                    configPaths: [path]
                )
            )
        }
    }

    // Regression: https://github.com/manaflow-ai/cmux/issues/3459
    // Mirror of the one-sided case for `theme = dark:Y` (only the dark side set).
    func testConditionalThemeOverrideResolvesExplicitSideOnlyForDarkOnlyTheme() throws {
        try withTempConfig("theme = dark:Catppuccin Mocha\n") { path in
            XCTAssertEqual(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .dark,
                    configPaths: [path]
                ),
                "theme = Catppuccin Mocha"
            )
            XCTAssertNil(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .light,
                    configPaths: [path]
                )
            )
        }
    }

    func testShouldApplyManagedDefaultAppearanceFollowsConfigFileIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-theme-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("appearance.conf")
        try "theme = Catppuccin Latte\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: [main.path])
        )
    }

    func testShouldApplyManagedDefaultAppearancePreservesQuotedQuestionMarkConfigFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-theme-quoted-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("?appearance.conf")
        try "theme = Catppuccin Latte\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "config-file = \"?appearance.conf\"\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: [main.path])
        )
    }

    func testShouldApplyManagedDefaultAppearanceProcessesIncludeQueuedAfterReset() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-theme-reset-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let themed = dir.appendingPathComponent("appearance.conf")
        try "theme = Catppuccin Latte\n"
            .write(to: themed, atomically: true, encoding: .utf8)

        let first = dir.appendingPathComponent("first.conf")
        try """
        config-file =
        config-file = appearance.conf
        """
        .write(to: first, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "config-file = first.conf\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: [main.path])
        )
    }

    func testStartupAppearanceFreshInstallPreviewUsesManagedDefaultColorsWithoutSettingTheme() {
        #if DEBUG
        let previousProfile = GhosttyStartupAppearancePreviewState.profile
        GhosttyStartupAppearancePreviewState.profile = .freshInstall
        GhosttyConfig.invalidateLoadCache()
        defer {
            GhosttyStartupAppearancePreviewState.profile = previousProfile
            GhosttyConfig.invalidateLoadCache()
        }

        let config = GhosttyConfig.load(preferredColorScheme: .light, useCache: false)
        XCTAssertNil(config.theme)
        XCTAssertEqual(config.backgroundColor.hexString(), "#FEFFFF")
        #endif
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

    func testShellIntegrationNormalizesClaudeConfigDirAfterUserZshrc() throws {
        let output = try runPromptInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "CMD=$CLAUDE_CONFIG_DIR" >> "$CMUX_TEST_OUTPUT"
            """,
            userZshRCContents: """
            mkdir -p "$HOME/.subrouter/codex/claude/_p1775010019397"
            ln -s "$HOME/.subrouter/codex" "$HOME/.codex-accounts"
            export CLAUDE_CONFIG_DIR="$HOME/.subrouter/codex/claude/_p1775010019397"

            cmux_test_ready() {
              [[ -e "$CMUX_TEST_READY" ]] && return 0
              print -r -- "PRE=$CLAUDE_CONFIG_DIR" > "$CMUX_TEST_OUTPUT"
              : > "$CMUX_TEST_READY"
              precmd_functions=(${precmd_functions:#cmux_test_ready})
            }
            precmd_functions+=(cmux_test_ready)
            """
        )

        XCTAssertTrue(
            output.contains("PRE=") && output.contains("CMD="),
            output
        )
        for line in output.split(separator: "\n") {
            XCTAssertTrue(
                line.hasSuffix("/.codex-accounts/claude/_p1775010019397"),
                output
            )
        }
        XCTAssertFalse(output.contains("/.subrouter/codex/claude/"), output)
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

    func testBashNoGitWatchSkipsHeadTrackingAndPRClear() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-no-git-watch-\(UUID().uuidString)")
        let repoA = root.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = root.appendingPathComponent("repo-b", isDirectory: true)
        let logPath = root.appendingPathComponent("send.log", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            mkdir -p "\(repoA.path)/.git" "\(repoB.path)/.git"
            printf '%s\\n' 'ref: refs/heads/main' > "\(repoA.path)/.git/HEAD"
            printf '%s\\n' 'ref: refs/heads/feature' > "\(repoB.path)/.git/HEAD"
            : > "\(logPath.path)"
            _cmux_send() { printf '%s\\n' "$1" >> "\(logPath.path)"; }
            cd "\(repoA.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_PATH="$PWD/.git/HEAD"
            _CMUX_GIT_HEAD_SIGNATURE="$(_cmux_git_head_signature "$_CMUX_GIT_HEAD_PATH")"
            printf '%s\\n' 'ref: refs/heads/old-cleared' > "$_CMUX_GIT_HEAD_PATH"
            cd "\(repoB.path)"
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_LAST_PR_ACTION="checkout"
            _CMUX_LAST_PR_TARGET="feature"
            _cmux_prompt_command
            printf 'HEAD_PATH=%s\\n' "$_CMUX_GIT_HEAD_PATH"
            printf 'HEAD_LAST_PWD=%s\\n' "$_CMUX_GIT_HEAD_LAST_PWD"
            printf 'LAST_PR_ACTION=%s\\n' "$_CMUX_LAST_PR_ACTION"
            printf 'LOG<<EOF\\n'
            cat "\(logPath.path)"
            printf 'EOF\\n'
            """,
            extraEnvironment: [
                "CMUX_NO_GIT_WATCH": "1",
                "CMUX_SOCKET_PATH": socketPath.path,
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertFalse(result.stdout.contains(repoA.appendingPathComponent(".git/HEAD").path), result.stdout)
        XCTAssertTrue(result.stdout.contains("HEAD_PATH=\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("HEAD_LAST_PWD=\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("LAST_PR_ACTION=\n"), result.stdout)
        XCTAssertFalse(result.stdout.contains("clear_pr"), result.stdout)
        XCTAssertFalse(result.stdout.contains("report_pr_action"), result.stdout)
    }

    func testZshNoGitWatchSkipsHeadTrackingAndPRClear() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-no-git-watch-\(UUID().uuidString)")
        let repoA = root.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = root.appendingPathComponent("repo-b", isDirectory: true)
        let logPath = root.appendingPathComponent("send.log", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            mkdir -p "\(repoA.path)/.git" "\(repoB.path)/.git"
            printf '%s\\n' 'ref: refs/heads/main' > "\(repoA.path)/.git/HEAD"
            printf '%s\\n' 'ref: refs/heads/feature' > "\(repoB.path)/.git/HEAD"
            : > "\(logPath.path)"
            _cmux_send() { printf '%s\\n' "$1" >> "\(logPath.path)"; }
            cd "\(repoA.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_PATH="$PWD/.git/HEAD"
            _CMUX_GIT_HEAD_SIGNATURE="$(_cmux_git_head_signature "$_CMUX_GIT_HEAD_PATH")"
            printf '%s\\n' 'ref: refs/heads/old-cleared' > "$_CMUX_GIT_HEAD_PATH"
            cd "\(repoB.path)"
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_LAST_PR_ACTION="checkout"
            _CMUX_LAST_PR_TARGET="feature"
            _cmux_precmd
            printf 'HEAD_PATH=%s\\n' "$_CMUX_GIT_HEAD_PATH"
            printf 'HEAD_LAST_PWD=%s\\n' "$_CMUX_GIT_HEAD_LAST_PWD"
            printf 'LAST_PR_ACTION=%s\\n' "$_CMUX_LAST_PR_ACTION"
            printf 'LOG<<EOF\\n'
            cat "\(logPath.path)"
            printf 'EOF\\n'
            """,
            extraEnvironment: [
                "CMUX_NO_GIT_WATCH": "1",
                "CMUX_SOCKET_PATH": socketPath.path,
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertFalse(output.contains(repoA.appendingPathComponent(".git/HEAD").path), output)
        XCTAssertTrue(output.contains("HEAD_PATH=\n"), output)
        XCTAssertTrue(output.contains("HEAD_LAST_PWD=\n"), output)
        XCTAssertTrue(output.contains("LAST_PR_ACTION=\n"), output)
        XCTAssertFalse(output.contains("clear_pr"), output)
        XCTAssertFalse(output.contains("report_pr_action"), output)
    }

    func testZshNoPullRequestWatchSkipsLegacyGhPRProbe() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-no-pr-watch-\(UUID().uuidString)")
        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let fakeBinURL = root.appendingPathComponent("fake-bin", isDirectory: true)
        let markerURL = root.appendingPathComponent("gh-pr-invoked", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: repoURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        try "ref: refs/heads/issue-2746-rate-limit\n".write(
            to: repoURL.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try writeExecutableScript(
            at: fakeBinURL.appendingPathComponent("gh"),
            contents: """
            #!/bin/sh
            printf invoked > "$CMUX_GH_MARKER"
            printf '2746\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/2746\\n'
            """
        )
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_send() { :; }
            _cmux_send_bg() { :; }
            _cmux_report_pr_for_path "\(repoURL.path)" || true
            [[ -e "\(markerURL.path)" ]] && print MARKER=1 || print MARKER=0
            """,
            extraEnvironment: [
                "CMUX_NO_PR_WATCH": "1",
                "CMUX_GH_MARKER": markerURL.path,
                "CMUX_SOCKET_PATH": socketPath.path,
                "PATH": "\(fakeBinURL.path):/usr/bin:/bin",
            ]
        )

        XCTAssertTrue(output.contains("MARKER=0"), output)
    }

    func testBashNoPullRequestWatchSkipsLegacyGhPRProbe() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-no-pr-watch-\(UUID().uuidString)")
        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let fakeBinURL = root.appendingPathComponent("fake-bin", isDirectory: true)
        let markerURL = root.appendingPathComponent("gh-pr-invoked", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: repoURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        try "ref: refs/heads/issue-2746-rate-limit\n".write(
            to: repoURL.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try writeExecutableScript(
            at: fakeBinURL.appendingPathComponent("gh"),
            contents: """
            #!/bin/sh
            printf invoked > "$CMUX_GH_MARKER"
            printf '2746\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/2746\\n'
            """
        )
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_send() { :; }
            _cmux_report_pr_for_path "\(repoURL.path)" || true
            [[ -e "\(markerURL.path)" ]] && printf 'MARKER=1\\n' || printf 'MARKER=0\\n'
            """,
            extraEnvironment: [
                "CMUX_NO_PR_WATCH": "1",
                "CMUX_GH_MARKER": markerURL.path,
                "CMUX_SOCKET_PATH": socketPath.path,
                "PATH": "\(fakeBinURL.path):/usr/bin:/bin",
            ]
        )

        XCTAssertTrue(result.stdout.contains("MARKER=0"), result.stdout)
    }

    func testZshPromptResetsTerminalKeyboardProtocols() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _cmux_precmd
            """,
            extraEnvironment: [
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_BUNDLED_CLI_PATH": "/usr/bin/true",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TEST_FORCE_KITTY_RESET": "1",
            ]
        )

        XCTAssertEqual(output, "\u{1B}[>m\u{1B}[<8u")
    }

    func testBashPromptResetsTerminalKeyboardProtocols() throws {
        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _cmux_prompt_command
            """,
            extraEnvironment: [
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_BUNDLED_CLI_PATH": "/usr/bin/true",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TEST_FORCE_KITTY_RESET": "1",
            ]
        )

        XCTAssertEqual(result.stdout, "\u{1B}[>m\u{1B}[<8u")
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
