//! The Swift app's own tables the exports read, in their Swift declaration order (each `allCases`). They live
//! in CmuxNextActions, not in the Rust catalog; each names its Swift source, and a change there needs the same
//! change here (the parity test against the checked-in exports catches a miss).

/// `ActionCategory` (ActionCategory.swift), `allCases` order.
pub const CATEGORIES: &[&str] = &[
    "window",
    "workspace",
    "pane",
    "screen",
    "tab",
    "terminal",
    "browser",
    "sidebar",
    "notifications",
    "agents",
    "cloud",
    "remote",
    "settings",
    "other",
];

/// `ActionMainMenu` raw values (ActionCategory.swift).
pub const MAIN_MENUS: &[&str] = &["app", "file", "edit", "view", "server", "window", "help"];

/// `ActionTargetKind` raw values (ActionTarget.swift).
pub const TARGET_KINDS: &[&str] = &[
    "tab",
    "tab-group",
    "pane",
    "column",
    "screen",
    "screen-group",
    "workspace",
    "workspace-group",
    "window",
    "machine",
    "room",
    "browser-profile",
    "bookmark",
    "sidebar-item",
    "sidebar-section",
    "agent-chat",
];

/// `SurfaceExemption` (ActionSurface.swift), `allCases` order.
pub const EXEMPTIONS: &[&str] = &[
    "paletteInternal",
    "devOnly",
    "focusMove",
    "stepAdjust",
    "liveInput",
    "guiOnly",
    "clipboard",
    "noObject",
    "noTargetSurface",
    "familyMember",
    "dragGesture",
    "unimplemented",
    "secondaryEngine",
    "duplicateOfDefault",
    "credentials",
    "endsApp",
    "systemChange",
    "ownerVerb",
    "minimalMenu",
    "pointerMenuTrim",
];

/// `ActionSurface` (ActionSurface.swift), `allCases` order.
pub const SURFACES: &[&str] = &["palette", "cli", "contextMenu", "mcp"];

/// `ActionMenuContext` (ActionTarget.swift), `allCases` order.
pub const MENU_CONTEXTS: &[&str] = &[
    "tab",
    "tabGroup",
    "screen",
    "screenGroup",
    "pane",
    "workspaceRow",
    "workspaceGroup",
    "sidebarBackground",
    "terminalSelection",
    "browserPage",
    "browserLink",
    "browserImage",
    "browserSelection",
    "cloudMachine",
    "sshMachine",
    "machineSection",
    "newTab",
    "profile",
    "browserProfile",
    "bookmark",
    "bookmarksBar",
    "bookmarkManager",
    "screenBar",
    "notification",
    "sidebarItem",
    "sidebarFooter",
    "sidebarSection",
    "agentChat",
    "windowBackground",
    "nowPlayingCard",
    "fileExplorerRow",
    "priorityRow",
    "joinedMachine",
    "tabStrip",
    "divider",
];

/// `ActionMenuContext.exportName` (ContextMenuCatalog+Export.swift): the raw value, but `profile` is `space`.
pub fn export_name(context: &str) -> &str {
    if context == "profile" { "space" } else { context }
}

/// `MenuGroup` (ContextMenuPlacement.swift), its `Int` raw value order (`Comparable`).
pub const MENU_GROUPS: &[&str] = &[
    "edit",
    "navigate",
    "create",
    "reopen",
    "identity",
    "organize",
    "move",
    "layout",
    "connection",
    "inspect",
    "view",
    "reset",
    "close",
];

/// `MenuFolder` (MenuFolder.swift), `allCases` order.
pub const MENU_FOLDERS: &[&str] = &[
    "new",
    "split",
    "agent",
    "openIn",
    "appearance",
    "options",
    "group",
    "move",
    "sort",
    "layout",
    "connection",
    "copy",
    "tools",
    "close",
    "archive",
    "more",
];

/// `ActionContext.keyNames` (KeyContext.swift): the `when` key names, in order.
pub const CONTEXT_KEYS: &[&str] = &[
    "terminalFocused",
    "browserFocused",
    "canvasLayout",
    "simulatorFocused",
    "diffViewerFocused",
    "filePreviewFocused",
    "markdownFocused",
    "rightSidebarFocused",
    "fileExplorerFocused",
    "textBoxFocused",
    "paletteOpen",
    "signedIn",
    "signedOut",
    "cloudWorkspace",
    "agentPaneFocused",
    "checkpointCaptureAvailable",
    "recordingShortcut",
    "omnibarFocused",
    "codeEditorFocused",
    "homeChannelsEnabled",
    "webViewFocused",
    "markdownReadOnlyFocused",
    "markdownEditorFocused",
];

