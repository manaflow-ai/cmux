// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `DensityActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "DensityActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "appearance.density.ultraCompact",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.density.ultraCompact", "Density: Ultra-compact"),
        keywords: &["density", "size", "spacing", "rows", "appearance", "font", "ultra", "compact", "dense", "tight", "smallest"],
        category: "settings",
        symbol: "rectangle.compress.vertical",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "density use-ultra-compact",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.density.compact",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.density.compact", "Density: Compact"),
        keywords: &["density", "size", "spacing", "rows", "appearance", "font", "compact", "dense", "default"],
        category: "settings",
        symbol: "rectangle.compress.vertical",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings use-compact-density",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.density.cozy",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.density.cozy", "Density: Cozy"),
        keywords: &["density", "size", "spacing", "rows", "appearance", "font", "cozy", "medium", "middle"],
        category: "settings",
        symbol: "rectangle",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "density use-cozy",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.density.comfortable",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.density.comfortable", "Density: Comfortable"),
        keywords: &["density", "size", "spacing", "rows", "appearance", "font", "comfortable", "roomy", "larger"],
        category: "settings",
        symbol: "rectangle.expand.vertical",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings use-comfortable-density",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.density.spacious",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.density.spacious", "Density: Spacious"),
        keywords: &["density", "size", "spacing", "rows", "appearance", "font", "spacious", "large", "big", "accessible"],
        category: "settings",
        symbol: "rectangle.expand.vertical",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "density use-spacious",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.density.set",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.density.set", "Set Density…"),
        keywords: &["density", "size", "spacing", "rows", "appearance", "font", "custom", "choose", "pick"],
        category: "settings",
        symbol: "slider.vertical.3",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        arguments: &[args::DENSITY],
        cli_name: "density set",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.density.create",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.density.create", "New Custom Density…"),
        keywords: &["density", "size", "spacing", "rows", "appearance", "font", "custom", "new", "create", "duplicate"],
        category: "settings",
        symbol: "plus.rectangle.on.rectangle",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        arguments: &[args::NAME_7, args::BASED_ON.optional(), args::FONT_SIZE.optional()],
        cli_name: "density create",
        ..Action::DEFAULT
    },
];
