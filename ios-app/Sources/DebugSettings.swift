import Foundation

enum DebugSettingsKeys {
    static let showChatOverlays = "cmux.debug.showChatOverlays"
}

enum DebugSettings {
    static var showChatOverlays: Bool {
        UserDefaults.standard.bool(forKey: DebugSettingsKeys.showChatOverlays)
    }
}