/// `ActionRegistry.impliedContext(for:)` (ActionRegistry+ContextMenus.swift): the context names a menu implies.
pub fn implied_context(context: &str) -> &'static [&'static str] {
    match context {
        "browserPage" | "browserLink" | "browserImage" | "browserSelection" => &["browserFocused"],
        "terminalSelection" => &["terminalFocused"],
        "agentChat" | "priorityRow" => &["agentPaneFocused"],
        "fileExplorerRow" => &["fileExplorerFocused"],
        _ => &[],
    }
}

/// `ActionFeature.feature(of:)` (ActionFeature.swift). `group` is the action's catalog group (Apps is every
/// action of `AppStoreActionCatalog`).
pub fn feature(id: &str, category: &str, group: Option<&str>) -> Option<&'static str> {
    let lowered = id.to_lowercase();
    if lowered.starts_with("computeruse") || id.starts_with("palette.computerUse.") {
        return Some("computerUse");
    }
    if category == "remote"
        || id == "disconnectRemoteTab"
        || ["server.makeThisMacAServer", "server.addServer", "server.pairAnotherMachine"]
            .contains(&id)
    {
        return Some("remoteHosts");
    }
    if group == Some("AppStoreActionCatalog") {
        return Some("apps");
    }
    if lowered.contains("cloud") {
        return Some("cloud");
    }
    None
}

/// `ContextMenuEssentials.choiceTrailers` (ContextMenuCatalog+Essentials.swift).
pub fn choice_trailer(id: &str) -> Option<&'static str> {
    if id == "moveWorkspaceToGroup" { Some("workspace.moveToNewGroup") } else { None }
}

/// `ContextMenuEssentials.inlineFolderLimit`.
pub const INLINE_FOLDER_LIMIT: usize = 8;

