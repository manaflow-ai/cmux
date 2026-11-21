// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `HibernationActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "HibernationActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "browser.hibernation.off",
        group: GROUP,
        title: t("HibernationActions", "action.hibernation.off", "Turn Off Tab Hibernation"),
        keywords: &["browser", "hibernation", "memory", "saver", "discard", "sleep", "off", "disable"],
        category: "settings",
        symbol: "moon.zzz",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings turn-off-tab-hibernation",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.hibernation.moderate",
        group: GROUP,
        title: t("HibernationActions", "action.hibernation.moderate30", "Hibernate Hidden Tabs After 30 Minutes"),
        keywords: &["browser", "hibernation", "memory", "saver", "discard", "sleep", "moderate"],
        category: "settings",
        symbol: "moon",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings use-moderate-tab-hibernation",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.hibernation.aggressive",
        group: GROUP,
        title: t("HibernationActions", "action.hibernation.aggressive", "Hibernate Hidden Tabs After 10 Minutes"),
        keywords: &["browser", "hibernation", "memory", "saver", "discard", "sleep", "aggressive"],
        category: "settings",
        symbol: "moon.fill",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings use-aggressive-tab-hibernation",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.keepNeighborTabsAwake.0",
        group: GROUP,
        title: t("HibernationActions", "action.neighborTabs.off", "Don't Keep Neighbor Tabs Awake"),
        keywords: &["browser", "tabs", "neighbor", "adjacent", "warm", "preload", "instant", "switch", "hibernation", "freeze", "off", "disable"],
        category: "settings",
        symbol: "rectangle.stack",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "settings keep-no-neighbor-tabs-awake",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.keepNeighborTabsAwake.1",
        group: GROUP,
        title: t("HibernationActions", "action.neighborTabs.one", "Keep 1 Neighbor Tab Awake on Each Side"),
        keywords: &["browser", "tabs", "neighbor", "adjacent", "warm", "preload", "instant", "switch", "hibernation", "freeze", "1", "one"],
        category: "settings",
        symbol: "rectangle.stack.fill",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "settings keep-1-neighbor-tab-awake",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.keepNeighborTabsAwake.2",
        group: GROUP,
        title: t("HibernationActions", "action.neighborTabs.two", "Keep 2 Neighbor Tabs Awake on Each Side"),
        keywords: &["browser", "tabs", "neighbor", "adjacent", "warm", "preload", "instant", "switch", "hibernation", "freeze", "2", "two"],
        category: "settings",
        symbol: "rectangle.stack.fill",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "settings keep-2-neighbor-tabs-awake",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.keepNeighborTabsAwake.3",
        group: GROUP,
        title: t("HibernationActions", "action.neighborTabs.three", "Keep 3 Neighbor Tabs Awake on Each Side"),
        keywords: &["browser", "tabs", "neighbor", "adjacent", "warm", "preload", "instant", "switch", "hibernation", "freeze", "3", "three"],
        category: "settings",
        symbol: "rectangle.stack.fill",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "settings keep-3-neighbor-tabs-awake",
        ..Action::DEFAULT
    },
    Action {
        id: "hibernateTab",
        group: GROUP,
        title: t("HibernationActions", "action.hibernateTab", "Hibernate Tab"),
        keywords: &["tab", "browser", "hibernate", "sleep", "discard", "memory", "saver"],
        category: "tab",
        symbol: "moon.zzz",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "tab hibernate",
        ..Action::DEFAULT
    },
    Action {
        id: "neverHibernateSite",
        group: GROUP,
        title: t("HibernationActions", "action.neverHibernateSite", "Never Hibernate This Site"),
        keywords: &["tab", "browser", "hibernate", "sleep", "discard", "exception", "exclude", "site", "keep", "awake"],
        category: "tab",
        symbol: "moon.circle",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "tab never-hibernate-site",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.hibernate",
        group: GROUP,
        title: t("HibernationActions", "action.workspace.hibernate", "Hibernate Workspace"),
        keywords: &["workspace", "hibernate", "sleep", "pause", "memory", "ram", "evict", "free", "idle"],
        category: "workspace",
        symbol: "moon.zzz",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "identity", 116).folder("options")], ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "workspace hibernate",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.toggleKeepAwake",
        group: GROUP,
        title: t("HibernationActions", "action.workspace.keepAwake", "Keep Workspace Awake"),
        keywords: &["workspace", "hibernate", "hibernation", "awake", "keep", "never", "sleep", "memory", "exception"],
        category: "workspace",
        symbol: "sun.max",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "identity", 117).folder("options")], ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "workspace toggle-keep-awake",
        ..Action::DEFAULT
    },
    Action {
        id: "wakeTab",
        group: GROUP,
        title: t("HibernationActions", "action.wakeTab", "Wake Tab"),
        keywords: &["tab", "browser", "wake", "restore", "hibernate", "reload"],
        category: "tab",
        symbol: "sun.max",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "tab wake",
        ..Action::DEFAULT
    },
];
