// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! Default key bindings that are not an action's own catalog shortcut
//! (plans/cmux-next/keybindings.md section 5), and the key tables the binding table reads.
//! `when` is the clause's text form.

use crate::model::*;

#[rustfmt::skip]
pub static TAB_CYCLE_ALIASES: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "]", modifiers: SHIFT | CMD }], command: "nextSurface", argument: None, arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "[", modifiers: SHIFT | CMD }], command: "prevSurface", argument: None, arguments: &[], when: None, source: "default" },
];

#[rustfmt::skip]
pub static WORKSPACES_AS_TABS: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "]", modifiers: SHIFT | CMD }], command: "nextSidebarTab", argument: None, arguments: &[("scope", BindingValue::String("workspaces"))], when: Some("sidebar.workspacesAsTabs && !(topPage == home || surfaceKind == home || surfaceKind == home-dock)"), source: "default" },
    Binding { keys: &[Shortcut { key: "[", modifiers: SHIFT | CMD }], command: "prevSidebarTab", argument: None, arguments: &[("scope", BindingValue::String("workspaces"))], when: Some("sidebar.workspacesAsTabs && !(topPage == home || surfaceKind == home || surfaceKind == home-dock)"), source: "default" },
];

#[rustfmt::skip]
pub static HOME_CHAT_SWITCHING: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "\t", modifiers: CTRL }], command: "home.nextConversation", argument: None, arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "\t", modifiers: CTRL | SHIFT }], command: "home.previousConversation", argument: None, arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "]", modifiers: SHIFT | CMD }], command: "home.nextConversation", argument: None, arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "[", modifiers: SHIFT | CMD }], command: "home.previousConversation", argument: None, arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "1", modifiers: CTRL }], command: "home.selectConversationByNumber", argument: Some("1"), arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "2", modifiers: CTRL }], command: "home.selectConversationByNumber", argument: Some("2"), arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "3", modifiers: CTRL }], command: "home.selectConversationByNumber", argument: Some("3"), arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "4", modifiers: CTRL }], command: "home.selectConversationByNumber", argument: Some("4"), arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "5", modifiers: CTRL }], command: "home.selectConversationByNumber", argument: Some("5"), arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "6", modifiers: CTRL }], command: "home.selectConversationByNumber", argument: Some("6"), arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "7", modifiers: CTRL }], command: "home.selectConversationByNumber", argument: Some("7"), arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "8", modifiers: CTRL }], command: "home.selectConversationByNumber", argument: Some("8"), arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "9", modifiers: CTRL }], command: "home.selectConversationByNumber", argument: Some("9"), arguments: &[], when: Some("topPage == home || surfaceKind == home-dock"), source: "default" },
];

#[rustfmt::skip]
pub static SCOPED_DEFAULTS: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "k", modifiers: CMD }], command: "agentPane.searchChats", argument: None, arguments: &[], when: Some("surfaceKind != terminal && !codeEditorFocused"), source: "default" },
    Binding { keys: &[Shortcut { key: "r", modifiers: SHIFT | CMD }], command: "home.replyToSelection", argument: None, arguments: &[], when: Some("topPage == home || surfaceKind == home || surfaceKind == home-dock"), source: "default" },
    Binding { keys: &[Shortcut { key: "=", modifiers: CMD }], command: "home.zoomIn", argument: None, arguments: &[], when: Some("topPage == home || surfaceKind == home || surfaceKind == home-dock || topPage == import-history || pageId == cmux.import-history"), source: "default" },
    Binding { keys: &[Shortcut { key: "=", modifiers: SHIFT | CMD }], command: "home.zoomIn", argument: None, arguments: &[], when: Some("topPage == home || surfaceKind == home || surfaceKind == home-dock || topPage == import-history || pageId == cmux.import-history"), source: "default" },
    Binding { keys: &[Shortcut { key: "-", modifiers: CMD }], command: "home.zoomOut", argument: None, arguments: &[], when: Some("topPage == home || surfaceKind == home || surfaceKind == home-dock || topPage == import-history || pageId == cmux.import-history"), source: "default" },
    Binding { keys: &[Shortcut { key: "0", modifiers: CMD }], command: "home.zoomReset", argument: None, arguments: &[], when: Some("topPage == home || surfaceKind == home || surfaceKind == home-dock || topPage == import-history || pageId == cmux.import-history"), source: "default" },
    Binding { keys: &[Shortcut { key: "w", modifiers: CMD }], command: "closeWorkspace", argument: None, arguments: &[], when: Some("sidebar.multiSelection"), source: "default" },
];

#[rustfmt::skip]
pub static PANE_RESIZE_ALIASES: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "\u{f702}", modifiers: CTRL | CMD }], command: "resizePaneLeft", argument: None, arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f703}", modifiers: CTRL | CMD }], command: "resizePaneRight", argument: None, arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f700}", modifiers: CTRL | CMD }], command: "resizePaneUp", argument: None, arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f701}", modifiers: CTRL | CMD }], command: "resizePaneDown", argument: None, arguments: &[], when: None, source: "default" },
];

