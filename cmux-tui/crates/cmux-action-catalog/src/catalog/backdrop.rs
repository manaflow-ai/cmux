// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `BackdropActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "BackdropActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "appearance.changeBackground",
        group: GROUP,
        title: t("ActionCatalog", "action.appearance.changeBackground", "Change Background…"),
        keywords: &["background", "wallpaper", "art", "painting", "backdrop", "appearance"],
        category: "settings",
        symbol: "photo",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("agentChat", "identity", 0), Placement::at("windowBackground", "identity", 0)], ..SurfacePlan::DEFAULT },
        cli_name: "settings change-background",
        ..Action::DEFAULT
    },
];
