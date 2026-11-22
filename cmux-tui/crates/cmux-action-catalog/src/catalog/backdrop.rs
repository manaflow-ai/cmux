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
        keywords: &["background", "wallpaper", "art", "painting", "backdrop", "appearance", "youtube", "video"],
        category: "settings",
        symbol: "photo",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("agentChat", "identity", 0), Placement::at("windowBackground", "identity", 0)], ..SurfacePlan::DEFAULT },
        cli_name: "settings change-background",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.background.followDesktop",
        group: GROUP,
        title: t("ActionCatalog", "action.appearance.background.followDesktop", "Follow Desktop Wallpaper"),
        description: Some("Sets appearance.background to desktop: the window shows the macOS desktop picture of its screen and follows every change (rotation, Spaces, aerials, time of day)."),
        keywords: &["desktop", "wallpaper", "macos", "follow", "desktop picture", "background", "system wallpaper"],
        category: "settings",
        symbol: "menubar.dock.rectangle",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("agentChat", "identity", 1), Placement::at("windowBackground", "identity", 1)], ..SurfacePlan::DEFAULT },
        cli_name: "action appearance-background-follow-desktop",
        ..Action::DEFAULT
    },
];
