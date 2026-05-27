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
                forName: CmdClickSupportedFileRouteSettings.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                didNotify = true
            }
            defer { notificationCenter.removeObserver(token) }

            XCTAssertTrue(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: notificationCenter)

            XCTAssertEqual(defaults.object(forKey: CmdClickSupportedFileRouteSettings.key) as? Bool, false)
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

    func testAgentHibernationCommandWarnsBeforeEnablingWithoutHookEvidence() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.agentHibernation"
                )
            )
            defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
            var confirmationCount = 0
            AgentHibernationEnableWarning.confirmationHandlerForTests = {
                confirmationCount += 1
                return false
            }
            defer { AgentHibernationEnableWarning.confirmationHandlerForTests = nil }

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(confirmationCount, 1)
            XCTAssertFalse(AgentHibernationSettings.isEnabled(defaults: defaults))
            XCTAssertFalse(descriptor.isOn(defaults))
        }
    }

    func testAgentHibernationCommandEnablesAfterWarningConfirmation() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.agentHibernation"
                )
            )
            defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
            AgentHibernationEnableWarning.confirmationHandlerForTests = { true }
            defer { AgentHibernationEnableWarning.confirmationHandlerForTests = nil }

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertTrue(AgentHibernationSettings.isEnabled(defaults: defaults))
            XCTAssertTrue(descriptor.isOn(defaults))
        }
    }

    func testAgentHibernationHookEvidenceIgnoresDisabledCursorIntegration() throws {
        try withTemporaryDefaults { defaults in
            let homeDirectory = try makeTemporaryHomeDirectory()
            defer { try? FileManager.default.removeItem(at: homeDirectory) }
            try writeHookConfig(
                "cmux hooks cursor",
                at: homeDirectory.appendingPathComponent(".cursor/hooks.json")
            )

            defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
            defaults.set(false, forKey: CursorIntegrationSettings.hooksEnabledKey)
            XCTAssertFalse(
                AgentHibernationHookSetupEvidence.hasHookSetupEvidence(
                    defaults: defaults,
                    environment: [:],
                    homeDirectory: homeDirectory
                )
            )

            defaults.set(true, forKey: CursorIntegrationSettings.hooksEnabledKey)
            XCTAssertTrue(
                AgentHibernationHookSetupEvidence.hasHookSetupEvidence(
                    defaults: defaults,
                    environment: [:],
                    homeDirectory: homeDirectory
                )
            )
        }
    }

    func testAgentHibernationHookEvidenceCoversGenericHookDefinitions() throws {
        try withTemporaryDefaults { defaults in
            let homeDirectory = try makeTemporaryHomeDirectory()
            defer { try? FileManager.default.removeItem(at: homeDirectory) }
            try writeHookConfig(
                "cmux hooks copilot",
                at: homeDirectory.appendingPathComponent(".copilot/config.json")
            )

            defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
            XCTAssertTrue(
                AgentHibernationHookSetupEvidence.hasHookSetupEvidence(
                    defaults: defaults,
                    environment: [:],
                    homeDirectory: homeDirectory
                )
            )
        }
    }

    func testAgentHibernationHookEvidenceDetectsRoutedHookCommands() throws {
        try withTemporaryDefaults { defaults in
            let homeDirectory = try makeTemporaryHomeDirectory()
            defer { try? FileManager.default.removeItem(at: homeDirectory) }
            try writeHookConfig(
                "$cmux_cli --socket \"$CMUX_SOCKET_PATH\" hooks codex session-start",
                at: homeDirectory.appendingPathComponent(".codex/hooks.json")
            )

            defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
            XCTAssertTrue(
                AgentHibernationHookSetupEvidence.hasHookSetupEvidence(
                    defaults: defaults,
                    environment: [:],
                    homeDirectory: homeDirectory
                )
            )
        }
    }

    func testAgentHibernationHookEvidenceDetectsPinnedHookMarkers() throws {
        try withTemporaryDefaults { defaults in
            let homeDirectory = try makeTemporaryHomeDirectory()
            defer { try? FileManager.default.removeItem(at: homeDirectory) }
            try writeHookConfig(
                ": cmux-grok-hook-v2;",
                at: homeDirectory.appendingPathComponent(".grok/hooks/cmux-session.json")
            )

            defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
            XCTAssertTrue(
                AgentHibernationHookSetupEvidence.hasHookSetupEvidence(
                    defaults: defaults,
                    environment: [:],
                    homeDirectory: homeDirectory
                )
            )
        }
    }

    func testWarnBeforeQuitCommandWritesConfirmQuitSourceOfTruth() throws {
        try withTemporaryDefaults { defaults in
            let descriptor = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(
                    commandId: "palette.toggleSetting.warnBeforeQuit"
                )
            )

            defaults.set(QuitConfirmationMode.dirtyOnly.rawValue, forKey: QuitWarningSettings.confirmQuitKey)
            XCTAssertTrue(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(defaults.string(forKey: QuitWarningSettings.confirmQuitKey), QuitConfirmationMode.never.rawValue)
            XCTAssertEqual(defaults.object(forKey: QuitWarningSettings.warnBeforeQuitKey) as? Bool, false)
            XCTAssertFalse(descriptor.isOn(defaults))

            descriptor.toggle(defaults: defaults, notificationCenter: NotificationCenter())

            XCTAssertEqual(defaults.string(forKey: QuitWarningSettings.confirmQuitKey), QuitConfirmationMode.always.rawValue)
            XCTAssertEqual(defaults.object(forKey: QuitWarningSettings.warnBeforeQuitKey) as? Bool, true)
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
                defaults.object(forKey: AgentSubagentNotificationSettings.suppressNotificationsKey) as? Bool,
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

    private func makeTemporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeHookConfig(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
