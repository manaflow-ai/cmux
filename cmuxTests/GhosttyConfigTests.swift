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

final class TabManagerNotificationOrderingSourceTests: XCTestCase {
    func testGhosttyDidSetTitleObserverDoesNotHopThroughTask() throws {
        let projectRoot = findProjectRoot()
        let tabManagerURL = projectRoot.appendingPathComponent("Sources/TabManager.swift")
        let source = try String(contentsOf: tabManagerURL, encoding: .utf8)

        guard let titleObserverStart = source.range(of: "forName: .ghosttyDidSetTitle"),
              let focusObserverStart = source.range(
                of: "forName: .ghosttyDidFocusSurface",
                range: titleObserverStart.upperBound..<source.endIndex
              ) else {
            XCTFail("Failed to locate TabManager notification observer block in Sources/TabManager.swift")
            return
        }

        let block = String(source[titleObserverStart.lowerBound..<focusObserverStart.lowerBound])
        XCTAssertFalse(
            block.contains("Task {"),
            """
            The .ghosttyDidSetTitle observer must update model state in the notification callback.
            Using Task can reorder updates and leave titlebar/toolbar one event behind.
            """
        )
        XCTAssertTrue(
            block.contains("MainActor.assumeIsolated"),
            "Expected .ghosttyDidSetTitle observer to run synchronously on MainActor."
        )
        XCTAssertTrue(
            block.contains("enqueuePanelTitleUpdate"),
            "Expected .ghosttyDidSetTitle observer to enqueue panel title updates."
        )
    }

    private func findProjectRoot() -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

final class SocketControlSettingsTests: XCTestCase {
    func testStableReleaseIgnoresAmbientSocketOverrideByDefault() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux.sock")
    }

    func testNightlyReleaseUsesDedicatedDefaultAndIgnoresAmbientSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.nightly",
            isDebugBuild: false
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
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-forced.sock")
    }

    func testDefaultSocketPathByChannel() {
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.cmuxterm.app", isDebugBuild: false),
            "/tmp/cmux.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.cmuxterm.app.nightly", isDebugBuild: false),
            "/tmp/cmux-nightly.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.cmuxterm.app.debug.tag", isDebugBuild: false),
            "/tmp/cmux-debug.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.cmuxterm.app.staging.tag", isDebugBuild: false),
            "/tmp/cmux-staging.sock"
        )
    }
}
