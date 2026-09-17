import XCTest
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CommandPaletteSettingsToggleTests: XCTestCase {
    func testIMessageModeCommandTogglesDefaultAndReportsState() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
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
            XCTAssertFalse(descriptor.isOn(defaults))
            XCTAssertEqual(descriptor.commandTitle(defaults: defaults), enableTitle)
            XCTAssertTrue(descriptor.commandSubtitle(defaults: defaults).contains(offState))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(defaults.object(forKey: IMessageModeSettings.key) as? Bool, true)
            XCTAssertTrue(descriptor.isOn(defaults))
            XCTAssertEqual(descriptor.commandTitle(defaults: defaults), disableTitle)
            XCTAssertTrue(descriptor.commandSubtitle(defaults: defaults).contains(onState))
        }
    }

    func testTerminalScrollBarTogglePostsChangeNotification() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
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

            XCTAssertTrue(descriptor.isOn(defaults))
            descriptor.toggle(defaults: defaults, notificationCenter: notificationCenter)

            XCTAssertEqual(defaults.object(forKey: TerminalScrollBarSettings.showScrollBarKey) as? Bool, false)
            XCTAssertTrue(didNotify)
        }
    }

    func testShowMenuBarCommandIsUnavailableWhenMenuBarOnlyIsEnabled() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.showInMenuBar"
                )
            )

            XCTAssertTrue(descriptor.isAvailable(defaults))
            defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
            XCTAssertFalse(descriptor.isAvailable(defaults))
        }
    }

    func testInterceptTerminalOpenCommandReadsRawSettingWhenBrowserIsDisabled() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.interceptTerminalOpenCommandInCmuxBrowser"
                )
            )
            defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
            defaults.set(true, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)

            XCTAssertTrue(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(
                defaults.object(forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey) as? Bool,
                false
            )
            XCTAssertFalse(descriptor.isOn(defaults))
        }
    }

    func testOpenSupportedFilesCommandTogglesAndPostsChangeNotification() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
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

            XCTAssertTrue(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: notificationCenter)

            XCTAssertEqual(defaults.object(forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey) as? Bool, false)
            XCTAssertFalse(descriptor.isOn(defaults))
            XCTAssertTrue(didNotify)
        }
    }

    func testOpenMarkdownViewerCommandTogglesAndPostsChangeNotification() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
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

            XCTAssertTrue(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: notificationCenter)

            XCTAssertEqual(defaults.object(forKey: AppCatalogSection().openMarkdownInCmuxViewer.userDefaultsKey) as? Bool, false)
            XCTAssertFalse(descriptor.isOn(defaults))
            XCTAssertTrue(didNotify)
        }
    }

    func testAgentHibernationCommandTogglesAndPostsChangeNotification() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
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

            XCTAssertFalse(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: notificationCenter)

            XCTAssertTrue(AgentHibernationSettings.isEnabled(defaults: defaults))
            XCTAssertTrue(descriptor.isOn(defaults))
            XCTAssertTrue(didNotify)
        }
    }

    func testWarnBeforeQuitCommandWritesConfirmQuitSourceOfTruth() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.warnBeforeQuit"
                )
            )

            defaults.set(ConfirmQuitMode.dirtyOnly.rawValue, forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey)
            XCTAssertTrue(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(defaults.string(forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey), ConfirmQuitMode.never.rawValue)
            XCTAssertEqual(defaults.object(forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey) as? Bool, false)
            XCTAssertFalse(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(defaults.string(forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey), ConfirmQuitMode.always.rawValue)
            XCTAssertEqual(defaults.object(forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey) as? Bool, true)
            XCTAssertTrue(descriptor.isOn(defaults))
        }
    }

    func testConfigLinkAndFileOpeningSettingsHaveCommandPaletteToggles() throws {
        XCTAssertNotNil(
            CommandPaletteSettingsToggleCommands.descriptor(
                commandId: "palette.toggleSetting.openTerminalLinksInCmuxBrowser"
            )
        )
        XCTAssertNotNil(
            CommandPaletteSettingsToggleCommands.descriptor(
                commandId: "palette.toggleSetting.openSupportedFilesInCmux"
            )
        )
    }

    func testSuppressSubagentNotificationsCommandTogglesDefaultAndReportsState() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.suppressSubagentNotifications"
                )
            )

            let offState = String(localized: "command.toggleSetting.state.off", defaultValue: "Off")
            let onState = String(localized: "command.toggleSetting.state.on", defaultValue: "On")
            XCTAssertTrue(descriptor.isOn(defaults))
            XCTAssertTrue(descriptor.commandSubtitle(defaults: defaults).contains(onState))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(
                defaults.object(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey) as? Bool,
                false
            )
            XCTAssertFalse(descriptor.isOn(defaults))
            XCTAssertTrue(descriptor.commandSubtitle(defaults: defaults).contains(offState))
        }
    }

    func testOpenSidebarPortLinksCommandIsUnavailableWhenPortsAreHidden() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.openSidebarPortLinksInCmuxBrowser"
                )
            )

            XCTAssertTrue(descriptor.isAvailable(defaults))
            defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showPortsKey)
            XCTAssertFalse(descriptor.isAvailable(defaults))
        }
    }

    func testWrapWorkspaceTitlesCommandTogglesDefaultAndReportsState() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.wrapWorkspaceTitlesInSidebar"
                )
            )

            XCTAssertFalse(descriptor.isOn(defaults))
            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(defaults.object(forKey: SidebarWorkspaceTitleWrapSettings.key) as? Bool, true)
            XCTAssertTrue(descriptor.isOn(defaults))
        }
    }

    func testUnavailableCommandDoesNotToggleStoredValue() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.openSidebarPortLinksInCmuxBrowser"
                )
            )
            defaults.set(false, forKey: BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey)
            defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showPortsKey)

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(
                defaults.object(forKey: BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey) as? Bool,
                false
            )
        }
    }

    func testSettingsToggleContributionsIncludeEveryDescriptor() {
        let descriptorIds = Set(CommandPaletteSettingsToggleCommands.descriptors.map(\.commandId))
        let contributionIds = Set(ContentView.commandPaletteSettingsToggleCommandContributions().map(\.commandId))

        XCTAssertEqual(contributionIds, descriptorIds)
    }

    func testSettingsToggleCommandIdsAreUnique() {
        let commandIds = CommandPaletteSettingsToggleCommands.descriptors.map(\.commandId)
        XCTAssertEqual(Set(commandIds).count, commandIds.count)
    }

    private func withTemporaryDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "cmux.commandPaletteSettingsToggle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try body(defaults)
    }
}
