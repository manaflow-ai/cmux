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


// MARK: - Managed default appearance and conditional theme override
extension GhosttyMouseFocusTests {
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

    func testConditionalThemeOverrideSkipsSameThemePair() throws {
        try withTempConfig("theme = light:Catppuccin Mocha,dark:Catppuccin Mocha\n") { path in
            XCTAssertNil(
                GhosttyApp.conditionalThemeOverrideConfigContents(
                    preferredColorScheme: .dark,
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
