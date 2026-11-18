// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ChromeStyleActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "ChromeStyleActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "appearance.chromeStyle.default",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.default", "Window Style: Default"),
        keywords: &["window", "style", "chrome", "appearance", "look"],
        category: "settings",
        symbol: "macwindow",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-default",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.chromeStyle.card",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.card", "Window Style: Card"),
        keywords: &["window", "style", "chrome", "appearance", "look", "card", "rounded", "curved", "dividers", "minimal"],
        category: "settings",
        symbol: "rectangle.inset.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-card",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.chromeStyle.cardOutlined",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.cardOutlined", "Window Style: Card with Outlines"),
        keywords: &["window", "style", "chrome", "appearance", "look", "card", "outlined", "outline", "borders"],
        category: "settings",
        symbol: "rectangle.split.2x1",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-card-outlined",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.chromeStyle.flat",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.flat", "Window Style: Flat"),
        keywords: &["window", "style", "chrome", "appearance", "look", "flat", "edge", "dividers", "minimal"],
        category: "settings",
        symbol: "rectangle",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-flat",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.chromeStyle.flatSidebarLine",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.flatSidebarLine", "Window Style: Flat with Sidebar Line"),
        keywords: &["window", "style", "chrome", "appearance", "look", "flat", "sidebar", "line", "border"],
        category: "settings",
        symbol: "sidebar.left",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-flat-sidebar-line",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.chromeStyle.bare",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.bare", "Window Style: Bare"),
        keywords: &["window", "style", "chrome", "appearance", "look", "bare", "no lines", "borderless", "seamless", "minimal"],
        category: "settings",
        symbol: "rectangle.dashed",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-bare",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.chromeStyle.panes",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.panes", "Window Style: Panes"),
        keywords: &["window", "style", "chrome", "appearance", "look", "panes", "cards", "outlined", "gaps", "borders"],
        category: "settings",
        symbol: "square.grid.2x2",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-panes",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.chromeStyle.twoTone",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.twoTone", "Window Style: Two-Tone"),
        keywords: &["window", "style", "chrome", "appearance", "look", "two-tone", "shade", "sidebar", "background", "card"],
        category: "settings",
        symbol: "rectangle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-two-tone",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.chromeStyle.floating",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.floating", "Window Style: Floating Panes"),
        keywords: &["window", "style", "chrome", "appearance", "look", "floating", "panes", "cards", "gaps", "rounded", "darker", "background", "no borders"],
        category: "settings",
        symbol: "square.grid.2x2.fill",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-floating",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.chromeStyle.blocks",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.chromeStyle.blocks", "Window Style: Blocks"),
        keywords: &["window", "style", "chrome", "appearance", "look", "blocks", "blocky", "solid", "flat", "tonal", "no borders", "no lines", "borderless"],
        category: "settings",
        symbol: "square.split.2x2.fill",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings window-style-blocks",
        ..Action::DEFAULT
    },
];
