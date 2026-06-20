import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Behavioral tests for ``TerminalKeyboardConfiguration``: the source of truth
/// for whether the mobile terminal keyboard's autocomplete and correction traits
/// are enabled (issue #6083). These verify the terminal-hardened default (off,
/// with no write), the persistence round-trip in both directions, the UIKit trait
/// application, and the change-notification contract that drives the live input
/// view's trait re-application.
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

    @Test("autocomplete maps to system-default inline prediction traits when enabled")
    func autocompleteMapsToSystemDefaultInlinePredictionTraitsWhenEnabled() {
        #expect(TerminalKeyboardConfiguration.inlinePredictionType(autocompleteEnabled: true) == .default)
        #expect(TerminalKeyboardConfiguration.inlinePredictionType(autocompleteEnabled: false) == .no)
    }

    @Test("autocomplete preference applies every configurable UIKit keyboard trait")
    func autocompletePreferenceAppliesConfigurableKeyboardTraits() {
        let config = TerminalKeyboardConfiguration(defaults: freshDefaults())
        let view = TerminalInputTextView(keyboardConfiguration: config)

        #expect(view.autocorrectionType == .no)
        #expect(view.smartQuotesType == .no)
        #expect(view.smartDashesType == .no)
        #expect(view.smartInsertDeleteType == .no)
        #expect(view.spellCheckingType == .no)
        #expect(view.inlinePredictionType == .no)
        #expect(view.autocapitalizationType == .none)

        config.autocompleteEnabled = true

        #expect(view.autocorrectionType == .default)
        #expect(view.smartQuotesType == .default)
        #expect(view.smartDashesType == .default)
        #expect(view.smartInsertDeleteType == .default)
        #expect(view.spellCheckingType == .default)
        #expect(view.inlinePredictionType == .default)
        #expect(view.autocapitalizationType == .none)

        config.autocompleteEnabled = false

        #expect(view.autocorrectionType == .no)
        #expect(view.smartQuotesType == .no)
        #expect(view.smartDashesType == .no)
        #expect(view.smartInsertDeleteType == .no)
        #expect(view.spellCheckingType == .no)
        #expect(view.inlinePredictionType == .no)
        #expect(view.autocapitalizationType == .none)
    }

    @Test("autocorrection replacements edit already-sent terminal text")
    func autocorrectionReplacementEditsAlreadySentTerminalText() {
        let config = TerminalKeyboardConfiguration(defaults: freshDefaults())
        config.autocompleteEnabled = true
        let view = TerminalInputTextView(keyboardConfiguration: config)
        var textEvents: [String] = []
        var backspaces = 0
        var escapeSequences: [Data] = []
        view.onText = { textEvents.append($0) }
        view.onBackspace = { backspaces += 1 }
        view.onEscapeSequence = { escapeSequences.append($0) }

        view.insertText("echo ")
        view.insertText("teh ")
        view.simulateTextChangeForTesting("the ", isComposing: false)

        #expect(textEvents == ["echo ", "teh ", "he"])
        #expect(backspaces == 2)
        #expect(escapeSequences == [
            Data([0x1B, 0x5B, 0x44]),
            Data([0x1B, 0x5B, 0x43]),
        ])
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
