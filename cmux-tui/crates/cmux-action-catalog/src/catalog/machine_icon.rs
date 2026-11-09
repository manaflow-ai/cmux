// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `MachineIconActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "MachineIconActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "machine.setIcon",
        group: GROUP,
        title: t("Localizable", "action.machine.setIcon", "Set Machine Icon…"),
        keywords: &["machine", "computer", "host", "icon", "emoji", "symbol"],
        category: "sidebar",
        symbol: "face.smiling",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("machineSection", "identity", 0).folder("appearance").label(t("Localizable", "menu.icon.set", "Set Icon…"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::ICON.optional()],
        targets: &["machine"],
        cli_name: "machine set-icon",
        ..Action::DEFAULT
    },
    Action {
        id: "machine.clearIcon",
        group: GROUP,
        title: t("Localizable", "action.machine.clearIcon", "Remove Machine Icon"),
        keywords: &["machine", "computer", "host", "icon", "emoji", "reset"],
        category: "sidebar",
        symbol: "xmark.circle",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("machineSection", "identity", 1).folder("appearance").label(t("Localizable", "menu.icon.remove", "Remove Icon"))], ..SurfacePlan::DEFAULT },
        targets: &["machine"],
        cli_name: "machine clear-icon",
        ..Action::DEFAULT
    },
];
