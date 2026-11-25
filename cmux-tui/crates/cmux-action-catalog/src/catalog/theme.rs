// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ThemeActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "ThemeActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "space.setTheme",
        group: GROUP,
        title: t("ThemeActions", "action.space.setTheme", "Set Space Theme…"),
        keywords: &["room", "profile", "theme", "colors", "ghostty", "appearance"],
        category: "workspace",
        symbol: "paintbrush",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("profile", "identity", 200).style("choices").parent("space.setColor")], ..SurfacePlan::DEFAULT },
        arguments: &[args::THEME],
        targets: &["room"],
        cli_name: "space set-theme",
        ..Action::DEFAULT
    },
    Action {
        id: "space.clearTheme",
        group: GROUP,
        title: t("ThemeActions", "action.space.clearTheme", "Reset Space Theme"),
        keywords: &["room", "profile", "theme", "reset", "ghostty"],
        category: "workspace",
        symbol: "eraser",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("profile", "identity", 201).parent("space.setColor")], ..SurfacePlan::DEFAULT },
        targets: &["room"],
        cli_name: "space clear-theme",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.setTheme",
        group: GROUP,
        title: t("ThemeActions", "action.workspace.setTheme", "Set Workspace Theme…"),
        keywords: &["workspace", "theme", "colors", "ghostty", "appearance"],
        category: "workspace",
        symbol: "paintbrush",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("agentChat", "identity", 1).style("choices").label(t("AgentChatMenu", "menu.agentChat.theme", "Theme"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::THEME],
        targets: &["workspace"],
        cli_name: "workspace set-theme",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.clearTheme",
        group: GROUP,
        title: t("ThemeActions", "action.workspace.clearTheme", "Reset Workspace Theme"),
        keywords: &["workspace", "theme", "reset", "ghostty"],
        category: "workspace",
        symbol: "eraser",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "identity", 109).folder("appearance")], ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "workspace clear-theme",
        ..Action::DEFAULT
    },
    Action {
        id: "terminal.setTheme",
        group: GROUP,
        title: t("ThemeActions", "action.terminal.setTheme", "Set Terminal Theme…"),
        keywords: &["terminal", "tab", "theme", "colors", "ghostty", "palette"],
        category: "terminal",
        symbol: "paintbrush",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        arguments: &[args::THEME],
        targets: &["tab"],
        cli_name: "terminal set-theme",
        ..Action::DEFAULT
    },
    Action {
        id: "terminal.clearTheme",
        group: GROUP,
        title: t("ThemeActions", "action.terminal.clearTheme", "Reset Terminal Theme"),
        keywords: &["terminal", "tab", "theme", "reset", "ghostty"],
        category: "terminal",
        symbol: "eraser",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "terminal clear-theme",
        ..Action::DEFAULT
    },
];
