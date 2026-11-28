// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AppearanceModeActionCatalog` actions: `appearance.mode` (Light, Dark, or the
//! system's, the default) from the palette and the CLI.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "AppearanceModeActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "appearance.mode.system",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.mode.system", "Appearance: Match System"),
        keywords: &["appearance", "mode", "system", "auto", "automatic", "light", "dark", "color scheme", "macos"],
        category: "settings",
        symbol: "circle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings appearance-system",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.mode.light",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.mode.light", "Appearance: Light"),
        keywords: &["appearance", "mode", "light", "light mode", "bright", "day", "color scheme"],
        category: "settings",
        symbol: "sun.max",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings appearance-light",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.mode.dark",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.mode.dark", "Appearance: Dark"),
        keywords: &["appearance", "mode", "dark", "dark mode", "night", "color scheme"],
        category: "settings",
        symbol: "moon",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings appearance-dark",
        ..Action::DEFAULT
    },
];
