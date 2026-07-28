import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Command palette settings toggle actions")
struct CommandPaletteSettingsToggleActionTests {
    @Test
    func everyContributionDeclaresOptionalBooleanEnabledArgument() {
        let expectedArgument = CmuxActionArgumentDefinition(
            name: "enabled",
            valueType: .boolean,
            required: false
        )

        for contribution in ContentView.commandPaletteSettingsToggleCommandContributions() {
            #expect(
                contribution.arguments == [expectedArgument],
                "\(contribution.commandId) must expose deterministic state setting"
            )
        }
    }

    @Test
    func interactiveInvocationWithoutEnabledArgumentPreservesToggleBehavior() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.iMessageMode"
                )
            )
            #expect(!descriptor.isOn(defaults))

            let result = CommandPaletteSettingsToggleCommands.execute(
                descriptor,
                invocation: CmuxActionInvocation(source: .commandPalette),
                defaults: defaults,
                notificationCenter: NotificationCenter()
            )

            #expect(result == .completed)
            #expect(descriptor.isOn(defaults))
        }
    }

    @Test
    func automationEnabledArgumentSetsStateDeterministically() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.iMessageMode"
                )
            )
            let enable = CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "true"]
            )
            let disable = CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "false"]
            )

            #expect(
                CommandPaletteSettingsToggleCommands.execute(
                    descriptor,
                    invocation: enable,
                    defaults: defaults,
                    notificationCenter: NotificationCenter()
                ) == .completed
            )
            #expect(descriptor.isOn(defaults))
            #expect(
                CommandPaletteSettingsToggleCommands.execute(
                    descriptor,
                    invocation: enable,
                    defaults: defaults,
                    notificationCenter: NotificationCenter()
                ) == .completed
            )
            #expect(descriptor.isOn(defaults))
            #expect(
                CommandPaletteSettingsToggleCommands.execute(
                    descriptor,
                    invocation: disable,
                    defaults: defaults,
                    notificationCenter: NotificationCenter()
                ) == .completed
            )
            #expect(!descriptor.isOn(defaults))
        }
    }

    @Test
    func unavailableToggleReturnsTypedFailureWithoutMutation() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.showInMenuBar"
                )
            )
            defaults.set(false, forKey: MenuBarExtraSettings.showInMenuBarKey)
            defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)

            let result = CommandPaletteSettingsToggleCommands.execute(
                descriptor,
                invocation: CmuxActionInvocation(
                    source: .automation,
                    arguments: ["enabled": "true"]
                ),
                defaults: defaults,
                notificationCenter: NotificationCenter()
            )

            #expect(
                result == .failed(
                    code: "action_unavailable",
                    message: String(
                        localized: "action.error.notApplicable",
                        defaultValue: "The action does not apply to the target's current state."
                    )
                )
            )
            #expect(!descriptor.isOn(defaults))
        }
    }

    @Test
    func toggleReportsFailureWhenMutationCannotBeConfirmed() throws {
        try withTemporaryDefaults { defaults in
            let key = "test.setting"
            let descriptor = CommandPaletteSettingToggleDescriptor(
                commandId: "palette.toggleSetting.test",
                settingsKey: key,
                title: { "Test" },
                sectionTitle: { "Test" },
                keywords: [],
                isOn: { $0.bool(forKey: key) },
                setOn: { _, _, _ in }
            )

            let result = CommandPaletteSettingsToggleCommands.execute(
                descriptor,
                invocation: CmuxActionInvocation(
                    source: .automation,
                    arguments: ["enabled": "true"]
                ),
                defaults: defaults,
                notificationCenter: NotificationCenter()
            )

            #expect(
                result == .failed(
                    code: "action_failed",
                    message: String(
                        localized: "action.error.configuredActionFailed",
                        defaultValue: "The configured action could not be started."
                    )
                )
            )
            #expect(!descriptor.isOn(defaults))
        }
    }

    private func withTemporaryDefaults(
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "cmux.commandPaletteSettingsToggle.action.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
