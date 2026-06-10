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


// MARK: - Theme loading, paired/alias resolution, caching
extension GhosttyConfigTests {
    private struct RGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int
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
