//! The menus cmux NEXT builds by hand in a view instead of from catalog placements, each with the
//! registry actions its rows run, so every row of such a menu is a command palette row by
//! construction (cmux#51026). Leo, 2026-11-08 (cmuxterm-hq goals/palette-all-actions.md): every
//! CLI and menu action has a palette entry.
//!
//! A right-click menu generated from placements (`context_menus` in the export) is in the palette
//! already: each of its rows is an action with its own palette decision. A hand-built menu (the
//! Back list, a download's menu, the DevTools divider's) lists its rows here by action id: the
//! palette lists the same actions, and `tests/hand_built_menus.rs` fails when a row names no
//! registered action or one the palette does not offer. The app exports this list as
//! `context_menus_not_exported` (`ContextMenuCatalog.exportHandBuiltMenus`), and
//! `scripts/cmux-next/palette-coverage.py` counts a menu as covered when its rows are, instead of
//! a reviewed keep reason per menu.
//!
//! A new hand-built menu is added here with its rows; the test also fails when the app's export
//! names a hand-built menu this list does not have.

/// One menu built by hand in its view.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HandBuiltMenu {
    /// The export's name for it (`context_menus_not_exported[].name`).
    pub name: &'static str,
    /// The Swift file that builds it, under `Packages/macOS/CmuxNext/Sources/`.
    pub source: &'static str,
    /// The registry actions its rows run (a row per history entry, download or profile runs the
    /// action on that object; the palette lists the same objects for the action's argument).
    pub rows: &'static [&'static str],
    /// The registry right-click menus (`ActionMenuContext` names) whose generated rows it also
    /// shows (`ActionRegistry.makeContextMenu`): each of those rows is an action with its own
    /// palette decision.
    pub contexts: &'static [&'static str],
    /// The rows that are no action, when it has any: what they act on that the palette cannot
    /// name (the link under the pointer, the one ask a card shows). None when every row is above.
    pub pointer_rows: Option<&'static str>,
}

const fn menu(
    name: &'static str,
    source: &'static str,
    rows: &'static [&'static str],
) -> HandBuiltMenu {
    HandBuiltMenu { name, source, rows, contexts: &[], pointer_rows: None }
}

impl HandBuiltMenu {
    const fn contexts(self, contexts: &'static [&'static str]) -> Self {
        Self { contexts, ..self }
    }

    const fn pointer_rows(self, why: &'static str) -> Self {
        Self { pointer_rows: Some(why), ..self }
    }
}

