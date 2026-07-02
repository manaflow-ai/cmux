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
    func testBundleIconPersistenceAllowsStableReleaseBundle() {
        XCTAssertTrue(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app",
                appBundleLastPathComponent: "cmux.app",
                persistenceDisabled: false
            )
        )
    }

    func testBundleIconPersistenceSkipsNightlyBundles() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.nightly",
                appBundleLastPathComponent: "cmux NIGHTLY.app",
                persistenceDisabled: false
            )
        )
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.nightly.issue-4350",
                appBundleLastPathComponent: "cmux NIGHTLY issue-4350.app",
                persistenceDisabled: false
            )
        )
    }

    func testBundleIconPersistenceRejectsMismatchedStableIdentifierAndPath() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app",
                appBundleLastPathComponent: "cmux NIGHTLY.app",
                persistenceDisabled: false
            )
        )
    }

    func testBundleIconPersistenceSkipsDebugBundles() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.debug",
                appBundleLastPathComponent: "cmux DEV.app",
                persistenceDisabled: false
            )
        )
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.debug.issue-4350",
                appBundleLastPathComponent: "cmux DEV issue-4350.app",
                persistenceDisabled: false
            )
        )
    }

    func testBundleIconPersistenceHonorsDisableDefault() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app",
                appBundleLastPathComponent: "cmux.app",
                persistenceDisabled: true
            )
        )
    }

    func testBundleIconPersistenceMirrorsSmokeLaunchArgumentToDefaults() {
        let suiteName = "AppearanceSettingsTests.BundleIconPersistence.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppBundleIconPersistencePolicy.updateDisableDefault(
            defaults: defaults,
            launchArguments: [AppBundleIconPersistencePolicy.disablePersistenceArgument]
        )
        XCTAssertEqual(
            defaults.object(forKey: AppBundleIconPersistencePolicy.disablePersistenceDefaultsKey) as? Bool,
            true
        )

        AppBundleIconPersistencePolicy.updateDisableDefault(
            defaults: defaults,
            launchArguments: []
        )
        XCTAssertEqual(
            defaults.object(forKey: AppBundleIconPersistencePolicy.disablePersistenceDefaultsKey) as? Bool,
            false
        )
    }

    func testAppConfigReloadRefreshUpdatesSurfaceConfigBeforeRedraw() throws {
        let fakeSurface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x3851))
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: fakeSurface,
            source: "appearanceSync:test",
            reloadSurfaceConfiguration: { surface, soft, source in
                XCTAssertEqual(surface, fakeSurface)
                XCTAssertTrue(soft)
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

        XCTAssertEqual(events, [
            "color-scheme",
            "reload:appearanceSync:test",
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    func testAppConfigReloadRefreshSkipsSurfaceConfigUpdateWhenSurfaceIsUnavailable() {
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

        XCTAssertEqual(events, [
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    func testAppConfigReloadRefreshAppliesSurfaceColorSchemeForPreviewReload() throws {
        let fakeSurface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x3852))
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: fakeSurface,
            source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource,
            reloadSurfaceConfiguration: { _, soft, source in
                XCTAssertTrue(soft)
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

        XCTAssertEqual(events, [
            "color-scheme",
            "reload:\(GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource)",
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    func testCmuxThemeFinalReloadUsesFinalSource() {
        XCTAssertEqual(
            GhosttySurfaceConfigurationRefresh.cmuxThemeReloadSource(phase: "final"),
            GhosttySurfaceConfigurationRefresh.cmuxThemeReloadFinalSource
        )
    }

    func testCmuxThemePreviewReloadIsDebounced() {
        XCTAssertEqual(
            GhosttySurfaceConfigurationRefresh.cmuxThemeReloadSource(phase: "preview"),
            GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource
        )
        XCTAssertTrue(
            GhosttySurfaceConfigurationRefresh.shouldDebounceCmuxThemeReload(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource
            )
        )
        XCTAssertTrue(
            GhosttySurfaceConfigurationRefresh.shouldDebounceCmuxThemeReload(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadLegacySource
            )
        )
        XCTAssertFalse(
            GhosttySurfaceConfigurationRefresh.shouldDebounceCmuxThemeReload(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadFinalSource
            )
        )
    }

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

    func testSplitGhosttyThemeUsesStoredDarkModeWhenAppAppearanceIsStaleLight() {
        let suiteName = "AppearanceSettingsTests.SplitThemeStoredDark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.dark.rawValue, forKey: AppearanceSettings.appearanceModeKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            appAppearance: NSAppearance(named: .aqua),
            defaults: defaults,
            systemAppearance: .init(interfaceStyle: "Dark")
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Catppuccin Latte,dark:Apple System Colors",
            preferredColorScheme: preferredColorScheme
        )

        XCTAssertEqual(preferredColorScheme, .dark)
        XCTAssertEqual(resolvedTheme, "Apple System Colors")
    }

    func testSplitGhosttyThemeUsesStoredLightModeWhenAppAppearanceIsStaleDark() {
        let suiteName = "AppearanceSettingsTests.SplitThemeStoredLight.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.light.rawValue, forKey: AppearanceSettings.appearanceModeKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            appAppearance: NSAppearance(named: .darkAqua),
            defaults: defaults,
            systemAppearance: .init(interfaceStyle: "Dark")
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Catppuccin Latte,dark:Apple System Colors",
            preferredColorScheme: preferredColorScheme
        )

        XCTAssertEqual(preferredColorScheme, .light)
        XCTAssertEqual(resolvedTheme, "Catppuccin Latte")
    }

    func testSplitGhosttyThemeUsesSystemLightWhenAppAppearanceIsStaleDark() {
        let suiteName = "AppearanceSettingsTests.SplitThemeSystemLight.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        defaults.removeObject(forKey: "AppleInterfaceStyle")

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            appAppearance: NSAppearance(named: .darkAqua),
            defaults: defaults,
            systemAppearance: .init(interfaceStyle: nil)
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Monokai Pro Light,dark:Monokai Pro Machine",
            preferredColorScheme: preferredColorScheme
        )

        XCTAssertEqual(preferredColorScheme, .light)
        XCTAssertEqual(resolvedTheme, "Monokai Pro Light")
    }

    func testSplitGhosttyThemeUsesSystemDarkWhenAppAppearanceIsStaleLight() {
        let suiteName = "AppearanceSettingsTests.SplitThemeSystemDark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            appAppearance: NSAppearance(named: .aqua),
            defaults: defaults,
            systemAppearance: .init(interfaceStyle: "Dark")
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Monokai Pro Light,dark:Monokai Pro Machine",
            preferredColorScheme: preferredColorScheme
        )

        XCTAssertEqual(preferredColorScheme, .dark)
        XCTAssertEqual(resolvedTheme, "Monokai Pro Machine")
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

    func testDefaultsObserverAppliesLiveAppearanceWhenStoredModeChanges() {
        let suiteName = "AppearanceSettingsTests.DefaultsObserver.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
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
                XCTFail("Dark mode should not resolve system appearance")
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

        XCTAssertEqual(appliedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedSource, "test.defaultsObserver")
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

final class SystemAppearanceObserverTests: XCTestCase {
    private final class ObservationToken: EffectiveAppearanceObservation {
        private(set) var invalidateCallCount = 0

        func invalidate() {
            invalidateCallCount += 1
        }
    }

    private final class Harness {
        var modeRawValue: String? = AppearanceMode.system.rawValue
        var prefersDark = false
        var startObservationReturnsNil = false
        var startObservationCallCount = 0
        var systemPrefersDarkCallCount = 0
        var events: [String] = []
        var onSetApplicationAppearance: ((NSAppearance?) -> Void)?
        private(set) var appearanceChangedHandler: (() -> Void)?
        private(set) var scheduledBlock: (() -> Void)?
        let observation = ObservationToken()

        lazy var environment = SystemAppearanceObserver.Environment(
            startEffectiveAppearanceObservation: { [unowned self] handler in
                self.startObservationCallCount += 1
                self.appearanceChangedHandler = handler
                return self.startObservationReturnsNil ? nil : self.observation
            },
            currentAppearanceModeRawValue: { [unowned self] in
                self.modeRawValue
            },
            systemPrefersDark: { [unowned self] in
                self.systemPrefersDarkCallCount += 1
                return self.prefersDark
            },
            setApplicationAppearance: { [unowned self] appearance in
                self.events.append("setApplicationAppearance(\(appearance?.name.rawValue ?? "nil"))")
                self.onSetApplicationAppearance?(appearance)
            },
            synchronizeTerminalThemeWithAppearance: { [unowned self] appearance, source in
                self.events.append("synchronizeTerminalThemeWithAppearance(\(appearance?.name.rawValue ?? "nil"), \(source))")
            },
            postSystemAppearanceDidChange: { [unowned self] in
                self.events.append("postSystemAppearanceDidChange")
            },
            scheduleOnMainQueue: { [unowned self] block in
                self.scheduledBlock = block
            }
        )

        func fireEffectiveAppearanceChanged() {
            appearanceChangedHandler?()
        }

        func runScheduledBlock() {
            let block = scheduledBlock
            scheduledBlock = nil
            block?()
        }
    }

    func testSystemModeAppearanceFlipKicksConcreteThenNilAndPostsNotification() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()

        XCTAssertEqual(harness.startObservationCallCount, 1)
        XCTAssertTrue(harness.events.isEmpty)

        harness.prefersDark = true
        harness.fireEffectiveAppearanceChanged()

        let darkAquaName = NSAppearance.Name.darkAqua.rawValue
        XCTAssertEqual(harness.events, [
            "setApplicationAppearance(\(darkAquaName))",
            "synchronizeTerminalThemeWithAppearance(\(darkAquaName), cmuxApp.systemAppearanceObserver)",
            "postSystemAppearanceDidChange"
        ])

        harness.runScheduledBlock()

        XCTAssertEqual(harness.events.count, 4)
        XCTAssertEqual(harness.events.last, "setApplicationAppearance(nil)")
    }

    func testSystemModeAppearanceFlipToLightKicksConcreteThenNilAndPostsNotification() {
        let harness = Harness()
        harness.prefersDark = true
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()

        XCTAssertTrue(harness.events.isEmpty)

        harness.prefersDark = false
        harness.fireEffectiveAppearanceChanged()

        let aquaName = NSAppearance.Name.aqua.rawValue
        XCTAssertEqual(harness.events, [
            "setApplicationAppearance(\(aquaName))",
            "synchronizeTerminalThemeWithAppearance(\(aquaName), cmuxApp.systemAppearanceObserver)",
            "postSystemAppearanceDidChange"
        ])

        harness.runScheduledBlock()

        XCTAssertEqual(harness.events.count, 4)
        XCTAssertEqual(harness.events.last, "setApplicationAppearance(nil)")
    }

    func testExplicitModeIgnoresEffectiveAppearanceChanges() {
        let harness = Harness()
        harness.modeRawValue = AppearanceMode.dark.rawValue
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        let callCountBeforeFire = harness.systemPrefersDarkCallCount
        harness.fireEffectiveAppearanceChanged()

        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertEqual(harness.systemPrefersDarkCallCount, callCountBeforeFire)
    }

    func testUnchangedResolvedAppearanceIsCoalesced() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.fireEffectiveAppearanceChanged()
        harness.fireEffectiveAppearanceChanged()

        XCTAssertTrue(harness.events.isEmpty)

        harness.prefersDark = true
        harness.fireEffectiveAppearanceChanged()

        let darkAquaName = NSAppearance.Name.darkAqua.rawValue
        XCTAssertEqual(harness.events, [
            "setApplicationAppearance(\(darkAquaName))",
            "synchronizeTerminalThemeWithAppearance(\(darkAquaName), cmuxApp.systemAppearanceObserver)",
            "postSystemAppearanceDidChange"
        ])

        // Pins that lastResolvedPrefersDark is updated on every apply, not just seeded at startObserving().
        harness.fireEffectiveAppearanceChanged()

        XCTAssertEqual(harness.events.count, 3)
    }

    func testReentrantFireDuringKickDoesNotLoop() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        // Simulate our own NSApplication.appearance write re-firing KVO with the
        // same resolved value; bound the re-entrancy so a regression cannot hang
        // the suite.
        var reentrantFireCount = 0
        harness.onSetApplicationAppearance = { [unowned harness] _ in
            guard reentrantFireCount < 2 else { return }
            reentrantFireCount += 1
            harness.fireEffectiveAppearanceChanged()
        }

        observer.startObserving()
        harness.prefersDark = true
        harness.fireEffectiveAppearanceChanged()

        let darkAquaName = NSAppearance.Name.darkAqua.rawValue
        XCTAssertEqual(harness.events, [
            "setApplicationAppearance(\(darkAquaName))",
            "synchronizeTerminalThemeWithAppearance(\(darkAquaName), cmuxApp.systemAppearanceObserver)",
            "postSystemAppearanceDidChange"
        ])

        harness.runScheduledBlock()

        XCTAssertEqual(harness.events, [
            "setApplicationAppearance(\(darkAquaName))",
            "synchronizeTerminalThemeWithAppearance(\(darkAquaName), cmuxApp.systemAppearanceObserver)",
            "postSystemAppearanceDidChange",
            "setApplicationAppearance(nil)"
        ])
        XCTAssertEqual(reentrantFireCount, 2)
    }

    func testNilRestoreSkippedWhenModeLeftSystemBeforeTick() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.prefersDark = true
        harness.fireEffectiveAppearanceChanged()

        let eventCountBeforeTick = harness.events.count
        harness.modeRawValue = AppearanceMode.dark.rawValue
        harness.runScheduledBlock()

        XCTAssertEqual(harness.events.count, eventCountBeforeTick)
    }

    func testFireAfterStopObservingProducesNoEvents() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()

        harness.prefersDark = true
        let callCountBeforeFire = harness.systemPrefersDarkCallCount
        harness.fireEffectiveAppearanceChanged()

        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertEqual(harness.systemPrefersDarkCallCount, callCountBeforeFire)
    }

    func testStartObservingIsIdempotentAndStopTearsDown() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.startObserving()

        XCTAssertEqual(harness.startObservationCallCount, 1)

        observer.stopObserving()

        XCTAssertEqual(harness.observation.invalidateCallCount, 1)

        observer.startObserving()

        XCTAssertEqual(harness.startObservationCallCount, 2)
    }

    func testStartObservingWithNilObservationIsNotIdempotent() {
        let harness = Harness()
        harness.startObservationReturnsNil = true
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.startObserving()

        // Documents current behavior: an observation-less start does not latch, so repeated startObserving() calls re-invoke the start closure.
        XCTAssertEqual(harness.startObservationCallCount, 2)
    }
}
