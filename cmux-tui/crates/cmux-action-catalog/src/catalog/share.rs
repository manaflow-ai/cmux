// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ShareActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "ShareActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "app.shareCmux",
        group: GROUP,
        title: t("ActionCatalog", "action.app.shareCmux", "Share cmux…"),
        keywords: &["share", "invite", "friend", "recommend", "download link", "copy link", "tell a friend"],
        category: "settings",
        symbol: "square.and.arrow.up",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action app-share-cmux",
        main_menu: Some("help"),
        ..Action::DEFAULT
    },
];
