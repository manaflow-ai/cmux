import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5457:
/// holding a key (e.g. `l` for vim motions) popped up the macOS
/// alternate-character picker instead of repeating the key into the terminal.
/// cmux disables the press-and-hold accent popup at launch by registering
/// `ApplePressAndHoldEnabled = false` in its registration domain (matching
/// Ghostty), so held keys repeat.
@Suite(.serialized) struct PressAndHoldDefaultsTests {
    private func makeScratchDefaults(
        function: String = #function
    ) throws -> (UserDefaults, String) {
        let suiteName = "PressAndHoldDefaultsTests.\(function)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test func registersPressAndHoldDisabledByDefault() throws {
        let (defaults, suiteName) = try makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PressAndHoldDefaults(defaults: defaults).registerDisabled()

        // With no explicit user preference, the registration domain must resolve
        // the key to a concrete `false` so held keys repeat into the terminal
        // instead of opening the macOS alternate-character picker. Without the
        // fix the key is absent entirely (object == nil) — the exact state in
        // which macOS shows the popup — so this is red without the fix.
        #expect(
            defaults.object(forKey: PressAndHoldDefaults.pressAndHoldEnabledKey) != nil,
            "Expected cmux to register a value for ApplePressAndHoldEnabled at launch"
        )
        #expect(
            defaults.bool(forKey: PressAndHoldDefaults.pressAndHoldEnabledKey) == false,
            "Expected the press-and-hold accent popup to be disabled"
        )
    }

    @Test func usesTheKeyMacOSReadsForPressAndHold() {
        // Guard against a typo silently re-enabling the popup: macOS only honors
        // this exact key name.
        #expect(PressAndHoldDefaults.pressAndHoldEnabledKey == "ApplePressAndHoldEnabled")
    }

    @Test func doesNotOverrideAnExplicitUserPreference() throws {
        let (defaults, suiteName) = try makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A user who explicitly opts the popup back on (e.g. via
        // `defaults write -g ApplePressAndHoldEnabled -bool true`) must win:
        // registration-domain defaults are the lowest-priority source, so the
        // explicit value takes precedence over our registered fallback.
        defaults.set(true, forKey: PressAndHoldDefaults.pressAndHoldEnabledKey)

        PressAndHoldDefaults(defaults: defaults).registerDisabled()

        #expect(
            defaults.bool(forKey: PressAndHoldDefaults.pressAndHoldEnabledKey) == true,
            "An explicit user preference must take precedence over the registered default"
        )
    }
}
