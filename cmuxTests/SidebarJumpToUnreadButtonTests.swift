import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct SidebarJumpToUnreadButtonTests {
    private let title = KeyboardShortcutSettings.Action.jumpToUnread.label

    @Test
    func jumpToUnreadControlHidesInMinimalModeLikeOtherFooterControls() {
        #expect(
            !SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: .minimal)
        )
        #expect(
            SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: .standard)
        )
    }

    @Test
    func buttonIsEnabledOnlyWhileSomethingIsUnread() {
        let shortcut = KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut

        let unread = SidebarJumpToUnreadButtonPresentation.resolve(
            hasUnreadNotifications: true,
            shortcut: shortcut
        )
        let allRead = SidebarJumpToUnreadButtonPresentation.resolve(
            hasUnreadNotifications: false,
            shortcut: shortcut
        )

        #expect(unread.isEnabled)
        #expect(!allRead.isEnabled)
        #expect(unread.systemName == "bell.badge")
        #expect(allRead.systemName == "bell")
        #expect(unread.title == title)
        #expect(allRead.title == title)
    }

    @Test
    func tooltipShowsTheConfiguredShortcutNotTheDefault() {
        let rebound = StoredShortcut(key: "j", command: false, shift: false, option: true, control: true)

        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(
            hasUnreadNotifications: true,
            shortcut: rebound
        )

        #expect(presentation.helpText == "\(title) (\(rebound.displayString))")
        let defaultDisplay = KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut.displayString
        #expect(!presentation.helpText.contains(defaultDisplay))
    }

    @Test
    func tooltipDropsTheShortcutWhenItIsUnbound() {
        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(
            hasUnreadNotifications: true,
            shortcut: .unbound
        )

        #expect(presentation.helpText == title)
    }
}
