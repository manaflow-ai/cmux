//! What each big part of the window is, for Customize… (Leo: "you should maybe be even able to
//! right click customize on anything", then "or at least the big things").
//!
//! One map, read by every surface that points at a part of the window: the right-click
//! Customize… row (`customize.open` with its `element` argument, placed in each element's
//! menus) and the Inspector (hold Option over a part: its name, its settings and its theme
//! colors, with Change This… and Reset). An element names the settings that change it
//! (`schemas/defaults/cmux-next.json` keys without their `setting.` prefix) and the theme
//! tokens it paints with (`ThemeTokens`, the formulas of the design tokens spec), so an
//! agent asked to change it starts from the right keys, and Reset knows what to put back.
//!
//! The big surfaces are [`BIG_SURFACES`]; `tests/customize_elements.rs` fails when one has no
//! element, an element names a setting or token that does not exist, or a menu it lists does
//! not offer Customize….

use crate::model::{EnumCase, Text};
use crate::text::t;

/// One part of the window a person can point at to customize.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CustomizeElement {
    /// Stable id: the `element` argument of `customize.open` and the Inspector's hit name.
    pub id: &'static str,
    /// Its name as the person sees it (the Inspector's header).
    pub title: Text,
    /// The big surface it is (one of [`BIG_SURFACES`]).
    pub surface: &'static str,
    /// The right-click menus (`ActionMenuContext` names) whose Customize… row means this
    /// element. Empty when the part has no native menu of its own yet: the Inspector
    /// still reaches it.
    pub menus: &'static [&'static str],
    /// The settings that change it, most used first.
    pub settings: &'static [&'static str],
    /// The theme tokens it paints with.
    pub tokens: &'static [&'static str],
}

/// The big surfaces every element map entry belongs to; each has at least one element.
pub const BIG_SURFACES: &[&str] = &[
    "sidebar",
    "sidebarSection",
    "titlebar",
    "tabBar",
    "tab",
    "pane",
    "chatComposer",
    "chatMessages",
    "widget",
];

const SIDEBAR: Text = t("Localizable", "menu.name.sidebarBackground", "Sidebar");
const SIDEBAR_SECTION: Text = t("Localizable", "menu.name.sidebarSection", "Sidebar Section");
const WORKSPACE_ROW: Text = t("Localizable", "menu.name.workspaceRow", "Workspace");
const TITLEBAR: Text = t("ActionCatalog", "customize.element.titlebar", "Title Bar");
const TAB_BAR: Text = t("ActionCatalog", "customize.element.tabBar", "Tab Bar");
const TAB: Text = t("Localizable", "menu.name.tab", "Tab");
const PANE: Text = t("Localizable", "menu.name.pane", "Pane");
const COMPOSER: Text = t("ActionCatalog", "customize.element.chatComposer", "Chat Composer");
const CHAT: Text = t("Localizable", "menu.name.agentChat", "Agent Chat");
const WIDGET: Text = t("ActionCatalog", "customize.element.widget", "Widget");

