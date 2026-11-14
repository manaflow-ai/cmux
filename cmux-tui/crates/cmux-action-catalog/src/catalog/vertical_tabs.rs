// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `VerticalTabsActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "VerticalTabsActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "tabs.verticalTabs.toggle",
        group: GROUP,
        title: t("SettingsActions", "action.tabs.verticalTabs.toggle", "Turn On Vertical Tabs"),
        keywords: &["vertical", "tabs", "list", "side", "horizontal", "strip", "workspace", "edge", "chrome"],
        category: "tab",
        symbol: "sidebar.left",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tabStrip", "view", 0)], ..SurfacePlan::DEFAULT },
        targets: &["pane"],
        cli_name: "pane toggle-vertical-tabs",
        ..Action::DEFAULT
    },
    Action {
        id: "tabs.verticalTabs.allWorkspaces",
        group: GROUP,
        title: t("SettingsActions", "action.tabs.verticalTabs.allWorkspaces", "Use Vertical Tabs for All Workspaces"),
        keywords: &["vertical", "tabs", "all", "every", "workspaces", "default", "list", "horizontal", "setting"],
        category: "settings",
        symbol: "rectangle.stack",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("tabStrip", "view", 1)], ..SurfacePlan::DEFAULT },
        cli_name: "action tabs-vertical-tabs-all-workspaces",
        ..Action::DEFAULT
    },
    Action {
        id: "tabs.verticalTabs.collapse",
        group: GROUP,
        title: t("SettingsActions", "action.tabs.verticalTabs.collapse", "Collapse Tabs"),
        keywords: &["vertical", "tabs", "collapse", "expand", "icons", "narrow", "list"],
        category: "tab",
        symbol: "arrow.left.to.line",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("tabStrip", "view", 2)], ..SurfacePlan::DEFAULT },
        targets: &["pane"],
        cli_name: "action tabs-vertical-tabs-collapse",
        ..Action::DEFAULT
    },
    Action {
        id: "tabs.verticalTabs.expandOnHover",
        group: GROUP,
        title: t("SettingsActions", "action.tabs.verticalTabs.expandOnHover", "Auto-Expand Tabs on Hover"),
        keywords: &["vertical", "tabs", "collapse", "expand", "hover", "auto", "icons", "setting"],
        category: "settings",
        symbol: "cursorarrow.motionlines",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("tabStrip", "view", 3)], ..SurfacePlan::DEFAULT },
        targets: &["pane"],
        cli_name: "action tabs-vertical-tabs-expand-on-hover",
        ..Action::DEFAULT
    },
];
