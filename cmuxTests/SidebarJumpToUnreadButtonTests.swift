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
    func barShowsOnlyWhileSomethingIsUnread() {
        let shortcut = KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut

        let unread = SidebarJumpToUnreadButtonPresentation.resolve(
            unreadCount: 3,
            shortcut: shortcut
        )
        let allRead = SidebarJumpToUnreadButtonPresentation.resolve(
            unreadCount: 0,
            shortcut: shortcut
        )

        #expect(unread.isVisible)
        #expect(!allRead.isVisible)
        #expect(unread.countText == "3")
        #expect(allRead.countText == nil)
        #expect(unread.label == "Jump to unread")
    }

    @Test
    func tooltipShowsTheConfiguredShortcutNotTheDefault() {
        let rebound = StoredShortcut(key: "j", command: false, shift: false, option: true, control: true)

        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(
            unreadCount: 1,
            shortcut: rebound
        )

        #expect(presentation.helpText == "\(title) (\(rebound.displayString))")
        let defaultDisplay = KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut.displayString
        #expect(!presentation.helpText.contains(defaultDisplay))
    }

    @Test
    func tooltipDropsTheShortcutWhenItIsUnbound() {
        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(
            unreadCount: 1,
            shortcut: .unbound
        )

        #expect(presentation.helpText == title)
    }

    @Test
    func largeCountsAreCapped() {
        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(
            unreadCount: 250,
            shortcut: KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut
        )

        #expect(presentation.countText == "99+")
    }
}