/// One row of a `ContextMenuEssentials.Rows` list.
pub enum EssentialRow {
    Action(&'static str),
    Choices(&'static str),
    Folder(&'static str),
    Separator,
}

/// `ContextMenuEssentials.Rows`.
pub struct Essentials {
    pub top: &'static [EssentialRow],
    pub group: &'static [EssentialRow],
    pub close: &'static [&'static str],
    pub tail: &'static [&'static str],
    pub before_more: &'static [EssentialRow],
}

use EssentialRow::{Action as A, Choices as C, Folder as F, Separator as S};

/// `ContextMenuEssentials.copyFolder`.
const COPY_FOLDER: &[EssentialRow] = &[F("copy")];

/// `ContextMenuEssentials.menus` (the one-row menus; `selectionMenus` are not exported).
pub fn essentials(context: &str) -> Option<Essentials> {
    match context {
        "workspaceRow" => Some(Essentials {
            top: &[
                A("renameWorkspace"),
                A("palette.toggleWorkspacePin"),
                C("palette.workspaceColor"),
                A("workspace.newBelow"),
                A("home.messageAbout"),
                F("move"),
            ],
            group: &[
                C("moveWorkspaceToGroup"),
                A("groupSelectedWorkspaces"),
                A("removeWorkspaceFromGroup"),
            ],
            close: &["workspace.toggleArchive", "closeWorkspace"],
            tail: &[],
            before_more: COPY_FOLDER,
        }),
        "tab" => Some(Essentials {
            top: &[
                A("newTab.toRight"),
                A("tabGroup.create"),
                A("tabGroup.addTab"),
                A("tabGroup.removeTab"),
                S,
                A("reloadTab"),
                A("duplicateTab"),
                A("palette.toggleTabPin"),
                A("toggleTabAudioMute"),
                A("closeTab"),
                A("closeOtherTabsInPane"),
                A("closeTabsToRight"),
            ],
            group: &[],
            close: &[],
            tail: &[],
            before_more: COPY_FOLDER,
        }),
        "pane" => Some(Essentials {
            top: &[
                A("splitRight"),
                A("splitDown"),
                F("split"),
                A("toggleSplitZoom"),
                A("renamePane"),
            ],
            group: &[],
            close: &["closePane"],
            tail: &[],
            before_more: COPY_FOLDER,
        }),
        _ => None,
    }
}

/// `ContextMenuCatalog.exportRenderRules` (ContextMenuCatalog+Export.swift).
pub const RENDER_RULES: &[&str] = &[
    "A row shows only when its visible_when holds: every name in requires is true in the effective context (the window's context plus the menu's implied names), debug_only rows need developer tools, and a row whose feature an administrator turned off is left out.",
    "enabled_when can_perform: the row is enabled when its action is bound and its handler allows it for the clicked target; a disabled row may carry a reason as subtitle and tooltip.",
    "A row with a label shows that label instead of its action's title: menu-only wording (Set Icon… for Set Space Icon…); the palette and CLI keep the title.",
    "A submenu takes its label, else its action's title, without a trailing ellipsis; a folder takes its own title. A submenu or folder without a shown row is left out.",
    "A separator shows only after a shown row and before another shown row: runs collapse to one, and leading and trailing separators drop.",
    "A choices row is a submenu with one item per value in choices.values (then a separator and More… when more_opens_palette). It shows by the same visible_when as every row, and only when its action is bound and enabled (otherwise it is left out, not disabled).",
    "A choices row with choices.trailer ends its submenu with that action under its own title, on the same target, after a separator when there are values. With a trailer the row shows even when it has no values (Move Workspace to Group > Move Workspace to New Group).",
    "context_menus_not_exported lists the menus built by hand in their views; they are not in context_menus. Whoever adds a new hand-built menu adds it to that list (ContextMenuCatalog.exportHandBuiltMenus).",
];

/// `ContextMenuCatalog.exportHandBuiltMenus` (ContextMenuCatalog+Export.swift): name, source.
pub const HAND_BUILT_MENUS: &[(&str, &str)] = &[
    ("remoteHoverToolbar", "CmuxNextRemoteView/Pane/RemoteHoverToolbar.swift"),
    ("terminalPaste", "CmuxNextTerminal/TerminalSurfaceView+Pasteboard.swift"),
    ("browserBackForward", "CmuxNextBrowser/UI/BrowserChromeView+BackForwardMenu.swift"),
    ("browserExtensions", "CmuxNextBrowser/UI/ExtensionsMenu.swift"),
    ("browserEnginePage", "CmuxNextBrowser/UI/BrowserContextMenuBuilder.swift"),
    ("browserDevToolsDivider", "CmuxNextBrowser/CEF/CEFDevToolsDivider.swift"),
    ("browserProfileLink", "CmuxNextApp/BrowserProfiles/BrowserProfileLinkMenu.swift"),
    ("browserToolbar", "CmuxNextApp/Handlers/BrowserToolbarHandlers.swift"),
    ("bookmarkFolder", "CmuxNextBookmarks/UI/BookmarkFolderMenu.swift"),
    ("titlebarHistory", "CmuxNextHistory/TitlebarHistoryMenu.swift"),
    ("notificationRow", "CmuxNextApp/Notifications/Panel/NotificationsPanelController.swift"),
    ("agentPaneMessage", "CmuxNextAgentPane/AgentPaneContextMenu.swift"),
    ("browserReload", "CmuxNextBrowser/UI/BrowserReloadMenu.swift"),
    ("browserDownloads", "CmuxNextApp/Handlers/BrowserDownloadsMenu.swift"),
    ("browserMedia", "CmuxNextApp/Handlers/BrowserMediaMenu.swift"),
    ("browserDevice", "CmuxNextBrowser/UI/BrowserDeviceMenu.swift"),
    ("browserMachineBadge", "CmuxNextApp/AppServices+BrowserTabMachines.swift"),
    ("remoteBrowserPage", "CmuxNextRemoteBrowser/Native/RemoteBrowserNativeUI.swift"),
    ("sidebarNoticeCard", "CmuxNextSidebar/Views/SidebarNoticeCardView.swift"),
    ("sidebarUpdateCard", "CmuxNextSidebar/Views/SidebarUpdateCardView.swift"),
    ("homeBackground", "CmuxNextHomeEngine/HomePageMenus.swift"),
];
