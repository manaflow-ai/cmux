import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal hyperlink activation command palette")
struct TerminalHyperlinkActivationCommandPaletteTests {
    @Test
    func commandTogglesSetting() throws {
        let suiteName = "cmux.terminalHyperlinkActivationCommandPalette.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let descriptor = try #require(
            CommandPaletteSettingsToggleCommands.descriptor(
                commandId: "palette.toggleSetting.terminalHyperlinkActivationEnabled"
            )
        )

        #expect(descriptor.isOn(defaults))
        descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

        #expect(
            defaults.object(
                forKey: BrowserLinkOpenSettings.terminalHyperlinkActivationEnabledKey
            ) as? Bool == false
        )
        #expect(!descriptor.isOn(defaults))
    }
}
