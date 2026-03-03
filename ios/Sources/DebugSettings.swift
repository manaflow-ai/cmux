import Foundation

enum DebugSettingsKeys {
    static let showChatOverlays = "cmux.debug.showChatOverlays"
    static let showChatInputTuning = "cmux.debug.showChatInputTuning"
}

enum DebugSettings {
    static var showChatOverlays: Bool {
        UserDefaults.standard.bool(forKey: DebugSettingsKeys.showChatOverlays)
    }

    static var showChatInputTuning: Bool {
        UserDefaults.standard.bool(forKey: DebugSettingsKeys.showChatInputTuning)
    }
}
