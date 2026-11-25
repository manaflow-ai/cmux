// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! Old action ids, categories and right-click folders.

use crate::model::*;
use crate::text::t;

/// What only a Debug build of the app has (its handlers or views are compiled out of Release):
/// these actions, and these values of an action's enumeration argument (action, argument,
/// value). A Release build drops them when it loads the catalog.
pub static DEBUG_BUILD_ONLY_ACTIONS: &[&str] = &[
    "home.agentMessagePlayground",
    "home.mcpConnectPlayground",
    "home.compareTablePlayground",
    "home.chiefTeleportPlayground",
];

/// Enumeration cases only Debug builds offer: none since Open Desktop's development-only `native`
/// viewer went with the Cloud tunnel (`rd` is its only viewer).
pub static DEBUG_BUILD_ONLY_CASES: &[(&str, &str, &str)] = &[];

/// Ids from before the catalog or renamed since, mapped to the catalog id (users keep them in
/// cmux.json `shortcuts`).
#[rustfmt::skip]
pub static LEGACY_ALIASES: &[(&str, &str)] = &[
    ("app.quit", "quit"),
    ("browserNewProfile", "browserProfile.new"),
    ("browserProfile.clearRoomDefault", "browserProfile.clearSpaceDefault"),
    ("browserProfile.setRoomDefault", "browserProfile.setSpaceDefault"),
    ("browserRenameProfile", "browserProfile.rename"),
    ("diffViewerScrollDown", "diffViewerNextLine"),
    ("diffViewerScrollHalfPageDown", "diffViewerHalfPageDown"),
    ("diffViewerScrollHalfPageUp", "diffViewerHalfPageUp"),
    ("diffViewerScrollToBottom", "diffViewerGoToBottom"),
    ("diffViewerScrollToTop", "diffViewerGoToTop"),
    ("diffViewerScrollUp", "diffViewerPreviousLine"),
    ("newTab.sameKind", "newTab.default"),
    ("openLinkInNewTab", "browser.link.openInNewTab"),
    ("palette.goToTab", "tab.search"),
    ("palette.show", "commandPalette"),
    ("resize-pane-down", "resizePaneDown"),
    ("resize-pane-left", "resizePaneLeft"),
    ("resize-pane-right", "resizePaneRight"),
    ("resize-pane-up", "resizePaneUp"),
    ("room.clearColor", "space.clearColor"),
    ("room.clearIcon", "space.clearIcon"),
    ("room.clearTheme", "space.clearTheme"),
    ("room.color.blue", "space.color.blue"),
    ("room.color.cyan", "space.color.cyan"),
    ("room.color.green", "space.color.green"),
    ("room.color.grey", "space.color.grey"),
    ("room.color.orange", "space.color.orange"),
    ("room.color.pink", "space.color.pink"),
    ("room.color.purple", "space.color.purple"),
    ("room.color.red", "space.color.red"),
    ("room.color.yellow", "space.color.yellow"),
    ("room.delete", "space.delete"),
    ("room.move", "space.move"),
    ("room.moveLeft", "space.moveLeft"),
    ("room.moveRight", "space.moveRight"),
    ("room.new", "space.new"),
    ("room.newWindow", "space.newWindow"),
    ("room.newWorkspace", "space.newWorkspace"),
    ("room.next", "space.next"),
    ("room.previous", "space.previous"),
    ("room.rename", "space.rename"),
    ("room.selectByNumber", "space.selectByNumber"),
    ("room.setColor", "space.setColor"),
    ("room.setDefaults", "space.setDefaults"),
    ("room.setIcon", "space.setIcon"),
    ("room.setTheme", "space.setTheme"),
    ("room.switch", "space.switch"),
    ("showWindowHints", "hints.show"),
    ("sidebar.section.toggleRoomScope", "sidebar.section.toggleSpaceScope"),
    ("tab.close", "closeTab"),
    ("tab.new", "newSurface"),
    ("tab.next", "nextSurface"),
    ("tab.previous", "prevSurface"),
    ("view.toggleSidebar", "toggleSidebar"),
    ("workspace.duplicateToRoom", "workspace.duplicateToSpace"),
    ("workspace.moveToRoom", "workspace.moveToSpace"),
    ("workspace.newInGroup", "workspace.newLikeThis"),
    ("workspace.newInSameDirectory", "workspace.newLikeThis"),
    ("workspaceGroup.moveToRoom", "workspaceGroup.moveToSpace"),
];

