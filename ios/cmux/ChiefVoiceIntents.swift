import AppIntents
import CmuxiOSApp

// App Intents for the iPhone Action Button, Siri, Spotlight, Shortcuts and the
// iOS 18 Shortcuts control in Control Center and on the Lock Screen
// (plans/cmux-next/ios-action-button-DESIGN.md). They live in the app target
// because App Intents metadata is extracted from the main bundle; each perform()
// is a one-line forward into the CmuxiOS package.

/// Opens cmux into a recording call with the user's Chief.
struct CallChiefIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.callChief.title"
    static let description = IntentDescription("intent.callChief.description")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CmuxiOSApplication.handle(.call)
        return .result()
    }
}

/// Opens cmux and records a voice note for the user's Chief.
struct RecordChiefVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.recordVoiceNote.title"
    static let description = IntentDescription("intent.recordVoiceNote.description")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CmuxiOSApplication.handle(.voiceNote)
        return .result()
    }
}

/// The App Shortcuts the Action Button setting and Siri list for cmux.
struct CmuxAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CallChiefIntent(),
            phrases: [
                "Call my Chief in \(.applicationName)",
                "Call Chief in \(.applicationName)",
                "Talk to my Chief in \(.applicationName)",
            ],
            shortTitle: "shortcut.callChief.shortTitle",
            systemImageName: "phone.fill"
        )
        AppShortcut(
            intent: RecordChiefVoiceNoteIntent(),
            phrases: [
                "Record a voice note for my Chief in \(.applicationName)",
                "Voice note for Chief in \(.applicationName)",
            ],
            shortTitle: "shortcut.recordVoiceNote.shortTitle",
            systemImageName: "waveform"
        )
    }
}
