import XCTest

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

            XCTAssertTrue(defaults.bool(forKey: IMessageModeSettings.key))
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

            XCTAssertFalse(defaults.bool(forKey: TerminalScrollBarSettings.showScrollBarKey))
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

            XCTAssertFalse(defaults.bool(forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey))
            XCTAssertFalse(descriptor.isOn(defaults))
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

            XCTAssertFalse(defaults.bool(forKey: BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey))
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
