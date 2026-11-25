// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `BrowserChromeActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "BrowserChromeActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "omnibar.openInBackgroundTab",
        group: GROUP,
        title: t("ActionCatalog", "action.omnibar.openInBackgroundTab", "Open Address in New Background Tab"),
        keywords: &["browser", "url", "omnibox", "address bar", "new tab", "background"],
        default_shortcut: Some(Shortcut { key: "\r", modifiers: CMD }),
        category: "browser",
        symbol: "plus.square.on.square",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("liveInput"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("liveInput"), ..SurfacePlan::DEFAULT },
        requires: &["omnibarFocused"],
        targets: &["pane"],
        cli_name: "action omnibar-open-in-background-tab",
        ..Action::DEFAULT
    },
    Action {
        id: "omnibar.openInForegroundTab",
        group: GROUP,
        title: t("ActionCatalog", "action.omnibar.openInForegroundTab", "Open Address in New Tab"),
        keywords: &["browser", "url", "omnibox", "address bar", "new tab", "foreground"],
        default_shortcut: Some(Shortcut { key: "\r", modifiers: SHIFT | CMD }),
        category: "browser",
        symbol: "plus.square",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("liveInput"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("liveInput"), ..SurfacePlan::DEFAULT },
        requires: &["omnibarFocused"],
        targets: &["pane"],
        cli_name: "action omnibar-open-in-foreground-tab",
        ..Action::DEFAULT
    },
    Action {
        id: "browserStop",
        group: GROUP,
        title: t("ActionCatalog", "action.browserStop", "Stop Loading"),
        keywords: &["browser", "cancel", "halt"],
        default_shortcut: Some(Shortcut { key: ".", modifiers: CMD }),
        category: "browser",
        symbol: "xmark",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser stop-loading",
        main_menu: Some("view"),
        ..Action::DEFAULT
    },
    Action {
        id: "browser.copyURL",
        group: GROUP,
        title: t("ActionCatalog", "action.browser.copyURL", "Copy Page URL"),
        keywords: &["browser", "link", "address", "url", "clipboard", "share"],
        default_shortcut: Some(Shortcut { key: "c", modifiers: SHIFT | CMD }),
        category: "browser",
        symbol: "link",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menus: &[Placement::at("browserPage", "navigate", 4)], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["tab"],
        cli_name: "action browser-copy-u-r-l",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.openLocally",
        group: GROUP,
        title: t("ActionCatalog", "action.browser.openLocally", "Open Locally Instead"),
        keywords: &["browser", "remote", "machine", "local", "this mac", "cloud", "ssh"],
        category: "browser",
        symbol: "laptopcomputer",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("browserPage", "navigate", 5)], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["tab"],
        cli_name: "action browser-open-locally",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.openOnMachine",
        group: GROUP,
        title: t("ActionCatalog", "action.browser.openOnMachine", "Open on Machine"),
        keywords: &["browser", "remote", "machine", "cloud", "ssh", "run there"],
        category: "browser",
        symbol: "server.rack",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["tab"],
        cli_name: "action browser-open-on-machine",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.findPrevious",
        group: GROUP,
        title: t("ActionCatalog", "action.browser.findPrevious", "Find Previous in Page"),
        keywords: &["browser", "search", "find"],
        default_shortcut: Some(Shortcut { key: "g", modifiers: SHIFT | CMD }),
        category: "browser",
        symbol: "chevron.up.circle",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Exempt("familyMember")), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "action browser-find-previous",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.download.openBlockedSiteSettings",
        group: GROUP,
        title: t("ActionCatalog", "action.browser.download.openBlockedSiteSettings", "Open Site Settings for Blocked Downloads"),
        keywords: &["browser", "download", "blocked", "automatic downloads", "multiple files", "site settings", "permission", "allow"],
        category: "browser",
        symbol: "gearshape",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        cli_name: "action browser-download-open-blocked-site-settings",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.prompt.allow",
        group: GROUP,
        title: t("ActionCatalog", "action.browser.prompt.allow", "Allow Site Request"),
        keywords: &["browser", "permission", "prompt", "allow", "download", "multiple files", "camera", "microphone"],
        category: "browser",
        symbol: "checkmark.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("liveInput"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["tab"],
        cli_name: "action browser-prompt-allow",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.prompt.block",
        group: GROUP,
        title: t("ActionCatalog", "action.browser.prompt.block", "Block Site Request"),
        keywords: &["browser", "permission", "prompt", "block", "deny", "never allow", "download", "camera", "microphone"],
        category: "browser",
        symbol: "nosign",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("liveInput"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["tab"],
        cli_name: "action browser-prompt-block",
        ..Action::DEFAULT
    },
];
