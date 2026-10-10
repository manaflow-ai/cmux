import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct SidebarJumpToUnreadButtonTests {
    private let title = KeyboardShortcutSettings.Action.jumpToUnread.label
    private let defaultShortcut = KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut

    @Test
    func hidesInMinimalModeLikeOtherFooterControls() {
        #expect(!SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: .minimal))
        #expect(SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: .standard))
    }

    @Test
    func showsOnlyWhileSomethingIsUnread() {
        let unread = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 3, shortcut: defaultShortcut)
        let allRead = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 0, shortcut: defaultShortcut)

        #expect(unread.isVisible)
        #expect(!allRead.isVisible)
        #expect(unread.countText == "3")
        #expect(allRead.countText == nil)
        #expect(unread.label == "Last unread")
    }

    @Test
    func largeCountsAreCapped() {
        let atCap = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 99, shortcut: defaultShortcut)
        let overCap = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 250, shortcut: defaultShortcut)

        #expect(atCap.countText == "99")
        #expect(overCap.countText == "99+")
    }

    @Test
    func hoverShortcutAndTooltipUseTheConfiguredShortcutNotTheDefault() {
        let rebound = StoredShortcut(key: "j", command: false, shift: false, option: true, control: true)

        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 1, shortcut: rebound)

        #expect(presentation.shortcutText == rebound.displayString)
        #expect(presentation.helpText == "\(title) (\(rebound.displayString))")
        #expect(!presentation.helpText.contains(defaultShortcut.displayString))
    }

    @Test
    func unboundShortcutLeavesNoShortcutInTheHoverOrTooltip() {
        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 1, shortcut: .unbound)

        #expect(presentation.shortcutText == nil)
        #expect(presentation.helpText == title)
        #expect(presentation.isVisible)
    }

    @Test
    func turningTheSettingOffHidesTheButtonEvenWithUnread() throws {
        let suiteName = "SidebarJumpToUnreadButtonTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SidebarJumpToUnreadButtonPresentation.isEnabled(defaults: defaults))

        defaults.set(false, forKey: "sidebarShowJumpToUnreadButton")
        let isEnabled = SidebarJumpToUnreadButtonPresentation.isEnabled(defaults: defaults)
        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(
            unreadCount: 5,
            shortcut: defaultShortcut,
            isEnabled: isEnabled
        )

        #expect(!isEnabled)
        #expect(!presentation.isVisible)
    }

    @Test
    func settingIsReadFromCmuxJSON() throws {
        let mapping = try #require(
            SidebarSettingsFileMapping.booleanSettings.first { $0.jsonKey == "showJumpToUnreadButton" }
        )

        #expect(mapping.defaultsKey == SettingCatalog().sidebar.showJumpToUnreadButton.userDefaultsKey)
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("sidebar.showJumpToUnreadButton"))
        let templateLine = try #require(
            CmuxSettingsFileStore.defaultTemplate().split(separator: "\n").first {
                $0.contains("\"showJumpToUnreadButton\"")
            }
        )
        #expect(templateLine.contains("true"))
    }
}
