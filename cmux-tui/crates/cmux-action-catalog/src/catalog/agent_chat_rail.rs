// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentChatRailActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentChatRailActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agentPane.display.showMinimap",
        group: GROUP,
        title: t("ActionCatalog", "action.agentPane.display.showMinimap", "Show Chat Minimap"),
        keywords: &["agent", "chat", "minimap", "rail", "tick", "ticks", "prompt rail", "map", "hide", "edge", "setting"],
        category: "settings",
        symbol: "sidebar.right",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        cli_name: "action agent-pane-display-show-minimap",
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.display.railOnRight",
        group: GROUP,
        title: t("ActionCatalog", "action.agentPane.display.railOnRight", "Prompt Rail on Right Edge"),
        keywords: &["agent", "chat", "minimap", "rail", "tick", "ticks", "prompt rail", "side", "left", "right", "edge", "setting"],
        category: "settings",
        symbol: "arrow.left.and.right",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        cli_name: "action agent-pane-display-rail-on-right",
        ..Action::DEFAULT
    },
];
