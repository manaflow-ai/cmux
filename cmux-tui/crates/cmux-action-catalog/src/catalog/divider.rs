// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `DividerActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "DividerActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "divider.insertNew",
        group: GROUP,
        title: t("LayoutActions", "action.divider.insertNew", "Insert New"),
        keywords: &["divider", "split", "insert", "new", "between", "pane", "terminal", "browser", "agent", "chat", "tab"],
        category: "pane",
        symbol: "rectangle.split.3x1",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("divider", "create", 0).style("choices")], ..SurfacePlan::DEFAULT },
        arguments: &[args::KIND_2, args::SPLIT_2.optional()],
        targets: &["workspace"],
        cli_name: "divider insert",
        ..Action::DEFAULT
    },
    Action {
        id: "divider.hide",
        group: GROUP,
        title: t("LayoutActions", "action.divider.hide", "Hide Divider"),
        keywords: &["divider", "split", "line", "hide", "invisible", "separator", "border"],
        category: "pane",
        symbol: "eye.slash",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("divider", "view", 0)], ..SurfacePlan::DEFAULT },
        arguments: &[args::SPLIT_2.optional()],
        targets: &["workspace"],
        cli_name: "divider hide",
        ..Action::DEFAULT
    },
    Action {
        id: "divider.show",
        group: GROUP,
        title: t("LayoutActions", "action.divider.show", "Show Divider"),
        keywords: &["divider", "split", "line", "show", "visible", "separator", "border"],
        category: "pane",
        symbol: "eye",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("divider", "view", 1)], ..SurfacePlan::DEFAULT },
        arguments: &[args::SPLIT_2.optional()],
        targets: &["workspace"],
        cli_name: "divider show",
        ..Action::DEFAULT
    },
];
