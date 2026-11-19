// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `WindowActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "WindowActionCatalog";

/// The rank of Customize… in each element's menu: last of its View group, before the menu's own
/// Customize Menu… row.
const CUSTOMIZE_RANK: i64 = 990;

#[rustfmt::skip]
const CUSTOMIZE_MENUS: &[Placement] = &[
    Placement::at("sidebarBackground", "view", CUSTOMIZE_RANK),
    Placement::at("sidebarFooter", "view", CUSTOMIZE_RANK),
    Placement::at("sidebarSection", "view", CUSTOMIZE_RANK),
    Placement::at("machineSection", "view", CUSTOMIZE_RANK),
    Placement::at("workspaceRow", "view", CUSTOMIZE_RANK),
    Placement::at("tabStrip", "view", CUSTOMIZE_RANK),
    Placement::at("tab", "view", CUSTOMIZE_RANK),
    Placement::at("pane", "view", CUSTOMIZE_RANK),
    Placement::at("agentChat", "view", CUSTOMIZE_RANK),
    Placement::at("nowPlayingCard", "view", CUSTOMIZE_RANK),
];

/// The part of the window Customize… is about (an element map id): the right-click row and the
/// Inspector's Change This… pass it; the palette and the app menu leave it out.
#[rustfmt::skip]
const CUSTOMIZE_ELEMENT: Argument = Argument { name: "element", title: t("ActionCatalog", "argument.customize.element", "Element"), kind: ArgKind::Enumeration(crate::customize_elements::ELEMENT_CASES), required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };

/// `CUSTOMIZE_ELEMENT` where the action needs one (Reset).
const CUSTOMIZE_ELEMENT_REQUIRED: Argument = Argument { required: true, ..CUSTOMIZE_ELEMENT };

