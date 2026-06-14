import CmuxMobileTerminal
import Foundation
import Testing
import UIKit

/// Behavioral tests for ``TerminalKeyboardConfiguration``: the source of truth
/// for whether the mobile terminal keyboard's inline autocomplete suggestions
/// are enabled (issue #6083). These verify the terminal-hardened default (off,
/// with no write), the persistence round-trip in both directions, and the
/// change-notification contract that drives the live input view's trait
/// re-application.
///
/// Each test injects a private `UserDefaults` suite so it never touches the live
/// app-root settings.
@MainActor
@Suite("TerminalKeyboardConfiguration")
struct TerminalKeyboardConfigurationTests {
    private static let storageKey = "cmux.terminal.keyboard.autocompleteEnabled.v1"

    /// A fresh suite-scoped defaults store, cleared so each test starts empty.
    private func freshDefaults() -> UserDefaults {
        let name = "cmux.keyboard.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("defaults to disabled and reading the default does not persist a value")
    func defaultsToDisabledWithoutAWrite() {
        let defaults = freshDefaults()
        let config = TerminalKeyboardConfiguration(defaults: defaults)

        #expect(config.autocompleteEnabled == false)
        // Constructing/reading the default must not write the key.
        #expect(defaults.object(forKey: Self.storageKey) == nil)
    }

    @Test("enabling persists across instances")
    func enablingPersistsAcrossInstances() {
        let defaults = freshDefaults()
        let config = TerminalKeyboardConfiguration(defaults: defaults)

        config.autocompleteEnabled = true

        #expect(TerminalKeyboardConfiguration(defaults: defaults).autocompleteEnabled == true)
    }

    @Test("disabling after enabling persists across instances")
    func disablingPersistsAcrossInstances() {
        let defaults = freshDefaults()
        let config = TerminalKeyboardConfiguration(defaults: defaults)

        config.autocompleteEnabled = true
        config.autocompleteEnabled = false

        #expect(TerminalKeyboardConfiguration(defaults: defaults).autocompleteEnabled == false)
    }

    @Test("a stored true is read back on init")
    func readsStoredTrueOnInit() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: Self.storageKey)

        #expect(TerminalKeyboardConfiguration(defaults: defaults).autocompleteEnabled == true)
    }

    @Test("autocomplete maps to explicit inline prediction traits")
    func autocompleteMapsToExplicitInlinePredictionTraits() {
        #expect(TerminalKeyboardConfiguration.inlinePredictionType(autocompleteEnabled: true) == .yes)
        #expect(TerminalKeyboardConfiguration.inlinePredictionType(autocompleteEnabled: false) == .no)
    }

    @Test("a real change posts exactly one notification; a no-op set posts none")
    func togglingPostsChangeNotificationOnlyForRealChanges() async {
        let config = TerminalKeyboardConfiguration(defaults: freshDefaults())

        await confirmation("posts once for the change, not for the no-op", expectedCount: 1) { confirmed in
            // queue: nil delivers synchronously on the posting (main) thread, so
            // the post lands inside the mutation before the body returns.
            let token = NotificationCenter.default.addObserver(
                forName: TerminalKeyboardConfiguration.didChangeNotification,
                object: config,
                queue: nil
            ) { _ in confirmed() }
            defer { NotificationCenter.default.removeObserver(token) }

            config.autocompleteEnabled = true // false -> true: posts
            config.autocompleteEnabled = true // unchanged: must not post
        }
    }
}
