// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `PaneBackgroundActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "PaneBackgroundActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "pane.setBackground",
        group: GROUP,
        title: t("LayoutActions", "action.pane.setBackground", "Set Pane Background…"),
        keywords: &["pane", "background", "wallpaper", "art", "painting", "backdrop", "image", "split"],
        category: "pane",
        symbol: "photo",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("pane", "identity", 104).style("choices").folder("appearance")], ..SurfacePlan::DEFAULT },
        arguments: &[args::BACKGROUND],
        targets: &["pane"],
        cli_name: "pane set-background",
        ..Action::DEFAULT
    },
    Action {
        id: "pane.setTint",
        group: GROUP,
        title: t("LayoutActions", "action.pane.setTint", "Set Pane Tint…"),
        keywords: &["pane", "tint", "color", "colour", "marker", "agent", "prod", "background"],
        category: "pane",
        symbol: "paintpalette",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("pane", "identity", 105).style("choices").folder("appearance")], ..SurfacePlan::DEFAULT },
        arguments: &[args::COLOR_2],
        targets: &["pane"],
        cli_name: "pane set-tint",
        ..Action::DEFAULT
    },
    Action {
        id: "pane.clearBackground",
        group: GROUP,
        title: t("LayoutActions", "action.pane.clearBackground", "Reset Pane Background"),
        keywords: &["pane", "background", "tint", "reset", "clear", "inherit"],
        category: "pane",
        symbol: "photo.badge.arrow.down",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("pane", "identity", 106).folder("appearance")], ..SurfacePlan::DEFAULT },
        targets: &["pane"],
        cli_name: "pane clear-background",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.setTint",
        group: GROUP,
        title: t("LayoutActions", "action.workspace.setTint", "Set Workspace Tint…"),
        keywords: &["workspace", "tint", "color", "colour", "marker", "prod", "project"],
        category: "workspace",
        symbol: "paintpalette",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        arguments: &[args::COLOR_2],
        targets: &["workspace"],
        cli_name: "workspace set-tint",
        ..Action::DEFAULT
    },
    Action {
        id: "tab.setTint",
        group: GROUP,
        title: t("LayoutActions", "action.tab.setTint", "Set Tab Tint…"),
        keywords: &["tab", "tint", "color", "colour", "marker", "agent", "terminal"],
        category: "terminal",
        symbol: "paintpalette",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tab", "identity", 207).style("choices").folder("options")], ..SurfacePlan::DEFAULT },
        arguments: &[args::COLOR_2],
        targets: &["tab"],
        cli_name: "tab set-tint",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.set",
        group: GROUP,
        title: t("LayoutActions", "action.appearance.set", "Set Appearance…"),
        keywords: &["appearance", "theme", "background", "wallpaper", "tint", "opacity", "window", "workspace", "pane", "tab"],
        category: "settings",
        symbol: "paintbrush",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[args::SCOPE_2, args::PROPERTY, args::VALUE],
        targets: &["tab", "pane", "workspace"],
        cli_name: "appearance set",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.reset",
        group: GROUP,
        title: t("LayoutActions", "action.appearance.reset", "Reset Appearance to Inherited"),
        keywords: &["appearance", "reset", "inherit", "inherited", "theme", "background", "tint"],
        category: "settings",
        symbol: "arrow.uturn.backward",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[args::SCOPE_2, args::PROPERTY.optional()],
        targets: &["tab", "pane", "workspace"],
        cli_name: "appearance reset",
        ..Action::DEFAULT
    },
];
