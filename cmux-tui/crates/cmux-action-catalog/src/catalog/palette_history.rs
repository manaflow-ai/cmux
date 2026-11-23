// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `PaletteHistoryActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "PaletteHistoryActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "palette.clearSearchHistory",
        group: GROUP,
        title: t("SettingsActions", "action.palette.clearSearchHistory", "Clear Palette Search History"),
        keywords: &["palette", "search", "history", "memory", "recent", "frecency", "ranking", "forget", "reset"],
        category: "settings",
        symbol: "clock.arrow.circlepath",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "settings clear-palette-history",
        ..Action::DEFAULT
    },
];
