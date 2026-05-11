import XCTest
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testResolvedModeDefaultsToSystemWhenUnset() {
        let suiteName = "AppearanceSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)

        let resolved = AppearanceSettings.resolvedMode(defaults: defaults)
        XCTAssertEqual(resolved, .system)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.system.rawValue)
    }

    func testCurrentColorSchemePreferenceUsesStoredDarkModeBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.dark.rawValue,
            appleInterfaceStyle: nil
        ) {
            XCTAssertEqual(
                GhosttyConfig.currentColorSchemePreference(appAppearance: nil),
                .dark
            )
        }
    }

    func testCurrentColorSchemePreferenceUsesStoredLightModeBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.light.rawValue,
            appleInterfaceStyle: "Dark"
        ) {
            XCTAssertEqual(
                GhosttyConfig.currentColorSchemePreference(appAppearance: nil),
                .light
            )
        }
    }

    func testCurrentColorSchemePreferenceUsesSystemDarkBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.system.rawValue,
            appleInterfaceStyle: "Dark"
        ) {
            XCTAssertEqual(
                GhosttyConfig.currentColorSchemePreference(appAppearance: nil),
                .dark
            )
        }
    }

    func testColorSchemePreferenceUsesSystemLightWhenSystemStyleIsUnset() {
        let suiteName = "AppearanceSettingsTests.SystemLight.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        defaults.removeObject(forKey: "AppleInterfaceStyle")
        let lightSystem = AppearanceSettings.SystemAppearance(interfaceStyle: nil)

        XCTAssertEqual(
            AppearanceSettings.colorSchemePreference(appAppearance: nil, defaults: defaults, systemAppearance: lightSystem),
            .light
        )
        XCTAssertEqual(
            GhosttyConfig.currentColorSchemePreference(appAppearance: nil, defaults: defaults, systemAppearance: lightSystem),
            .light
        )
    }

    func testColorSchemeOverrideIsExplicitOnlyForManualLightAndDarkModes() {
        XCTAssertEqual(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.light.rawValue), .light)
        XCTAssertEqual(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.dark.rawValue), .dark)
        XCTAssertNil(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.system.rawValue))
        XCTAssertNil(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.auto.rawValue))
        XCTAssertNil(AppearanceSettings.colorSchemeOverride(for: "invalid"))
        XCTAssertEqual(AppearanceSettings.colorScheme(for: AppearanceMode.dark.rawValue, fallback: .light), .dark)
        XCTAssertEqual(AppearanceSettings.colorScheme(for: AppearanceMode.system.rawValue, fallback: .dark), .dark)
    }

    func testSelectingDarkModeAppliesRuntimeAppearanceAndSynchronizesTerminalTheme() {
        let suiteName = "AppearanceSettingsTests.SelectDark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var appliedAppearanceName: NSAppearance.Name?
        var synchronizedAppearanceName: NSAppearance.Name?
        var synchronizedSource: String?
        let environment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                appliedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
            },
            synchronizeTerminalThemeWithAppearance: { appearance, source in
                synchronizedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
                synchronizedSource = source
            },
            systemAppearance: {
                XCTFail("Dark mode should not resolve system appearance")
                return nil
            }
        )

        let selected = AppearanceSettings.selectMode(
            .dark,
            defaults: defaults,
            source: "settings.themePicker",
            environment: environment
        )

        XCTAssertEqual(selected, .dark)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.dark.rawValue)
        XCTAssertEqual(appliedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedSource, "settings.themePicker")
    }

    func testSelectingSystemModeClearsRuntimeAppearanceOverrideForSystemFollow() {
        let suiteName = "AppearanceSettingsTests.SelectSystem.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var appliedAppearanceWasCleared = false
        var synchronizedAppearanceWasCleared = false
        let environment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                appliedAppearanceWasCleared = appearance == nil
            },
            synchronizeTerminalThemeWithAppearance: { appearance, _ in
                synchronizedAppearanceWasCleared = appearance == nil
            },
            systemAppearance: {
                XCTFail("System mode should clear the app override after launch")
                return NSAppearance(named: .darkAqua)
            }
        )

        let selected = AppearanceSettings.selectMode(
            .system,
            defaults: defaults,
            source: "settings.themePicker",
            environment: environment
        )

        XCTAssertEqual(selected, .system)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.system.rawValue)
        XCTAssertTrue(appliedAppearanceWasCleared)
        XCTAssertTrue(synchronizedAppearanceWasCleared)
    }

    func testSelectingAppearanceModesWritesManagedGhosttyConfig() throws {
        let suiteName = "AppearanceSettingsTests.ManagedGhosttyConfig.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let scenarios: [(mode: AppearanceMode, systemAppearance: NSAppearance.Name, expectedBackground: String, expectedForeground: String)] = [
            (.light, .darkAqua, "#feffff", "#000000"),
            (.dark, .aqua, "#1e1e1e", "#ffffff"),
            (.system, .aqua, "#feffff", "#000000"),
            (.system, .darkAqua, "#1e1e1e", "#ffffff"),
        ]

        for scenario in scenarios {
            try withTemporaryHomeDirectory { homeDirectory in
                let configEnvironment = ConfigSourceEnvironment(
                    homeDirectoryURL: homeDirectory,
                    currentBundleIdentifier: "com.cmuxterm.app"
                )
                let configURL = try configEnvironment.materializeCmuxConfigFileIfNeeded()
                XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "")

                let environment = AppearanceSettings.LiveApplyEnvironment(
                    setApplicationAppearance: { _ in },
                    synchronizeTerminalThemeWithAppearance: { _, _ in },
                    systemAppearance: {
                        NSAppearance(named: scenario.systemAppearance)
                    },
                    persistManagedTerminalAppearanceConfig: { mode, appearance, callbackDefaults, source in
                        let resolvedAppearance = appearance ?? NSAppearance(named: scenario.systemAppearance)
                        ManagedGhosttyAppearanceConfigStore(
                            environment: configEnvironment,
                            defaults: callbackDefaults
                        )
                        .persistManagedTerminalAppearanceConfig(
                            mode: mode,
                            appAppearance: resolvedAppearance,
                            source: source
                        )
                        return nil
                    }
                )

                _ = AppearanceSettings.selectMode(
                    scenario.mode,
                    defaults: defaults,
                    source: "settings.themePicker",
                    environment: environment
                )

                let contents = try String(contentsOf: configURL, encoding: .utf8)
                XCTAssertFalse(contents.isEmpty, "Expected \(scenario.mode.rawValue) to write \(configURL.path)")
                XCTAssertTrue(
                    contents.contains("background = \(scenario.expectedBackground)"),
                    "Expected \(scenario.mode.rawValue) config to contain \(scenario.expectedBackground); got:\n\(contents)"
                )
                XCTAssertTrue(
                    contents.contains("foreground = \(scenario.expectedForeground)"),
                    "Expected \(scenario.mode.rawValue) config to contain \(scenario.expectedForeground); got:\n\(contents)"
                )
            }
        }
    }

    func testManagedGhosttyConfigReplacesOrphanedManagedBlock() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let configEnvironment = ConfigSourceEnvironment(
                homeDirectoryURL: homeDirectory,
                currentBundleIdentifier: "com.cmuxterm.app"
            )
            try configEnvironment.writeCmuxConfigContents("""
            font-size = 13
            # cmux-managed-appearance: begin
            background = #000000
            """)

            ManagedGhosttyAppearanceConfigStore(environment: configEnvironment)
                .persistManagedTerminalAppearanceConfig(
                    mode: .dark,
                    appAppearance: NSAppearance(named: .darkAqua),
                    source: "test.orphanedManagedBlock"
                )

            let contents = try String(contentsOf: configEnvironment.cmuxConfigURL, encoding: .utf8)
            XCTAssertTrue(contents.contains("font-size = 13"))
            XCTAssertEqual(occurrenceCount(of: "# cmux-managed-appearance: begin", in: contents), 1)
            XCTAssertEqual(occurrenceCount(of: "# cmux-managed-appearance: end", in: contents), 1)
            XCTAssertTrue(contents.contains("background = #1e1e1e"))
            XCTAssertFalse(contents.contains("background = #000000"))
        }
    }

    func testManagedGhosttyConfigDoesNotOverwriteUnreadableExistingConfig() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let configEnvironment = ConfigSourceEnvironment(
                homeDirectoryURL: homeDirectory,
                currentBundleIdentifier: "com.cmuxterm.app"
            )
            let configURL = try configEnvironment.materializeCmuxConfigFileIfNeeded()
            let invalidUTF8 = Data([0xff, 0xfe, 0xfd])
            try invalidUTF8.write(to: configURL)

            let didPersist = ManagedGhosttyAppearanceConfigStore(environment: configEnvironment)
                .persistManagedTerminalAppearanceConfig(
                    mode: .dark,
                    appAppearance: NSAppearance(named: .darkAqua),
                    source: "test.unreadableExistingConfig"
                )

            XCTAssertFalse(didPersist)
            XCTAssertEqual(try Data(contentsOf: configURL), invalidUTF8)
        }
    }

    func testTerminalThemeSyncSkipsReloadWhenManagedConfigPersistenceFails() async throws {
        let suiteName = "AppearanceSettingsTests.FailedPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let blocker = AppearancePersistenceBlocker()
        var synchronizedSources: [String] = []
        let environment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { _ in },
            synchronizeTerminalThemeWithAppearance: { _, source in
                synchronizedSources.append(source)
            },
            systemAppearance: {
                NSAppearance(named: .aqua)
            },
            persistManagedTerminalAppearanceConfig: { _, _, _, source in
                blocker.task(for: source)
            }
        )

        AppearanceSettings.synchronizeTerminalThemeWithManagedConfig(
            appAppearance: NSAppearance(named: .aqua),
            defaults: defaults,
            source: "failedPersistence",
            environment: environment
        )

        await blocker.waitUntilRegistered(count: 1)
        await blocker.complete("appearanceSync:failedPersistence", result: false)
        for _ in 0..<3 {
            await Task.yield()
        }
        XCTAssertEqual(synchronizedSources, [])
    }

    func testTerminalThemeSyncIgnoresSupersededPersistenceCompletion() async throws {
        let suiteName = "AppearanceSettingsTests.SupersededSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let blocker = AppearancePersistenceBlocker()
        var synchronizedSources: [String] = []
        let environment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { _ in },
            synchronizeTerminalThemeWithAppearance: { _, source in
                synchronizedSources.append(source)
            },
            systemAppearance: {
                NSAppearance(named: .aqua)
            },
            persistManagedTerminalAppearanceConfig: { _, _, _, source in
                blocker.task(for: source)
            }
        )

        AppearanceSettings.synchronizeTerminalThemeWithManagedConfig(
            appAppearance: NSAppearance(named: .aqua),
            defaults: defaults,
            source: "first",
            environment: environment
        )
        AppearanceSettings.synchronizeTerminalThemeWithManagedConfig(
            appAppearance: NSAppearance(named: .darkAqua),
            defaults: defaults,
            source: "second",
            environment: environment
        )

        await blocker.waitUntilRegistered(count: 2)
        await blocker.complete("appearanceSync:first")
        for _ in 0..<3 {
            await Task.yield()
        }
        XCTAssertEqual(synchronizedSources, [])

        await blocker.complete("appearanceSync:second")
        for _ in 0..<3 {
            await Task.yield()
        }
        XCTAssertEqual(synchronizedSources, ["second"])
    }

    private func withTemporaryAppearanceDefaults(
        appearanceMode: String,
        appleInterfaceStyle: String?,
        body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let originalAppearanceMode = defaults.object(forKey: AppearanceSettings.appearanceModeKey)
        let originalAppleInterfaceStyle = defaults.object(forKey: "AppleInterfaceStyle")
        defer {
            restoreDefaultsValue(
                originalAppearanceMode,
                key: AppearanceSettings.appearanceModeKey,
                defaults: defaults
            )
            restoreDefaultsValue(
                originalAppleInterfaceStyle,
                key: "AppleInterfaceStyle",
                defaults: defaults
            )
        }

        defaults.set(appearanceMode, forKey: AppearanceSettings.appearanceModeKey)
        if let appleInterfaceStyle {
            defaults.set(appleInterfaceStyle, forKey: "AppleInterfaceStyle")
        } else {
            defaults.removeObject(forKey: "AppleInterfaceStyle")
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

    private func withTemporaryHomeDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-appearance-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

private actor AppearancePersistenceBlocker {
    private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]

    nonisolated func task(for source: String) -> Task<Bool, Never> {
        Task {
            await self.wait(for: source)
        }
    }

    func waitUntilRegistered(count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func complete(_ source: String, result: Bool = true) {
        continuations.removeValue(forKey: source)?.resume(returning: result)
    }

    private func wait(for source: String) async -> Bool {
        await withCheckedContinuation { continuation in
            continuations[source] = continuation
        }
    }
}
