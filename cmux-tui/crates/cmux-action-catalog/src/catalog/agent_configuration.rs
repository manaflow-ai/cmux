// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentConfigurationActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentConfigurationActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agentPane.setModel",
        group: GROUP,
        title: t("AgentConfigurationActions", "action.agentPane.setModel", "Set Agent Chat Model…"),
        keywords: &["agent", "chat", "model", "models", "harness", "provider", "llm", "switch", "change", "set"],
        category: "agents",
        symbol: "cpu",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        arguments: &[args::MODEL_2],
        targets: &["pane", "tab", "agent-chat"],
        cli_name: "agent set-model",
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.setEffort",
        group: GROUP,
        title: t("AgentConfigurationActions", "action.agentPane.setEffort", "Set Agent Chat Effort…"),
        keywords: &["agent", "chat", "effort", "reasoning", "thinking", "depth", "fast", "slow", "set", "change"],
        category: "agents",
        symbol: "gauge.with.dots.needle.67percent",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        arguments: &[args::EFFORT],
        targets: &["pane", "tab", "agent-chat"],
        cli_name: "agent set-effort",
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.setMode",
        group: GROUP,
        title: t("AgentConfigurationActions", "action.agentPane.setMode", "Set Agent Chat Mode…"),
        keywords: &["agent", "chat", "mode", "permission", "access", "plan", "read-only", "full access", "set", "change"],
        category: "agents",
        symbol: "slider.horizontal.3",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        arguments: &[args::MODE],
        targets: &["pane", "tab", "agent-chat"],
        cli_name: "agent set-mode",
        ..Action::DEFAULT
    },
];
