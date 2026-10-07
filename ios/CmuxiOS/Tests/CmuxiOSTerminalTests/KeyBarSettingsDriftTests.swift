import CmuxiOSSettingsCore
import CmuxiOSTerminal
import Testing

/// Settings stores key bar keys by id (`KeyBarKeyID`); the renderer reads
/// them as `TerminalKeyBarKey`. The two lists must stay equal.
@Suite struct KeyBarSettingsDriftTests {
    @Test func settingsIdsAreTheRendererIds() {
        #expect(KeyBarKeyID.allCases.map(\.rawValue) == TerminalKeyBarKey.allCases.map(\.rawValue))
        #expect(KeyBarKeyID.defaultOrder.map(\.rawValue) == TerminalKeyBarKey.defaultKeys.map(\.rawValue))
    }

    @Test func settingsAppearanceRoundTripsThroughTheRendererParser() {
        let ids = TerminalPreferences(keyBarKeys: [.paste, .escape]).appearance.keyBarKeyIDs
        #expect(TerminalKeyBarKey.keys(fromSetting: ids) == [.paste, .escape])
    }
}