#[rustfmt::skip]
pub static CATEGORIES: &[Category] = &[
    Category { id: "window", title: t("Localizable", "category.window", "Window"), sort_order: 0 },
    Category { id: "workspace", title: t("Localizable", "category.workspace", "Workspace"), sort_order: 1 },
    Category { id: "pane", title: t("Localizable", "category.pane", "Panes"), sort_order: 2 },
    Category { id: "screen", title: t("ScreenActions", "category.screen", "Screens"), sort_order: 3 },
    Category { id: "tab", title: t("Localizable", "category.tab", "Tabs"), sort_order: 4 },
    Category { id: "terminal", title: t("Localizable", "category.terminal", "Terminal"), sort_order: 5 },
    Category { id: "browser", title: t("Localizable", "category.browser", "Browser and Viewers"), sort_order: 6 },
    Category { id: "sidebar", title: t("Localizable", "category.sidebar", "Sidebar"), sort_order: 7 },
    Category { id: "notifications", title: t("Localizable", "category.notifications", "Notifications"), sort_order: 8 },
    Category { id: "agents", title: t("Localizable", "category.agents", "Agents"), sort_order: 9 },
    Category { id: "cloud", title: t("Localizable", "category.cloud", "Cloud and Account"), sort_order: 10 },
    Category { id: "remote", title: t("RemoteActions", "category.remote", "Remote Machines"), sort_order: 11 },
    Category { id: "settings", title: t("Localizable", "category.settings", "Settings and Help"), sort_order: 12 },
    Category { id: "other", title: t("Localizable", "category.other", "Other"), sort_order: 13 },
];

#[rustfmt::skip]
pub static MENU_FOLDERS: &[MenuFolder] = &[
    MenuFolder { id: "new", title: t("Localizable", "menu.folder.new", "New"), symbol: "plus.square", group: "create" },
    MenuFolder { id: "split", title: t("Localizable", "menu.folder.split", "Split"), symbol: "rectangle.split.2x1", group: "create" },
    MenuFolder { id: "agent", title: t("Localizable", "menu.folder.agent", "Agent"), symbol: "sparkles", group: "create" },
    MenuFolder { id: "openIn", title: t("Localizable", "menu.folder.openIn", "Open In"), symbol: "arrow.up.forward.app", group: "reopen" },
    MenuFolder { id: "appearance", title: t("Localizable", "menu.folder.appearance", "Appearance"), symbol: "paintpalette", group: "identity" },
    MenuFolder { id: "options", title: t("Localizable", "menu.folder.options", "Options"), symbol: "slider.horizontal.3", group: "identity" },
    MenuFolder { id: "group", title: t("Localizable", "menu.folder.group", "Group"), symbol: "square.stack.3d.up", group: "organize" },
    MenuFolder { id: "move", title: t("Localizable", "menu.folder.move", "Move"), symbol: "arrow.up.and.down.square", group: "move" },
    MenuFolder { id: "sort", title: t("Localizable", "menu.folder.sort", "Sort"), symbol: "arrow.up.arrow.down", group: "move" },
    MenuFolder { id: "layout", title: t("Localizable", "menu.folder.layout", "Layout"), symbol: "rectangle.3.group", group: "layout" },
    MenuFolder { id: "connection", title: t("Localizable", "menu.folder.connection", "Connection"), symbol: "network", group: "connection" },
    MenuFolder { id: "copy", title: t("Localizable", "menu.folder.copy", "Copy"), symbol: "doc.on.doc", group: "inspect" },
    MenuFolder { id: "tools", title: t("Localizable", "menu.folder.tools", "Tools"), symbol: "wrench.and.screwdriver", group: "inspect" },
    MenuFolder { id: "close", title: t("Localizable", "menu.folder.close", "Close"), symbol: "xmark.square", group: "close" },
    MenuFolder { id: "archive", title: t("Localizable", "menu.folder.archive", "Archive"), symbol: "archivebox", group: "close" },
    MenuFolder { id: "more", title: t("Localizable", "menu.folder.more", "More"), symbol: "ellipsis.circle", group: "close" },
];
