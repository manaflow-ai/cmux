import Foundation

/// Copy of the keep-awake card (lane E5).
struct KeepAwakeStepText {
    static var title: String { String(localized: "onboarding.keepAwake.title", defaultValue: "Keep your Mac awake.", bundle: .module) }
    static var body: String {
        String(localized: "onboarding.keepAwake.body",
               defaultValue: "Agents keep working while you are away. cmux can stop your Mac from sleeping while it is plugged in.",
               bundle: .module)
    }
    static var checking: String { String(localized: "onboarding.keepAwake.checking", defaultValue: "Checking…", bundle: .module) }
    static var unavailable: String {
        String(localized: "onboarding.keepAwake.unavailable", defaultValue: "Needs a newer cmux on this Mac", bundle: .module)
    }
    static var noMacs: String {
        String(localized: "onboarding.keepAwake.noMacs", defaultValue: "Pair a Mac to turn this on.", bundle: .module)
    }
}