#[rustfmt::skip]
pub static PANE_FOCUS_ALIASES: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "h", modifiers: CTRL | CMD }], command: "focusLeft", argument: None, arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "j", modifiers: CTRL | CMD }], command: "focusDown", argument: None, arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "k", modifiers: CTRL | CMD }], command: "focusUp", argument: None, arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "l", modifiers: CTRL | CMD }], command: "focusRight", argument: None, arguments: &[], when: None, source: "default" },
];

#[rustfmt::skip]
pub static FOCUS_HISTORY_ALIASES: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "[", modifiers: CMD }], command: "focusHistoryBack", argument: None, arguments: &[], when: Some("surfaceKind != page && !codeEditorFocused"), source: "default" },
    Binding { keys: &[Shortcut { key: "]", modifiers: CMD }], command: "focusHistoryForward", argument: None, arguments: &[], when: Some("surfaceKind != page && !codeEditorFocused"), source: "default" },
    Binding { keys: &[Shortcut { key: "-", modifiers: CTRL }], command: "focusHistoryBack", argument: None, arguments: &[], when: Some("surfaceKind != terminal"), source: "default" },
    Binding { keys: &[Shortcut { key: "-", modifiers: CTRL | SHIFT }], command: "focusHistoryForward", argument: None, arguments: &[], when: Some("surfaceKind != terminal"), source: "default" },
];

#[rustfmt::skip]
pub static ZOOM_ALIASES: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "=", modifiers: SHIFT | CMD }], command: "markdownZoomIn", argument: None, arguments: &[], when: None, source: "default" },
];

#[rustfmt::skip]
pub static SPACE_ALIASES: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "[", modifiers: OPT | CMD }], command: "space.previous", argument: None, arguments: &[], when: Some("!codeEditorFocused"), source: "default" },
    Binding { keys: &[Shortcut { key: "]", modifiers: OPT | CMD }], command: "space.next", argument: None, arguments: &[], when: Some("!codeEditorFocused"), source: "default" },
    Binding { keys: &[Shortcut { key: "1", modifiers: CTRL | OPT | CMD }], command: "space.selectByNumber", argument: Some("1"), arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "2", modifiers: CTRL | OPT | CMD }], command: "space.selectByNumber", argument: Some("2"), arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "3", modifiers: CTRL | OPT | CMD }], command: "space.selectByNumber", argument: Some("3"), arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "4", modifiers: CTRL | OPT | CMD }], command: "space.selectByNumber", argument: Some("4"), arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "5", modifiers: CTRL | OPT | CMD }], command: "space.selectByNumber", argument: Some("5"), arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "6", modifiers: CTRL | OPT | CMD }], command: "space.selectByNumber", argument: Some("6"), arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "7", modifiers: CTRL | OPT | CMD }], command: "space.selectByNumber", argument: Some("7"), arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "8", modifiers: CTRL | OPT | CMD }], command: "space.selectByNumber", argument: Some("8"), arguments: &[], when: None, source: "default" },
    Binding { keys: &[Shortcut { key: "9", modifiers: CTRL | OPT | CMD }], command: "space.selectByNumber", argument: Some("9"), arguments: &[], when: None, source: "default" },
];

