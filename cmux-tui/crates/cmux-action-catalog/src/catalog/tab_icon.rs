// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `TabIconActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "TabIconActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "tab.setIcon",
        group: GROUP,
        title: t("Localizable", "action.tab.setIcon", "Set Tab Icon…"),
        keywords: &["tab", "icon", "emoji", "symbol"],
        category: "tab",
        symbol: "face.smiling",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tab", "identity", 207).folder("options").label(t("Localizable", "menu.icon.set", "Set Icon…"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::ICON.optional()],
        targets: &["tab"],
        cli_name: "tab set-icon",
        ..Action::DEFAULT
    },
    Action {
        id: "tab.clearIcon",
        group: GROUP,
        title: t("Localizable", "action.tab.clearIcon", "Remove Tab Icon"),
        keywords: &["tab", "icon", "emoji", "reset"],
        category: "tab",
        symbol: "circle.dashed",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tab", "identity", 208).folder("options").label(t("Localizable", "menu.icon.remove", "Remove Icon"))], ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "tab clear-icon",
        ..Action::DEFAULT
    },
];