/// Every element, in the order the Inspector lists them.
#[rustfmt::skip]
pub static ELEMENTS: &[CustomizeElement] = &[
    CustomizeElement {
        id: "sidebar",
        title: SIDEBAR,
        surface: "sidebar",
        menus: &["sidebarBackground", "sidebarFooter"],
        settings: &["sidebar.side", "sidebar.style", "sidebar.density", "sidebar.textSize", "sidebar.showSpaces", "sidebar.showProfileControl", "sidebar.showSearchButton", "appearance.sidebarSurface", "appearance.surfaces.sidebar.color", "appearance.surfaces.sidebar.opacity", "appearance.metrics.sidebarWidth"],
        tokens: &["sidebarBackground", "sidebarStep", "textPrimary", "textSecondary", "separator"],
    },
    CustomizeElement {
        id: "sidebarSection",
        title: SIDEBAR_SECTION,
        surface: "sidebarSection",
        menus: &["sidebarSection", "machineSection"],
        settings: &["sidebar.sectionLook", "sidebar.groupBy", "sidebar.topBandMaxShare", "sidebar.bottomBandMaxShare", "sidebar.pinnedBandsScroll"],
        tokens: &["sidebarBackground", "textSecondary", "separator", "hoverFill"],
    },
    CustomizeElement {
        id: "workspaceRow",
        title: WORKSPACE_ROW,
        surface: "sidebar",
        menus: &["workspaceRow"],
        settings: &["sidebar.workspaceRow.branch", "sidebar.workspaceRow.directory", "sidebar.workspaceRow.ports", "sidebar.workspaceRow.pullRequest", "sidebar.workspaceRow.lastActivity", "sidebar.showTimestamps", "sidebar.showColors", "appearance.metrics.sidebarRowHeight", "appearance.metrics.sidebarRowInset", "appearance.metrics.sidebarRowPadding", "appearance.metrics.sidebarRowGap", "appearance.metrics.sidebarRowHeightWithSubtitle"],
        tokens: &["selectionFill", "hoverFill", "textPrimary", "textSecondary", "badgeFill", "attention"],
    },
    CustomizeElement {
        id: "titlebar",
        title: TITLEBAR,
        surface: "titlebar",
        menus: &[],
        settings: &["window.titlebar", "window.titlebarButtons", "tabs.toolbarButtons", "appearance.metrics.titlebarHeight", "appearance.metrics.toolbarButtonSize", "appearance.metrics.toolbarButtonGap", "appearance.metrics.toolbarButtonCornerRadius", "appearance.metrics.toolbarButtonActiveFill", "appearance.metrics.headerDivider"],
        tokens: &["chromeBackground", "textSecondary", "separator"],
    },
    CustomizeElement {
        id: "tabBar",
        title: TAB_BAR,
        surface: "tabBar",
        menus: &["tabStrip"],
        settings: &["tabs.barPosition", "tabs.barOrder", "tabs.verticalTabs", "tabs.overflow", "tabs.plusButton", "tabs.newTabButtonPosition", "appearance.surfaces.tabBar.color", "appearance.surfaces.tabBar.opacity", "appearance.metrics.tabStripHeight"],
        tokens: &["stripBackground", "stripStep", "separator"],
    },
    CustomizeElement {
        id: "tab",
        title: TAB,
        surface: "tab",
        menus: &["tab"],
        settings: &["appearance.metrics.tabFontSize", "appearance.metrics.tabMaxWidth", "appearance.metrics.tabMinActiveWidth", "appearance.metrics.tabPinnedWidth", "focus.inactiveTabStyle", "appearance.statusIndicator.showAgentWorkingOnTabs", "notifications.attention.showOnTab"],
        tokens: &["selectionFill", "hoverFill", "textPrimary", "textSecondary", "accent"],
    },
    CustomizeElement {
        id: "pane",
        title: PANE,
        surface: "pane",
        menus: &["pane"],
        settings: &["layout.paneBorder", "layout.paneBorderColor", "layout.paneBorderWidth", "layout.paneCornerRadius", "layout.panePadding", "layout.paneSeparation", "appearance.paneBackgrounds", "focusRing.showWhenSinglePane"],
        tokens: &["contentBackground", "paneBorder", "focusRing"],
    },
    CustomizeElement {
        id: "chatComposer",
        title: COMPOSER,
        surface: "chatComposer",
        menus: &[],
        settings: &["agentPane.composerRing", "agentPane.showDictation", "agentPane.spellChecking", "agentPane.composerVimKeys", "agentPane.showContextUsage", "agentPane.attachmentView", "appearance.metrics.composerPadding", "appearance.metrics.composerMinHeight"],
        tokens: &["elevatedBackground", "textPrimary", "textPlaceholder", "focusRing", "accent"],
    },
    CustomizeElement {
        id: "chatMessages",
        title: CHAT,
        surface: "chatMessages",
        menus: &["agentChat"],
        settings: &["agentPane.display.font.size", "agentPane.display.font.preset", "agentPane.display.font.lineHeight", "agentPane.display.code.family", "agentPane.display.width", "agentPane.display.fullWidth", "agentPane.display.detail", "agentPane.display.senderIcon.lead", "agentPane.zoom"],
        tokens: &["contentBackground", "textPrimary", "textSecondary", "highlight", "textSelection"],
    },
    CustomizeElement {
        id: "widget",
        title: WIDGET,
        surface: "widget",
        menus: &["nowPlayingCard"],
        settings: &["sidebar.nowPlaying.enabled", "sidebar.cards.tips", "sidebar.hoverCards.enabled"],
        tokens: &["elevatedBackground", "separator", "textPrimary", "textSecondary"],
    },
];

/// The `element` argument's values: one per element, titled by its name.
#[rustfmt::skip]
pub static ELEMENT_CASES: &[EnumCase] = &[
    EnumCase { value: "sidebar", title: SIDEBAR },
    EnumCase { value: "sidebarSection", title: SIDEBAR_SECTION },
    EnumCase { value: "workspaceRow", title: WORKSPACE_ROW },
    EnumCase { value: "titlebar", title: TITLEBAR },
    EnumCase { value: "tabBar", title: TAB_BAR },
    EnumCase { value: "tab", title: TAB },
    EnumCase { value: "pane", title: PANE },
    EnumCase { value: "chatComposer", title: COMPOSER },
    EnumCase { value: "chatMessages", title: CHAT },
    EnumCase { value: "widget", title: WIDGET },
];

/// The element with `id`.
pub fn element(id: &str) -> Option<&'static CustomizeElement> {
    ELEMENTS.iter().find(|element| element.id == id)
}

/// The element a right-click in `menu` (an `ActionMenuContext` name) customizes.
pub fn element_for_menu(menu: &str) -> Option<&'static CustomizeElement> {
    ELEMENTS.iter().find(|element| element.menus.contains(&menu))
}
