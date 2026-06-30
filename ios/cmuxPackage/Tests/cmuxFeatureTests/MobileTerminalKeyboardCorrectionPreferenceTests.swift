#if canImport(UIKit)
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Mobile terminal keyboard corrections")
struct MobileTerminalKeyboardCorrectionPreferenceTests {
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = [
            "MobileTerminalKeyboardCorrectionPreferenceTests",
            name,
            UUID().uuidString,
        ].joined(separator: ".")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("keyboard corrections default off without writing the default")
    func defaultsOffWithoutWriting() throws {
        let defaults = try freshDefaults("defaults")
        let preference = MobileTerminalKeyboardCorrectionPreference(defaults: defaults)

        #expect(preference.isEnabled == false)
        #expect(
            defaults.object(forKey: MobileTerminalKeyboardCorrectionPreference.enabledDefaultsKey) == nil
        )

        let view = TerminalInputTextView(keyboardCorrectionPreference: preference)
        #expect(view.autocorrectionType == .no)
        #expect(view.spellCheckingType == .no)
        #expect(view.smartInsertDeleteType == .no)
        #expect(view.autocapitalizationType == .none)
        #expect(view.smartQuotesType == .no)
        #expect(view.smartDashesType == .no)
    }

    @Test("enabling keyboard corrections persists across preference instances")
    func enablingPersistsAcrossInstances() throws {
        let defaults = try freshDefaults("persists")
        let preference = MobileTerminalKeyboardCorrectionPreference(defaults: defaults)

        preference.isEnabled = true

        #expect(defaults.bool(forKey: MobileTerminalKeyboardCorrectionPreference.enabledDefaultsKey))
        let reloaded = MobileTerminalKeyboardCorrectionPreference(defaults: defaults)
        #expect(reloaded.isEnabled)
    }

    @Test("terminal input traits follow the injected preference live")
    func inputTraitsFollowPreference() throws {
        let defaults = try freshDefaults("traits")
        let preference = MobileTerminalKeyboardCorrectionPreference(defaults: defaults)
        let view = TerminalInputTextView(keyboardCorrectionPreference: preference)

        #expect(view.autocorrectionType == .no)
        #expect(view.spellCheckingType == .no)
        #expect(view.smartInsertDeleteType == .no)

        preference.isEnabled = true
        #expect(view.autocorrectionType == .yes)
        #expect(view.spellCheckingType == .yes)
        #expect(view.smartInsertDeleteType == .yes)

        preference.isEnabled = false
        #expect(view.autocorrectionType == .no)
        #expect(view.spellCheckingType == .no)
        #expect(view.smartInsertDeleteType == .no)
    }
}
#endif
