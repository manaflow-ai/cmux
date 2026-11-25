// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ResourceActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "ResourceActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "tab.showResources",
        group: GROUP,
        title: t("ActionCatalog", "action.tab.showResources", "Show Tab Resource Usage"),
        keywords: &["cpu", "memory", "ram", "process", "activity", "task manager", "usage"],
        category: "tab",
        symbol: "gauge.with.dots.needle.33percent",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("tab", "inspect", 500).folder("options")], ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "tab show-resources",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.showResources",
        group: GROUP,
        title: t("ActionCatalog", "action.workspace.showResources", "Show Workspace Resource Usage"),
        keywords: &["cpu", "memory", "ram", "process", "activity", "task manager", "usage"],
        category: "workspace",
        symbol: "gauge.with.dots.needle.33percent",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "workspace show-resources",
        ..Action::DEFAULT
    },
];
