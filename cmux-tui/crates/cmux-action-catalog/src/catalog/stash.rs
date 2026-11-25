// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `StashActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "StashActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "tab.stash",
        group: GROUP,
        title: t("StashActions", "action.stash.tab", "Save and Close Tab"),
        keywords: &["stash", "save", "close", "later", "onetab", "put away", "tab", "browser", "page"],
        category: "tab",
        symbol: "tray.and.arrow.down",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tab", "close", 605).folder("close")], ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "tab stash",
        ..Action::DEFAULT
    },
    Action {
        id: "tab.stashToRight",
        group: GROUP,
        title: t("StashActions", "action.stash.toRight", "Save and Close Tabs to the Right"),
        keywords: &["stash", "save", "close", "later", "onetab", "put away", "tab", "browser", "page"],
        category: "tab",
        symbol: "arrow.right.to.line.compact",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tab", "close", 606).folder("close")], ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "tab stash-to-right",
        ..Action::DEFAULT
    },
    Action {
        id: "tab.stashOthers",
        group: GROUP,
        title: t("StashActions", "action.stash.others", "Save and Close Other Tabs"),
        keywords: &["stash", "save", "close", "later", "onetab", "put away", "tab", "browser", "page"],
        category: "tab",
        symbol: "tray.full",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tab", "close", 607).folder("close")], ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "tab stash-others",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.stash",
        group: GROUP,
        title: t("StashActions", "action.stash.workspace", "Save and Close Workspace"),
        keywords: &["stash", "save", "close", "later", "onetab", "put away", "workspace", "terminals"],
        category: "workspace",
        symbol: "tray.and.arrow.down",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "close", 506).folder("close")], ..SurfacePlan::DEFAULT },
        arguments: &[args::CONFIRM.optional()],
        targets: &["workspace"],
        cli_name: "workspace stash",
        is_destructive: true,
        ..Action::DEFAULT
    },
    Action {
        id: "workspaceGroup.stash",
        group: GROUP,
        title: t("StashActions", "action.stash.workspaceGroup", "Save and Close Group"),
        keywords: &["stash", "save", "close", "later", "onetab", "put away", "group", "workspaces"],
        category: "workspace",
        symbol: "tray.2",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceGroup", "close", 504).folder("options")], ..SurfacePlan::DEFAULT },
        arguments: &[args::CONFIRM.optional()],
        targets: &["workspace-group"],
        cli_name: "workspace-group stash",
        is_destructive: true,
        ..Action::DEFAULT
    },
    Action {
        id: "window.stash",
        group: GROUP,
        title: t("StashActions", "action.stash.window", "Save and Close All Workspaces"),
        keywords: &["stash", "save", "close", "later", "onetab", "put away", "window", "all", "workspaces"],
        category: "workspace",
        symbol: "tray.full",
        surfaces: PALETTE | MENU | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "close", 507).folder("close")], ..SurfacePlan::DEFAULT },
        arguments: &[args::WINDOW.optional(), args::CONFIRM.optional()],
        cli_name: "window stash",
        main_menu: Some("file"),
        is_destructive: true,
        ..Action::DEFAULT
    },
    Action {
        id: "stash.show",
        group: GROUP,
        title: t("StashActions", "action.stash.show", "Show Stashed Tabs"),
        keywords: &["stash", "stashed", "onetab", "saved", "save for later", "tabs", "restore", "cmux://stashed"],
        category: "window",
        symbol: "tray.full",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "stash show",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "stash.importOneTab",
        group: GROUP,
        title: t("StashActions", "action.stash.importOneTab", "Import from OneTab…"),
        keywords: &["stash", "onetab", "import", "paste", "tabs"],
        category: "window",
        symbol: "square.and.arrow.down",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action stash-import-one-tab",
        ..Action::DEFAULT
    },
];
