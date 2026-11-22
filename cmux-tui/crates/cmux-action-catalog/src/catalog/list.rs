// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ListActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "ListActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "list.next",
        group: GROUP,
        title: t("ActionCatalog", "action.list.next", "Next Item"),
        keywords: &["list", "down", "next", "select"],
        category: "window",
        symbol: "chevron.down",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("liveInput"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("liveInput"), ..SurfacePlan::DEFAULT },
        cli_name: "action list-next",
        ..Action::DEFAULT
    },
    Action {
        id: "list.previous",
        group: GROUP,
        title: t("ActionCatalog", "action.list.previous", "Previous Item"),
        keywords: &["list", "up", "previous", "select"],
        category: "window",
        symbol: "chevron.up",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("liveInput"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("liveInput"), ..SurfacePlan::DEFAULT },
        cli_name: "action list-previous",
        ..Action::DEFAULT
    },
];