#[rustfmt::skip]
pub static PALETTE_KEYS: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "\u{f700}", modifiers: 0 }], command: "commandPalettePrevious", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f701}", modifiers: 0 }], command: "commandPaletteNext", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f700}", modifiers: CMD }], command: "paletteKey.firstItem", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f700}", modifiers: CMD }], command: "paletteKey.leaveLevel", argument: None, arguments: &[], when: Some("paletteOpen && palette.hierarchical && !palette.actionsMenuOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f701}", modifiers: CMD }], command: "paletteKey.lastItem", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f72c}", modifiers: 0 }], command: "paletteKey.pageUp", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f72d}", modifiers: 0 }], command: "paletteKey.pageDown", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f729}", modifiers: 0 }], command: "paletteKey.firstItem", argument: None, arguments: &[], when: Some("paletteOpen && (palette.actionsMenuOpen || palette.hierarchical && palette.queryEmpty)"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f72b}", modifiers: 0 }], command: "paletteKey.lastItem", argument: None, arguments: &[], when: Some("paletteOpen && (palette.actionsMenuOpen || palette.hierarchical && palette.queryEmpty)"), source: "default" },
    Binding { keys: &[Shortcut { key: "\r", modifiers: 0 }], command: "paletteKey.submit", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\r", modifiers: SHIFT }], command: "paletteKey.submit", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\r", modifiers: OPT }], command: "paletteKey.submit", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\r", modifiers: CMD }], command: "paletteKey.submitAlternate", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\r", modifiers: SHIFT | CMD }], command: "paletteKey.submitAlternate", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: " ", modifiers: 0 }], command: "paletteKey.submit", argument: None, arguments: &[], when: Some("paletteOpen && palette.queryEmpty && palette.togglesInPlace && !palette.actionsMenuOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\t", modifiers: 0 }], command: "paletteKey.openActions", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\t", modifiers: SHIFT }], command: "paletteKey.closeActions", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "k", modifiers: CMD }], command: "paletteKey.toggleActions", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{1b}", modifiers: 0 }], command: "paletteKey.escape", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f703}", modifiers: 0 }], command: "paletteKey.enterRow", argument: None, arguments: &[], when: Some("paletteOpen && palette.hierarchical && !palette.actionsMenuOpen && palette.caretAtEnd"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{f702}", modifiers: 0 }], command: "paletteKey.leaveLevel", argument: None, arguments: &[], when: Some("paletteOpen && palette.hierarchical && !palette.actionsMenuOpen && palette.caretAtStart"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{8}", modifiers: 0 }], command: "paletteKey.back", argument: None, arguments: &[], when: Some("paletteOpen && palette.queryEmpty && !palette.actionsMenuOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "\u{8}", modifiers: 0 }], command: "paletteKey.filterDeleteBackward", argument: None, arguments: &[], when: Some("paletteOpen && palette.actionsMenuOpen"), source: "default" },
    Binding { keys: &[Shortcut { key: "w", modifiers: CMD }], command: "paletteKey.closeItem", argument: None, arguments: &[], when: Some("paletteOpen"), source: "default" },
];

#[rustfmt::skip]
pub static LIST_NAVIGATION: &[Binding] = &[
    Binding { keys: &[Shortcut { key: "n", modifiers: CTRL }], command: "list.next", argument: None, arguments: &[], when: Some("listFocus"), source: "default" },
    Binding { keys: &[Shortcut { key: "j", modifiers: CTRL }], command: "list.next", argument: None, arguments: &[], when: Some("listFocus"), source: "default" },
    Binding { keys: &[Shortcut { key: "p", modifiers: CTRL }], command: "list.previous", argument: None, arguments: &[], when: Some("listFocus"), source: "default" },
    Binding { keys: &[Shortcut { key: "k", modifiers: CTRL }], command: "list.previous", argument: None, arguments: &[], when: Some("listFocus"), source: "default" },
];

pub static HOME_CHAT_SCOPED: &[&str] =
    &["home.nextConversation", "home.previousConversation", "home.selectConversationByNumber"];
pub static HOME_SCOPED: &[&str] = &["home.zoomIn", "home.zoomOut", "home.zoomReset"];
pub static YIELDS_TO_CODE_EDITOR: &[&str] = &[
    "focusDown",
    "focusLocation",
    "focusUp",
    "globalSearch",
    "groupSelectedWorkspaces",
    "home.openChiefDock",
    "moveSurfaceToPaneDown",
    "moveSurfaceToPaneLeft",
    "moveSurfaceToPaneRight",
    "moveSurfaceToPaneUp",
    "openBrowser",
    "palette.newAgentChat",
    "space.next",
    "space.previous",
    "splitRight",
    "toggleChecklistItemComplete",
    "toggleSplitZoom",
];
pub static YIELDS_TO_TERMINAL: &[&str] = &[
    "decreaseWorkspaceTerminalFontSize",
    "groupSelectedWorkspaces",
    "increaseWorkspaceTerminalFontSize",
    "resetWorkspaceTerminalFontSize",
    "toggleChecklistItemComplete",
];
pub static YIELDS_TO_WEB_CONTENT: &[&str] = &["toggleChecklistItemComplete"];
pub static TEXT_INPUT_KEYS: &[Shortcut] = &[
    Shortcut { key: "\r", modifiers: OPT },
    Shortcut { key: "\r", modifiers: SHIFT },
    Shortcut { key: "\u{f700}", modifiers: 0 },
    Shortcut { key: "\r", modifiers: CMD },
    Shortcut { key: "\r", modifiers: 0 },
    Shortcut { key: "\u{1b}", modifiers: 0 },
];

/// Every default entry that is an alias of an action (`ActionSurfaceExport.defaultAliases`):
/// the action aliases, list navigation, the palette keys, the scoped defaults and Home's chat
/// switching, in that order.
pub fn alias_entries() -> impl Iterator<Item = &'static Binding> {
    [
        TAB_CYCLE_ALIASES,
        PANE_RESIZE_ALIASES,
        PANE_FOCUS_ALIASES,
        FOCUS_HISTORY_ALIASES,
        ZOOM_ALIASES,
        SPACE_ALIASES,
        LIST_NAVIGATION,
        PALETTE_KEYS,
        SCOPED_DEFAULTS,
        HOME_CHAT_SWITCHING,
    ]
    .into_iter()
    .flatten()
}
