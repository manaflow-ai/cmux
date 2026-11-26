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
    // Leo, 2026-11-22: "it was cumbersome back then to switch back" and "the fast-actions need to
    // be most accessible": one click between a rotating folder and a past pick
    // (appearance.backgroundRecents, recorded by cmux-config's settings write).
    Action {
        id: "appearance.previousBackground",
        group: GROUP,
        title: t("ActionCatalog", "action.appearance.previousBackground", "Switch to Previous Background"),
        keywords: &["background", "wallpaper", "previous", "back", "last", "swap", "toggle", "folder", "recent"],
        category: "settings",
        symbol: "arrow.uturn.backward",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("windowBackground", "identity", 1)], ..SurfacePlan::DEFAULT },
        cli_name: "wallpaper back",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.recentBackgrounds",
        group: GROUP,
        title: t("ActionCatalog", "action.appearance.recentBackgrounds", "Recent Backgrounds…"),
        keywords: &["background", "wallpaper", "recent", "history", "previous", "folder", "picture"],
        category: "settings",
        symbol: "clock.arrow.circlepath",
        surfaces: PALETTE | CONTEXT_MENU,
        arguments: &[RECENT_BACKGROUND],
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("windowBackground", "identity", 2)], ..SurfacePlan::DEFAULT },
        cli_name: "wallpaper recent",
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
    // Leo, 2026-11-22: "we also want people to be able to reposition the images easily. the
    // fast-actions need to be most accessible." Drag, zoom, Fill, Fit (appearance.backgroundPlacement).
    Action {
        id: "appearance.adjustBackground",
        group: GROUP,
        title: t("ActionCatalog", "action.appearance.adjustBackground", "Adjust Background…"),
        keywords: &["background", "wallpaper", "position", "move", "drag", "zoom", "crop", "fit", "fill", "place"],
        category: "settings",
        symbol: "arrow.up.and.down.and.arrow.left.and.right",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("windowBackground", "identity", 1)], ..SurfacePlan::DEFAULT },
        cli_name: "settings adjust-background",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.background.fill",
        group: GROUP,
        title: t("ActionCatalog", "action.appearance.background.fill", "Background: Fill Window"),
        keywords: &["background", "wallpaper", "fill", "cover", "crop", "position"],
        category: "settings",
        symbol: "arrow.up.left.and.arrow.down.right",
        surfaces: PALETTE,
        // Adjust Background… (on the window background's menu) offers Fill and Fit.
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        cli_name: "settings background-fill",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.background.fit",
        group: GROUP,
        title: t("ActionCatalog", "action.appearance.background.fit", "Background: Fit Window"),
        keywords: &["background", "wallpaper", "fit", "whole", "contain", "position"],
        category: "settings",
        symbol: "arrow.down.right.and.arrow.up.left",
        surfaces: PALETTE,
        // Adjust Background… (on the window background's menu) offers Fill and Fit.
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        cli_name: "settings background-fit",
        ..Action::DEFAULT
    },
];

/// Recent Backgrounds…'s pick: one of appearance.backgroundRecents (the app's `backgroundRecents`
/// suggestions).
#[rustfmt::skip]
const RECENT_BACKGROUND: Argument = Argument { name: "background", title: t("ActionCatalog", "argument.recentBackground", "Background"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "backgroundRecents", pinned: &[], other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
