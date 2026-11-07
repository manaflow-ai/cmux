// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `LinkActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "LinkActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "link.open",
        group: GROUP,
        title: t("ActionCatalog", "action.link.open", "Open Link…"),
        keywords: &["link", "url", "deeplink", "cmux://", "go to", "jump", "paste"],
        category: "window",
        symbol: "link",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::URL_2, args::BACKGROUND_2.optional(), args::SOURCE_3.optional()],
        cli_name: "link open",
        ..Action::DEFAULT
    },
];
