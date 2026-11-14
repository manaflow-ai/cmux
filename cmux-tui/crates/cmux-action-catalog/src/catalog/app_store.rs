// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AppStoreActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "AppStoreActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "appStore.show",
        group: GROUP,
        title: t("AppStoreActions", "action.appStore.show", "App Store"),
        keywords: &["apps", "store", "extensions", "plugins", "install", "marketplace", "sidebar sections"],
        category: "settings",
        symbol: "bag",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("sidebarBackground", "view", 301)], ..SurfacePlan::DEFAULT },
        arguments: &[args::APP_2.optional(), args::TAB.optional(), args::CATEGORY.optional()],
        cli_name: "app store",
        ..Action::DEFAULT
    },
    Action {
        id: "appStore.showInstalled",
        group: GROUP,
        title: t("AppStoreActions", "action.appStore.showInstalled", "Installed Apps"),
        keywords: &["apps", "installed", "extensions", "plugins", "permissions", "logs", "reload", "disable"],
        category: "settings",
        symbol: "checkmark.seal",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action app-store-show-installed",
        ..Action::DEFAULT
    },
    Action {
        id: "app.hide",
        group: GROUP,
        title: t("AppStoreActions", "action.app.hide", "Hide App…"),
        keywords: &["apps", "hide", "remove from sidebar", "declutter"],
        category: "settings",
        symbol: "eye.slash",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::APP_2],
        cli_name: "apps hide",
        ..Action::DEFAULT
    },
    Action {
        id: "app.unhide",
        group: GROUP,
        title: t("AppStoreActions", "action.app.unhide", "Show Hidden App…"),
        keywords: &["apps", "unhide", "show", "hidden", "restore"],
        category: "settings",
        symbol: "eye",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::APP_2],
        cli_name: "apps unhide",
        ..Action::DEFAULT
    },
    Action {
        id: "app.reloadCustomViews",
        group: GROUP,
        title: t("AppStoreActions", "action.app.reloadCustomViews", "Reload Custom Views"),
        keywords: &["apps", "reload", "customize", "custom views", "sidebar sections", "refresh", "script", "error"],
        category: "settings",
        symbol: "arrow.clockwise",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "apps reload",
        ..Action::DEFAULT
    },
    Action {
        id: "app.install",
        group: GROUP,
        title: t("AppStoreActions", "action.app.install", "Install App…"),
        keywords: &["apps", "install", "add", "store", "extensions", "plugins", "deploy", "self-hosted"],
        category: "settings",
        symbol: "arrow.down.app",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::APP_2, args::DEPLOY.optional()],
        cli_name: "apps install",
        waits_for_person: true,
        ..Action::DEFAULT
    },
    Action {
        id: "app.remove",
        group: GROUP,
        title: t("AppStoreActions", "action.app.remove", "Remove App…"),
        keywords: &["apps", "remove", "uninstall", "delete", "extensions", "plugins"],
        category: "settings",
        symbol: "trash",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::APP_2],
        cli_name: "apps remove",
        waits_for_person: true,
        ..Action::DEFAULT
    },
    Action {
        id: "app.open",
        group: GROUP,
        title: t("AppStoreActions", "action.app.open", "Open App…"),
        keywords: &["apps", "open", "coderouter", "page", "add account", "subscription"],
        category: "settings",
        symbol: "square.grid.2x2",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::APP_2.optional(), args::COMMAND_4.optional()],
        cli_name: "app open",
        ..Action::DEFAULT
    },
    Action {
        id: "app.command.run",
        group: GROUP,
        title: t("AppStoreActions", "action.app.command.run", "Run App Command…"),
        keywords: &["apps", "command", "coderouter", "status", "accounts", "usage", "route"],
        category: "settings",
        symbol: "puzzlepiece.extension",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::APP_2.optional(), args::COMMAND_4.optional()],
        cli_name: "app run-command",
        ..Action::DEFAULT
    },
];