/// The new chat's first composer text in place of `/customize ` (Settings search's "Ask cmux to do
/// this" passes `/customize WORDS`). Shown, never sent by itself.
#[rustfmt::skip]
const CUSTOMIZE_DRAFT: Argument = Argument { name: "draft", title: t("ActionCatalog", "argument.customize.draft", "Draft"), kind: ArgKind::String, required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "openSettings",
        group: GROUP,
        title: t("ActionCatalog", "action.openSettings", "Settings…"),
        keywords: &["preferences", "options", "config"],
        default_shortcut: Some(Shortcut { key: ",", modifiers: CMD }),
        category: "window",
        symbol: "gearshape",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::SECTION.optional(), args::SETTING.optional()],
        cli_name: "app settings",
        main_menu: Some("app"),
        ..Action::DEFAULT
    },
    // Customize…: customize cmux by asking (cmux-customize), opened from the palette and the
    // app menu with no terminal. The CLI's own door is `cmux customize`; this one opens a panel
    // that takes the keyboard, which automation never does unasked.
    Action {
        id: "customize.open",
        group: GROUP,
        title: t("ActionCatalog", "action.customize.open", "Customize…"),
        keywords: &["customize", "customise", "personalize", "make it yours", "ask", "agent", "sidebar", "section", "widget", "extension", "theme", "profile", "preview", "apply", "discard", "rollback", "undo"],
        category: "window",
        symbol: "wand.and.rays",
        surfaces: PALETTE | KEYBOARD | MENU | CONTEXT_MENU,
        // Right-click Customize… on each big part of the window (Leo: "you should maybe be even able to
        // right click customize on anything"): one row per menu the element map lists
        // (customize_elements::ELEMENTS, `tests/customize_elements.rs` keeps the two the same).
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: CUSTOMIZE_MENUS, ..SurfacePlan::DEFAULT },
        arguments: &[CUSTOMIZE_ELEMENT, CUSTOMIZE_DRAFT],
        cli_name: "action customize-open",
        main_menu: Some("app"),
        ..Action::DEFAULT
    },
    // Reset: an element's settings (customize_elements) back to their defaults, the Customize
    // Inspector's Reset button. The settings it removes are the element map's, nothing else.
    Action {
        id: "customize.reset",
        group: GROUP,
        title: t("ActionCatalog", "action.customize.reset", "Reset Element to Defaults"),
        keywords: &["customize", "reset", "defaults", "element", "inspector", "undo"],
        category: "window",
        symbol: "arrow.uturn.backward",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[CUSTOMIZE_ELEMENT_REQUIRED],
        cli_name: "action customize-reset",
        ..Action::DEFAULT
    },
    // Reset Customization Library: every library entry off, back to what was there before any
    // layer, as `cmux customize library reset` (the CLI's own verb). The Settings card turns
    // entries off one at a time and changes the library only on the person's click, so this row
    // is the person's too.
    Action {
        id: "customize.library.reset",
        group: GROUP,
        title: t("SettingsActions", "action.customize.library.reset", "Reset Customization Library"),
        keywords: &["customize", "customise", "customization", "library", "reset", "turn off", "all off", "disable", "layers", "entries", "undo", "rollback"],
        category: "settings",
        symbol: "arrow.counterclockwise",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action customize-library-reset",
        is_person_only: true,
        ..Action::DEFAULT
    },
    Action {
        id: "newWindow",
        group: GROUP,
        title: t("ActionCatalog", "action.newWindow", "New Window"),
        keywords: &["open"],
        default_shortcut: Some(Shortcut { key: "n", modifiers: SHIFT | CMD }),
        category: "window",
        symbol: "macwindow.badge.plus",
        surfaces: PALETTE | KEYBOARD | MENU | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app new-window",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "newIncognitoWindow",
        group: GROUP,
        title: t("ActionCatalog", "action.newIncognitoWindow", "New Incognito Window"),
        keywords: &["private", "incognito", "browser", "off the record"],
        default_shortcut: Some(Shortcut { key: "n", modifiers: OPT | SHIFT | CMD }),
        category: "window",
        symbol: "eyeglasses",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app new-incognito-window",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "closeWindow",
        group: GROUP,
        title: t("ActionCatalog", "action.closeWindow", "Close Window"),
        default_shortcut: Some(Shortcut { key: "w", modifiers: CTRL | CMD }),
        category: "window",
        symbol: "xmark.rectangle",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app close-window",
        main_menu: Some("file"),
        ..Action::DEFAULT
    },
    Action {
        id: "window.closeOthers",
        group: GROUP,
        title: t("ActionCatalog", "action.window.closeOthers", "Close Other Windows"),
        keywords: &["close", "windows", "other", "others"],
        category: "window",
        symbol: "xmark.rectangle.portrait",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app close-other-windows",
        main_menu: Some("file"),
        ..Action::DEFAULT
    },
    Action {
        id: "window.mergeAll",
        group: GROUP,
        title: t("ActionCatalog", "action.window.mergeAll", "Merge All Windows"),
        keywords: &["merge", "windows", "combine", "gather", "join", "spaces"],
        category: "window",
        symbol: "rectangle.stack",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app merge-all-windows",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "closeAllWindows",
        group: GROUP,
        title: t("ActionCatalog", "action.closeAllWindows", "Close All Windows"),
        keywords: &["close", "windows", "all"],
        category: "window",
        symbol: "xmark.rectangle.portrait",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app close-all-windows",
        main_menu: Some("file"),
        ..Action::DEFAULT
    },
    Action {
        id: "zoomWindow",
        group: GROUP,
        title: t("ActionCatalog", "action.zoomWindow", "Zoom"),
        keywords: &["maximize", "window", "resize", "fill"],
        category: "window",
        symbol: "arrow.up.left.and.arrow.down.right.square",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app zoom-window",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "selectNextWindow",
        group: GROUP,
        title: t("ActionCatalog", "action.selectNextWindow", "Select Next Window"),
        keywords: &["cycle", "window", "switch"],
        category: "window",
        symbol: "macwindow.and.cursorarrow",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app select-next-window",
        ..Action::DEFAULT
    },
    Action {
        id: "selectPreviousWindow",
        group: GROUP,
        title: t("ActionCatalog", "action.selectPreviousWindow", "Select Previous Window"),
        keywords: &["cycle", "window", "switch"],
        category: "window",
        symbol: "macwindow.and.cursorarrow",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app select-previous-window",
        ..Action::DEFAULT
    },
    Action {
        id: "minimizeWindow",
        group: GROUP,
        title: t("ActionCatalog", "action.minimizeWindow", "Minimize"),
        keywords: &["dock", "hide", "miniaturize"],
        category: "window",
        symbol: "minus.rectangle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app minimize-window",
        ..Action::DEFAULT
    },
    Action {
        id: "window.screenshot",
        group: GROUP,
        title: t("ActionCatalog", "action.window.screenshot", "Screenshot Window"),
        keywords: &["screenshot", "capture", "image", "png", "picture"],
        category: "window",
        symbol: "camera",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[args::OUT.optional()],
        targets: &["window"],
        cli_name: "window screenshot",
        ..Action::DEFAULT
    },
    Action {
        id: "toggleFullScreen",
        group: GROUP,
        title: t("ActionCatalog", "action.toggleFullScreen", "Toggle Full Screen"),
        keywords: &["fullscreen", "maximize"],
        default_shortcut: Some(Shortcut { key: "f", modifiers: CTRL | CMD }),
        category: "window",
        symbol: "arrow.up.left.and.arrow.down.right",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app toggle-full-screen",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "quit",
        group: GROUP,
        title: t("ActionCatalog", "action.quit", "Quit cmux"),
        keywords: &["exit", "close"],
        default_shortcut: Some(Shortcut { key: "q", modifiers: CMD }),
        category: "window",
        symbol: "power",
        surfaces: KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("endsApp"), ..SurfacePlan::DEFAULT },
        arguments: &[args::KEEP_SESSIONS.optional(), args::END_SESSIONS.optional(), args::END_EVERYTHING.optional()],
        cli_name: "app quit",
        main_menu: Some("app"),
        ..Action::DEFAULT
    },
    Action {
        id: "quitKeepSessions",
        group: GROUP,
        title: t("ActionCatalog", "action.quitKeepSessions", "Quit and Keep Sessions"),
        keywords: &["exit", "close", "background", "terminals", "cmux-tui", "detach"],
        category: "window",
        symbol: "power",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("endsApp"), ..SurfacePlan::DEFAULT },
        cli_name: "app quit-keep-sessions",
        main_menu: Some("app"),
        ..Action::DEFAULT
    },
    Action {
        id: "quitEndSessions",
        group: GROUP,
        title: t("ActionCatalog", "action.quitEndSessionsKeepLayout", "Quit and End Sessions, Keep Layout"),
        keywords: &["exit", "close", "kill", "terminals", "cmux-tui", "stop", "layout"],
        category: "window",
        symbol: "power",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("endsApp"), ..SurfacePlan::DEFAULT },
        cli_name: "app quit-end-sessions",
        main_menu: Some("app"),
        ..Action::DEFAULT
    },
    Action {
        id: "quitEndEverything",
        group: GROUP,
        title: t("ActionCatalog", "action.quitEndEverything", "Quit and End Everything"),
        keywords: &["exit", "close", "kill", "terminals", "cmux-tui", "stop", "workspaces", "fresh", "reset"],
        category: "window",
        symbol: "power",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("endsApp"), ..SurfacePlan::DEFAULT },
        cli_name: "app quit-end-everything",
        main_menu: Some("app"),
        ..Action::DEFAULT
    },
    Action {
        id: "showHideAllWindows",
        group: GROUP,
        title: t("ActionCatalog", "action.showHideAllWindows", "Show/Hide All Windows"),
        keywords: &["global", "hotkey", "summon"],
        default_shortcut: Some(Shortcut { key: ".", modifiers: CTRL | OPT | CMD }),
        category: "window",
        symbol: "macwindow.on.rectangle",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menu_exemption: Some("focusMove"), ..SurfacePlan::DEFAULT },
        cli_name: "app show-hide-all-windows",
        focuses: true,
        is_global_hot_key: true,
        ..Action::DEFAULT
    },
    Action {
        id: "globalSearch",
        group: GROUP,
        title: t("ActionCatalog", "action.globalSearch", "Search All Windows…"),
        keywords: &["find", "global"],
        default_shortcut: Some(Shortcut { key: "f", modifiers: OPT | CMD }),
        category: "window",
        symbol: "magnifyingglass",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::TEXT.optional()],
        cli_name: "app search-all-windows",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "palette.open",
        group: GROUP,
        title: t("ActionCatalog", "action.palette.open", "Open Palette Scope…"),
        keywords: &["palette", "scope", "search in"],
        category: "window",
        symbol: "square.grid.2x2",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::SCOPE.optional(), args::QUERY.optional()],
        cli_name: "palette open",
        ..Action::DEFAULT
    },
    Action {
        id: "commandPalette",
        group: GROUP,
        title: t("ActionCatalog", "action.commandPalette", "Command Palette…"),
        keywords: &["actions", "commands", "search"],
        default_shortcut: Some(Shortcut { key: "p", modifiers: SHIFT | CMD }),
        category: "window",
        surfaces: KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app command-palette",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "commandPaletteNext",
        group: GROUP,
        title: t("ActionCatalog", "action.commandPaletteNext", "Palette: Select Next Item"),
        default_shortcut: Some(Shortcut { key: "n", modifiers: CTRL }),
        category: "window",
        symbol: "chevron.down",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("paletteInternal")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "app palette-select-next-item",
        ..Action::DEFAULT
    },
    Action {
        id: "commandPalettePrevious",
        group: GROUP,
        title: t("ActionCatalog", "action.commandPalettePrevious", "Palette: Select Previous Item"),
        default_shortcut: Some(Shortcut { key: "p", modifiers: CTRL }),
        category: "window",
        symbol: "chevron.up",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("paletteInternal")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "app palette-select-previous-item",
        ..Action::DEFAULT
    },
    Action {
        id: "goToWorkspace",
        group: GROUP,
        title: t("ActionCatalog", "action.goToWorkspace", "Go to Workspace…"),
        keywords: &["switch", "jump", "switcher"],
        default_shortcut: Some(Shortcut { key: "p", modifiers: CMD }),
        category: "window",
        symbol: "arrow.right.square",
        surfaces: KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menu_exemption: Some("focusMove"), ..SurfacePlan::DEFAULT },
        arguments: &[args::WORKSPACE],
        cli_name: "app go-to-workspace",
        main_menu: Some("window"),
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "search.chats",
        group: GROUP,
        title: t("ActionCatalog", "action.search.chats", "Search Everything…"),
        keywords: &["search", "everything", "history", "chats", "agents", "chief", "find", "acp"],
        default_shortcut: Some(Shortcut { key: "a", modifiers: SHIFT | CMD }),
        category: "window",
        symbol: "magnifyingglass",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menu_exemption: Some("focusMove"), ..SurfacePlan::DEFAULT },
        arguments: &[args::QUERY.optional()],
        cli_name: "app search-chats",
        main_menu: Some("window"),
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "palette.openTaskManager",
        group: GROUP,
        title: t("ActionCatalog", "action.palette.openTaskManager", "Task Manager"),
        keywords: &["processes", "cpu", "memory", "activity"],
        category: "window",
        symbol: "gauge.with.dots.needle.33percent",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("tabStrip", "view", 100)], ..SurfacePlan::DEFAULT },
        cli_name: "app task-manager",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "palette.sleepyMode",
        group: GROUP,
        title: t("ActionCatalog", "action.palette.sleepyMode", "Sleepy Mode"),
        keywords: &["idle", "pause", "battery"],
        category: "window",
        symbol: "moon.zzz",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app sleepy-mode",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "keepMacAwake",
        group: GROUP,
        title: t("ActionCatalog", "action.keepMacAwake", "Keep Mac Awake"),
        keywords: &["caffeinate", "sleep"],
        category: "window",
        symbol: "cup.and.saucer",
        surfaces: MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "app keep-mac-awake",
        main_menu: Some("app"),
        ..Action::DEFAULT
    },
    Action {
        id: "showMainWindow",
        group: GROUP,
        title: t("ActionCatalog", "action.showMainWindow", "Show cmux"),
        keywords: &["open", "window"],
        category: "window",
        symbol: "macwindow",
        surfaces: MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menu_exemption: Some("focusMove"), ..SurfacePlan::DEFAULT },
        cli_name: "app show",
        main_menu: Some("window"),
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "about",
        group: GROUP,
        title: t("ActionCatalog", "action.about", "About cmux"),
        keywords: &["version"],
        category: "window",
        symbol: "info.circle",
        surfaces: MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app about",
        main_menu: Some("app"),
        ..Action::DEFAULT
    },
    Action {
        id: "taskManager.killProcess",
        group: GROUP,
        title: t("ActionCatalog", "action.taskManager.killProcess", "Kill Process…"),
        keywords: &["terminate", "signal"],
        category: "window",
        symbol: "xmark.octagon",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[args::PROCESS, args::CONFIRM.optional()],
        cli_name: "app kill-process",
        is_destructive: true,
        ..Action::DEFAULT
    },
];
