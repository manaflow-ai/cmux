import AppKit
import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal appearance authority")
struct GhosttyAppearanceAuthorityTests {
    @Test(arguments: [false, true])
    func stalePaneCannotReverseSystemThemeTransition(toDark: Bool) throws {
        let suite = "GhosttyAppearanceAuthorityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("system", forKey: AppearanceSettings.appearanceModeKey)
        defaults.set(toDark ? "Light" : "Dark", forKey: "AppleInterfaceStyle")

        let previous = try #require(NSAppearance(named: toDark ? .aqua : .darkAqua))
        let current = try #require(NSAppearance(named: toDark ? .darkAqua : .aqua))
        // A detached/reparented native pane can retain its prior appearance
        // while the application observer has already seen the system switch.
        let pane = NSView(frame: .zero)
        pane.appearance = previous
        let expected: GhosttyConfig.ColorSchemePreference = toDark ? .dark : .light
        var committed: GhosttyConfig.ColorSchemePreference = toDark ? .light : .dark
        var reloadCount = 0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-11307-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let light = directory.appendingPathComponent("light")
        let dark = directory.appendingPathComponent("dark")
        try "background = #FAFBFC\nforeground = #101112\npalette = 1=#A02030\n".write(
            to: light, atomically: true, encoding: .utf8
        )
        try "background = #101112\nforeground = #FAFBFC\npalette = 1=#F08090\n".write(
            to: dark, atomically: true, encoding: .utf8
        )

        // Application notification, delayed pane notifications, then a manual
        // reload with no passed appearance must all select the same palette.
        for observation: NSAppearance? in [current, pane.effectiveAppearance, previous, nil] {
            let resolved = GhosttyConfig.appearanceSyncColorSchemePreference(
                passedAppearance: observation,
                defaults: defaults,
                isApplicationFinishedLaunching: { true },
                liveEffectiveAppearance: { current }
            ).preference
            let plan = GhosttyApp.appearanceSynchronizationPlan(
                previousColorScheme: committed,
                currentColorScheme: resolved
            )
            if plan.shouldReloadConfiguration { reloadCount += 1 }
            committed = resolved
            var config = GhosttyConfig()
            config.loadTheme(
                "light:\(light.path),dark:\(dark.path)",
                environment: [:],
                bundleResourceURL: nil,
                preferredColorScheme: resolved
            )
            #expect(resolved == expected)
            #expect(config.backgroundColor.hexString() == (toDark ? "#101112" : "#FAFBFC"))
            #expect(config.foregroundColor.hexString() == (toDark ? "#FAFBFC" : "#101112"))
            #expect(config.palette[1]?.hexString() == (toDark ? "#F08090" : "#A02030"))
        }
        #expect(reloadCount == 1)
    }

    @Test(arguments: ["light", "dark"])
    func explicitAppModeStillWins(mode: String) throws {
        let suite = "GhosttyAppearanceAuthorityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(mode, forKey: AppearanceSettings.appearanceModeKey)
        let opposite = NSAppearance(named: mode == "light" ? .darkAqua : .aqua)
        let resolved = GhosttyConfig.appearanceSyncColorSchemePreference(
            passedAppearance: opposite,
            defaults: defaults,
            isApplicationFinishedLaunching: { true },
            liveEffectiveAppearance: {
                Issue.record("Explicit app mode must not consult the system appearance")
                return opposite
            }
        ).preference
        #expect(resolved == (mode == "light" ? .light : .dark))
    }

    @Test
    func fixedGhosttyThemeIsPreservedWhenAppBecomesLight() throws {
        let suite = "GhosttyAppearanceAuthorityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("system", forKey: AppearanceSettings.appearanceModeKey)
        let theme = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-11307-fixed-\(UUID().uuidString)")
        try "background = #121314\nforeground = #E1E2E3\npalette = 1=#C04050\n".write(
            to: theme, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: theme) }
        let resolved = GhosttyConfig.appearanceSyncColorSchemePreference(
            passedAppearance: NSAppearance(named: .darkAqua),
            defaults: defaults,
            isApplicationFinishedLaunching: { true },
            liveEffectiveAppearance: { NSAppearance(named: .aqua) }
        ).preference
        var config = GhosttyConfig()
        config.loadTheme(theme.path, environment: [:], bundleResourceURL: nil, preferredColorScheme: resolved)
        #expect(config.backgroundColor.hexString() == "#121314")
        #expect(config.foregroundColor.hexString() == "#E1E2E3")
        #expect(config.palette[1]?.hexString() == "#C04050")
        #expect(GhosttyApp.terminalRuntimeColorSchemePreference(forBackgroundColor: config.backgroundColor) == .dark)
    }

    @Test(arguments: [false, true])
    func passedAppearanceRemainsFallbackWhenAppAppearanceIsUnavailable(launched: Bool) throws {
        let suite = "GhosttyAppearanceAuthorityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("system", forKey: AppearanceSettings.appearanceModeKey)
        defaults.set("Dark", forKey: "AppleInterfaceStyle")
        let resolved = GhosttyConfig.appearanceSyncColorSchemePreference(
            passedAppearance: NSAppearance(named: .aqua),
            defaults: defaults,
            isApplicationFinishedLaunching: { launched },
            liveEffectiveAppearance: {
                #expect(launched, "Do not read AppKit's appearance before didFinishLaunching on Tahoe")
                return nil
            }
        ).preference
        #expect(resolved == .light)
    }
}
