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


// MARK: - Config file loading, parsing, legacy fallback
extension GhosttyConfigTests {
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

}
