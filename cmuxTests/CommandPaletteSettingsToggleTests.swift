import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CommandPaletteSettingsToggleTests {
    @Test
    func testIMessageModeCommandTogglesDefaultAndReportsState() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.iMessageMode"
                )
            )

            let settingTitle = String(localized: "settings.app.iMessageMode", defaultValue: "iMessage Mode")
            let enableTitle = String.localizedStringWithFormat(
                String(localized: "command.toggleSetting.enableTitle", defaultValue: "Enable %@"),
                settingTitle
            )
            let disableTitle = String.localizedStringWithFormat(
                String(localized: "command.toggleSetting.disableTitle", defaultValue: "Disable %@"),
                settingTitle
            )
            let offState = String(localized: "command.toggleSetting.state.off", defaultValue: "Off")
            let onState = String(localized: "command.toggleSetting.state.on", defaultValue: "On")
            #expect(!descriptor.isOn(defaults))
            #expect(descriptor.commandTitle(defaults: defaults) == enableTitle)
            #expect(descriptor.commandSubtitle(defaults: defaults).contains(offState))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            #expect((defaults.object(forKey: IMessageModeSettings.key) as? Bool) == true)
            #expect(descriptor.isOn(defaults))
            #expect(descriptor.commandTitle(defaults: defaults) == disableTitle)
            #expect(descriptor.commandSubtitle(defaults: defaults).contains(onState))
        }
    }

    @Test
    func testTerminalScrollBarTogglePostsChangeNotification() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.terminalShowScrollBar"
                )
            )
            let notificationCenter = NotificationCenter()
            var didNotify = false
            let token = notificationCenter.addObserver(
                forName: TerminalScrollBarSettings.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                didNotify = true
            }
            defer { notificationCenter.removeObserver(token) }

            #expect(descriptor.isOn(defaults))
            descriptor.toggle(defaults: defaults, notificationCenter: notificationCenter)

            #expect((defaults.object(forKey: TerminalScrollBarSettings.showScrollBarKey) as? Bool) == false)
            #expect(didNotify)
        }
    }

    @Test
    func testShowMenuBarCommandIsUnavailableWhenMenuBarOnlyIsEnabled() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.showInMenuBar"
                )
            )

            #expect(descriptor.isAvailable(defaults))
            defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
            #expect(!descriptor.isAvailable(defaults))
        }
    }

    @Test
    func testInterceptTerminalOpenCommandReadsRawSettingWhenBrowserIsDisabled() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.interceptTerminalOpenCommandInCmuxBrowser"
                )
            )
            defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
            defaults.set(true, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)

            #expect(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            #expect(
                (defaults.object(forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey) as? Bool) == false
            )
            #expect(!descriptor.isOn(defaults))
        }
    }

    @Test
    func testOpenSupportedFilesCommandTogglesAndPostsChangeNotification() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.openSupportedFilesInCmux"
                )
            )
            let notificationCenter = NotificationCenter()
            var didNotify = false
            let token = notificationCenter.addObserver(
                forName: FileRouteSettingsStore.supportedFileRouteDidChange,
                object: nil,
                queue: nil
            ) { _ in
                didNotify = true
            }
            defer { notificationCenter.removeObserver(token) }

            #expect(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: notificationCenter)

            #expect((defaults.object(forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey) as? Bool) == false)
            #expect(!descriptor.isOn(defaults))
            #expect(didNotify)
        }
    }

    @Test
    func testOpenMarkdownViewerCommandTogglesAndPostsChangeNotification() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.openMarkdownInCmuxViewer"
                )
            )
            let notificationCenter = NotificationCenter()
            var didNotify = false
            let token = notificationCenter.addObserver(
                forName: FileRouteSettingsStore.markdownRouteDidChange,
                object: nil,
                queue: nil
            ) { _ in
                didNotify = true
            }
            defer { notificationCenter.removeObserver(token) }

            #expect(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: notificationCenter)

            #expect((defaults.object(forKey: AppCatalogSection().openMarkdownInCmuxViewer.userDefaultsKey) as? Bool) == false)
            #expect(!descriptor.isOn(defaults))
            #expect(didNotify)
        }
    }

    @Test
    func testAgentHibernationCommandTogglesAndPostsChangeNotification() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.agentHibernation"
                )
            )
            let notificationCenter = NotificationCenter()
            var didNotify = false
            let token = notificationCenter.addObserver(
                forName: AgentHibernationSettings.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                didNotify = true
            }
            defer { notificationCenter.removeObserver(token) }

            #expect(!descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: notificationCenter)

            #expect(AgentHibernationSettings.isEnabled(defaults: defaults))
            #expect(descriptor.isOn(defaults))
            #expect(didNotify)
        }
    }

    @Test
    func testWarnBeforeQuitCommandWritesConfirmQuitSourceOfTruth() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.warnBeforeQuit"
                )
            )

            defaults.set(ConfirmQuitMode.dirtyOnly.rawValue, forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey)
            #expect(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            #expect(defaults.string(forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey) == ConfirmQuitMode.never.rawValue)
            #expect((defaults.object(forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey) as? Bool) == false)
            #expect(!descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            #expect(defaults.string(forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey) == ConfirmQuitMode.always.rawValue)
            #expect((defaults.object(forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey) as? Bool) == true)
            #expect(descriptor.isOn(defaults))
        }
    }

    @Test
    func testConfigLinkAndFileOpeningSettingsHaveCommandPaletteToggles() throws {
        #expect(
            CommandPaletteSettingsToggleCommands.descriptor(
                commandId: "palette.toggleSetting.openTerminalLinksInCmuxBrowser"
            ) != nil
        )
        #expect(
            CommandPaletteSettingsToggleCommands.descriptor(
                commandId: "palette.toggleSetting.openSupportedFilesInCmux"
            ) != nil
        )
    }

    @Test
    func testSuppressSubagentNotificationsCommandTogglesDefaultAndReportsState() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.suppressSubagentNotifications"
                )
            )

            let offState = String(localized: "command.toggleSetting.state.off", defaultValue: "Off")
            let onState = String(localized: "command.toggleSetting.state.on", defaultValue: "On")
            #expect(descriptor.isOn(defaults))
            #expect(descriptor.commandSubtitle(defaults: defaults).contains(onState))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            #expect(
                (defaults.object(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey) as? Bool) == false
            )
            #expect(!descriptor.isOn(defaults))
            #expect(descriptor.commandSubtitle(defaults: defaults).contains(offState))
        }
    }

    @Test
    func testOpenSidebarPortLinksCommandIsUnavailableWhenPortsAreHidden() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.openSidebarPortLinksInCmuxBrowser"
                )
            )

            #expect(descriptor.isAvailable(defaults))
            defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showPortsKey)
            #expect(!descriptor.isAvailable(defaults))
        }
    }

    @Test
    func testWrapWorkspaceTitlesCommandTogglesDefaultAndReportsState() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.wrapWorkspaceTitlesInSidebar"
                )
            )

            #expect(!descriptor.isOn(defaults))
            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            #expect((defaults.object(forKey: SidebarWorkspaceTitleWrapSettings.key) as? Bool) == true)
            #expect(descriptor.isOn(defaults))
        }
    }

    @Test
    func testHideWorkspaceCloseButtonCommandTogglesDefaultAndReportsState() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.hideWorkspaceCloseButtonInSidebar"
                )
            )
            let key = SettingCatalog().sidebar.hideWorkspaceCloseButton.userDefaultsKey

            #expect(!descriptor.isOn(defaults))
            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            #expect((defaults.object(forKey: key) as? Bool) == true)
            #expect(descriptor.isOn(defaults))
        }
    }

    @Test
    func testUnavailableCommandDoesNotToggleStoredValue() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try #require(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.openSidebarPortLinksInCmuxBrowser"
                )
            )
            defaults.set(false, forKey: BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey)
            defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showPortsKey)

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            #expect(
                (defaults.object(forKey: BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey) as? Bool) == false
            )
        }
    }

    @Test
    func testSettingsToggleContributionsIncludeEveryDescriptor() {
        let descriptorIds = Set(CommandPaletteSettingsToggleCommands.descriptors.map(\.commandId))
        let contributionIds = Set(ContentView.commandPaletteSettingsToggleCommandContributions().map(\.commandId))

        #expect(contributionIds == descriptorIds)
    }

    @Test
    func testSettingsToggleCommandIdsAreUnique() {
        let commandIds = CommandPaletteSettingsToggleCommands.descriptors.map(\.commandId)
        #expect(Set(commandIds).count == commandIds.count)
    }

    private func withTemporaryDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "cmux.commandPaletteSettingsToggle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try body(defaults)
    }
}