/// Every hand-built menu, in the export's order.
#[rustfmt::skip]
pub const MENUS: &[HandBuiltMenu] = &[
    menu("remoteHoverToolbar", "CmuxNextRemoteView/Pane/RemoteHoverToolbar.swift", &["remote.setQuality"])
        .pointer_rows("the Display menu shows the one current display and a disabled placeholder, no action"),
    menu("terminalPaste", "CmuxNextTerminal/TerminalSurfaceView+Pasteboard.swift", &["terminalCopy", "terminalPaste", "terminal.selectAll"]),
    menu("browserBackForward", "CmuxNextBrowser/UI/BrowserChromeView+BackForwardMenu.swift", &["browser.goToHistoryEntry"]),
    menu("browserExtensions", "CmuxNextBrowser/UI/ExtensionsMenu.swift", &[
        "browser.extensions.menu", "browser.extension.run", "browser.extension.pin", "browser.extension.unpin",
        "browser.extension.options", "browser.extension.enable", "browser.extension.disable", "browser.extension.reload",
        "browser.extension.remove", "browser.extension.siteAccess", "browser.extension.homePage", "browser.extension.details",
        "browser.extension.webPermissions", "browser.extensions.loadUnpacked", "browser.extensions.webStore",
        "browser.extensions.manage",
    ]),
    menu("browserEnginePage", "CmuxNextBrowser/UI/BrowserContextMenuBuilder.swift", &[
        "browserBack", "browserForward", "browserReload", "browser.savePageAs", "browser.cast", "browser.createQRCode",
        "browser.translate", "browserProfile.openLink", "settings.customizeMenus",
    ])
        .contexts(&["browserPage", "browserLink", "browserImage", "browserSelection"])
        .pointer_rows("the engine's own rows on the frame or element under the pointer (Inspect, spelling), which the palette cannot name"),
    menu("browserDevToolsDivider", "CmuxNextBrowser/CEF/CEFDevToolsDivider.swift", &[
        "devtools.openDockedLeft", "devtools.openDocked", "devtools.openDockedRight", "devtools.openInWindow", "devtools.close",
    ]),
    menu("browserProfileLink", "CmuxNextApp/BrowserProfiles/BrowserProfileLinkMenu.swift", &["browserProfile.openLink"]),
    menu("browserToolbar", "CmuxNextApp/Handlers/BrowserToolbarHandlers.swift", &["browser.overflow.menu", "browser.toolbar.togglePin"])
        .contexts(&["browserPage"]),
    menu("bookmarkFolder", "CmuxNextBookmarks/UI/BookmarkFolderMenu.swift", &["bookmark.open", "bookmark.openAll"]),
    menu("titlebarHistory", "CmuxNextHistory/TitlebarHistoryMenu.swift", &["recentlyFocused", "history.reopen", "history.show"]),
    menu("notificationRow", "CmuxNextApp/Notifications/Panel/NotificationsPanelController.swift", &[
        "notificationOpen", "notificationCopy", "notificationToggleRead", "notificationDismiss", "settings.customizeMenus",
    ]),
    menu("agentPaneMessage", "CmuxNextAgentPane/AgentPaneContextMenu.swift", &["agentPane.togglePointerInspector"])
        .contexts(&["agentChat"])
        .pointer_rows("rows on the message, image, code, path or link part or selection under the pointer, which the palette cannot name"),
    menu("browserReload", "CmuxNextBrowser/UI/BrowserReloadMenu.swift", &["browserReload", "browserHardReload"]),
    menu("browserDownloads", "CmuxNextApp/Handlers/BrowserDownloadsMenu.swift", &[
        "browser.download.open", "browser.download.reveal", "browser.download.togglePause", "browser.download.retry",
        "browser.download.cancel", "browser.download.copyLink",
    ]),
    menu("browserMedia", "CmuxNextApp/Handlers/BrowserMediaMenu.swift", &["browser.media.show", "tab.focus"]),
    menu("browserDevice", "CmuxNextBrowser/UI/BrowserDeviceMenu.swift", &["browserDevice"]),
    menu("browserMachineBadge", "CmuxNextApp/AppServices+BrowserTabMachines.swift", &["browser.openOnMachine"]),
    menu("remoteBrowserPage", "CmuxNextRemoteBrowser/Native/RemoteBrowserNativeUI.swift", &[])
        .pointer_rows("Debug builds only: a remote page's own right-click menu and <select> options, sent by that page and answered back to it"),
    menu("sidebarNoticeCard", "CmuxNextSidebar/Views/SidebarNoticeCardView.swift", &[
        "updates.releaseNotes", "updates.showDetails", "updates.cancelDownload", "palette.applyUpdateIfAvailable",
        "palette.checkForUpdates", "updates.snooze", "tips.muteDay", "tips.muteWeek",
    ])
        .pointer_rows("the one ask on that card (yes or no, archive, create), an announcement's or tip's own action, and hiding that card"),
    menu("sidebarUpdateCard", "CmuxNextSidebar/Views/SidebarUpdateCardView.swift", &["updates.snooze"]),
    menu("homeBackground", "CmuxNextHomeEngine/HomePageMenus.swift", &[
        "home.newMessage", "home.newChief", "home.createChannel", "home.invite", "home.inviteToTeam",
        "home.showHiddenConversations", "openTeamPicker",
    ]),
];

/// The hand-built menu named `name`.
pub fn find(name: &str) -> Option<&'static HandBuiltMenu> {
    MENUS.iter().find(|menu| menu.name == name)
}
