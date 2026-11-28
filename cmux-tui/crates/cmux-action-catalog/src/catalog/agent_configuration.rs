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
    // Secrets for one chat only (acpmux `chat_secrets.rs`, hq RFD 0211 VM item 4): the values of
    // --names from this Mac's Keychain go to this Mac's acpmux over the person's own connection,
    // which keeps them in memory for that chat with a TTL and gives them to that chat's agent only.
    Action {
        id: "agentPane.deliverSecrets",
        group: GROUP,
        title: Text::raw("Give Secrets to This Chat…"),
        description: Some("Gives one agent chat (--target agent-chat:<session id>, or the focused chat) the values of --names A,B from this Mac's Keychain (--repo OWNER/NAME for repo-scoped ones), for that chat only: acpmux holds them in memory, never on disk, for an hour, and puts them in that chat's agent environment and no other chat's; the agent restarts between turns to get them. Values are stored with cmux cloud secret set NAME. Returns session_id, delivered, missing and applied."),
        keywords: &["agent", "chat", "secret", "secrets", "env", "keychain", "token", "scope", "deliver"],
        category: "agents",
        symbol: "key",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        arguments: &[args::NAMES, args::REPO_2.optional()],
        targets: &["pane", "tab", "agent-chat"],
        cli_name: "agent deliver-secrets",
        waits_for_result: true,
        ..Action::DEFAULT
    },
];
