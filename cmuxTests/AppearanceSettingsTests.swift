import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
final class AppearanceSettingsTests {
    @Test func bundleIconPersistenceAllowsStableReleaseBundle() {
        #expect(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app",
                appBundleLastPathComponent: "cmux.app",
                persistenceDisabled: false
            )
        )
    }

    @Test func bundleIconPersistenceSkipsNightlyBundles() {
        #expect(
            !AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.nightly",
                appBundleLastPathComponent: "cmux NIGHTLY.app",
                persistenceDisabled: false
            )
        )
        #expect(
            !AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.nightly.issue-4350",
                appBundleLastPathComponent: "cmux NIGHTLY issue-4350.app",
                persistenceDisabled: false
            )
        )
    }

    @Test func bundleIconPersistenceRejectsMismatchedStableIdentifierAndPath() {
        #expect(
            !AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app",
                appBundleLastPathComponent: "cmux NIGHTLY.app",
                persistenceDisabled: false
            )
        )
    }

    @Test func bundleIconPersistenceSkipsDebugBundles() {
        #expect(
            !AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.debug",
                appBundleLastPathComponent: "cmux DEV.app",
                persistenceDisabled: false
            )
        )
        #expect(
            !AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.debug.issue-4350",
                appBundleLastPathComponent: "cmux DEV issue-4350.app",
                persistenceDisabled: false
            )
        )
    }

    @Test func bundleIconPersistenceHonorsDisableDefault() {
        #expect(
            !AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app",
                appBundleLastPathComponent: "cmux.app",
                persistenceDisabled: true
            )
        )
    }

    @Test func bundleIconPersistenceMirrorsSmokeLaunchArgumentToDefaults() throws {
        let suiteName = "AppearanceSettingsTests.BundleIconPersistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppBundleIconPersistencePolicy.updateDisableDefault(
            defaults: defaults,
            launchArguments: [AppBundleIconPersistencePolicy.disablePersistenceArgument]
        )
        #expect(
            (defaults.object(forKey: AppBundleIconPersistencePolicy.disablePersistenceDefaultsKey) as? Bool) == true
        )

        AppBundleIconPersistencePolicy.updateDisableDefault(
            defaults: defaults,
            launchArguments: []
        )
        #expect(
            (defaults.object(forKey: AppBundleIconPersistencePolicy.disablePersistenceDefaultsKey) as? Bool) == false
        )
    }

    @Test func appConfigReloadRefreshUpdatesSurfaceConfigBeforeRedraw() throws {
        let fakeSurface = try #require(UnsafeMutableRawPointer(bitPattern: 0x3851))
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: fakeSurface,
            source: "appearanceSync:test",
            reloadSurfaceConfiguration: { surface, soft, source in
                #expect(surface == fakeSurface)
                #expect(soft)
                events.append("reload:\(source)")
            },
            applySurfaceColorScheme: {
                events.append("color-scheme")
            },
            refreshHostBackground: {
                events.append("host-background")
            },
            forceRefresh: { reason in
                events.append("force-refresh:\(reason)")
            }
        )

        #expect(events == [
            "color-scheme",
            "reload:appearanceSync:test",
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    @Test func appConfigReloadRefreshSkipsSurfaceConfigUpdateWhenSurfaceIsUnavailable() {
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: nil,
            source: "appearanceSync:teardown",
            reloadSurfaceConfiguration: { _, _, _ in
                events.append("reload")
            },
            applySurfaceColorScheme: {
                events.append("color-scheme")
            },
            refreshHostBackground: {
                events.append("host-background")
            },
            forceRefresh: { reason in
                events.append("force-refresh:\(reason)")
            }
        )

        #expect(events == [
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    @Test func appConfigReloadRefreshAppliesSurfaceColorSchemeForPreviewReload() throws {
        let fakeSurface = try #require(UnsafeMutableRawPointer(bitPattern: 0x3852))
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: fakeSurface,
            source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource,
            reloadSurfaceConfiguration: { _, soft, source in
                #expect(soft)
                events.append("reload:\(source)")
            },
            applySurfaceColorScheme: {
                events.append("color-scheme")
            },
            refreshHostBackground: {
                events.append("host-background")
            },
            forceRefresh: { reason in
                events.append("force-refresh:\(reason)")
            }
        )

        #expect(events == [
            "color-scheme",
            "reload:\(GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource)",
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    @Test func cmuxThemeFinalReloadUsesFinalSource() {
        #expect(
            GhosttySurfaceConfigurationRefresh.cmuxThemeReloadSource(phase: "final")
                == GhosttySurfaceConfigurationRefresh.cmuxThemeReloadFinalSource
        )
    }

    @Test func cmuxThemePreviewReloadIsDebounced() {
        #expect(
            GhosttySurfaceConfigurationRefresh.cmuxThemeReloadSource(phase: "preview")
                == GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource
        )
        #expect(
            GhosttySurfaceConfigurationRefresh.shouldDebounceCmuxThemeReload(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource
            )
        )
        #expect(
            GhosttySurfaceConfigurationRefresh.shouldDebounceCmuxThemeReload(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadLegacySource
            )
        )
        #expect(
            !GhosttySurfaceConfigurationRefresh.shouldDebounceCmuxThemeReload(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadFinalSource
            )
        )
    }

    @Test func resolvedModeDefaultsToSystemWhenUnset() throws {
        let suiteName = "AppearanceSettingsTests.Default.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)

        let resolved = AppearanceSettings.resolvedMode(defaults: defaults)
        #expect(resolved == .system)
        #expect(defaults.string(forKey: AppearanceSettings.appearanceModeKey) == AppearanceMode.system.rawValue)
    }

    @Test func currentColorSchemePreferenceUsesStoredDarkModeBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.dark.rawValue,
            appleInterfaceStyle: nil
        ) {
            #expect(GhosttyConfig.currentColorSchemePreference(appAppearance: nil) == .dark)
        }
    }

    @Test func currentColorSchemePreferenceUsesStoredLightModeBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.light.rawValue,
            appleInterfaceStyle: "Dark"
        ) {
            #expect(GhosttyConfig.currentColorSchemePreference(appAppearance: nil) == .light)
        }
    }

    @Test func currentColorSchemePreferenceUsesSystemDarkBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.system.rawValue,
            appleInterfaceStyle: "Dark"
        ) {
            #expect(GhosttyConfig.currentColorSchemePreference(appAppearance: nil) == .dark)
        }
    }

    @Test func colorSchemePreferenceUsesSystemLightWhenSystemStyleIsUnset() throws {
        let suiteName = "AppearanceSettingsTests.SystemLight.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        defaults.removeObject(forKey: "AppleInterfaceStyle")
        let lightSystem = AppearanceSettings.SystemAppearance(interfaceStyle: nil)

        #expect(
            AppearanceSettings.colorSchemePreference(appAppearance: nil, defaults: defaults, systemAppearance: lightSystem)
                == .light
        )
        #expect(
            GhosttyConfig.currentColorSchemePreference(appAppearance: nil, defaults: defaults, systemAppearance: lightSystem)
                == .light
        )
    }

    @Test func colorSchemeOverrideIsExplicitOnlyForManualLightAndDarkModes() {
        #expect(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.light.rawValue) == .light)
        #expect(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.dark.rawValue) == .dark)
        #expect(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.system.rawValue) == nil)
        #expect(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.auto.rawValue) == nil)
        #expect(AppearanceSettings.colorSchemeOverride(for: "invalid") == nil)
        #expect(AppearanceSettings.colorScheme(for: AppearanceMode.dark.rawValue, fallback: .light) == .dark)
        #expect(AppearanceSettings.colorScheme(for: AppearanceMode.system.rawValue, fallback: .dark) == .dark)
    }

    @Test func selectingDarkModeAppliesRuntimeAppearanceAndSynchronizesTerminalTheme() throws {
        let suiteName = "AppearanceSettingsTests.SelectDark.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
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
                Issue.record("Dark mode should not resolve system appearance")
                return nil
            }
        )

        let selected = AppearanceSettings.selectMode(
            .dark,
            defaults: defaults,
            source: "settings.themePicker",
            environment: environment
        )

        #expect(selected == .dark)
        #expect(defaults.string(forKey: AppearanceSettings.appearanceModeKey) == AppearanceMode.dark.rawValue)
        #expect(appliedAppearanceName == .darkAqua)
        #expect(synchronizedAppearanceName == .darkAqua)
        #expect(synchronizedSource == "settings.themePicker")
    }

    @Test func selectingSystemModeClearsRuntimeAppearanceOverrideForSystemFollow() throws {
        let suiteName = "AppearanceSettingsTests.SelectSystem.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
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
                Issue.record("System mode should clear the app override after launch")
                return NSAppearance(named: .darkAqua)
            }
        )

        let selected = AppearanceSettings.selectMode(
            .system,
            defaults: defaults,
            source: "settings.themePicker",
            environment: environment
        )

        #expect(selected == .system)
        #expect(defaults.string(forKey: AppearanceSettings.appearanceModeKey) == AppearanceMode.system.rawValue)
        #expect(appliedAppearanceWasCleared)
        #expect(synchronizedAppearanceWasCleared)
    }

    @Test func defaultsObserverAppliesLiveAppearanceWhenStoredModeChanges() throws {
        let suiteName = "AppearanceSettingsTests.DefaultsObserver.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationCenter = NotificationCenter()
        var appliedAppearanceName: NSAppearance.Name?
        var synchronizedAppearanceName: NSAppearance.Name?
        var synchronizedSource: String?
        let liveEnvironment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                appliedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
            },
            synchronizeTerminalThemeWithAppearance: { appearance, source in
                synchronizedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
                synchronizedSource = source
            },
            systemAppearance: {
                Issue.record("Dark mode should not resolve system appearance")
                return nil
            }
        )
        let observer = AppearanceSettingsUserDefaultsObserver(
            environment: .init(
                addDefaultsObserver: { handler in
                    notificationCenter.addObserver(
                        forName: UserDefaults.didChangeNotification,
                        object: nil,
                        queue: nil
                    ) { _ in
                        handler()
                    }
                },
                removeObserver: { observer in
                    notificationCenter.removeObserver(observer)
                },
                currentRawValue: {
                    defaults.string(forKey: AppearanceSettings.appearanceModeKey)
                },
                applyStoredMode: { rawValue, source in
                    AppearanceSettings.applyStoredMode(
                        rawValue: rawValue,
                        defaults: defaults,
                        source: source,
                        environment: liveEnvironment
                    )
                }
            ),
            source: "test.defaultsObserver"
        )

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        observer.startObserving()
        defaults.set(AppearanceMode.dark.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)

        #expect(appliedAppearanceName == .darkAqua)
        #expect(synchronizedAppearanceName == .darkAqua)
        #expect(synchronizedSource == "test.defaultsObserver")
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

}
