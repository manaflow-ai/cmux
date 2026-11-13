// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentChatViewActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentChatViewActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agentChat.view",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.view", "View Chat Only"),
        keywords: &["agent", "chat", "session", "view", "watch", "read only", "claude", "codex", "take over"],
        category: "agents",
        symbol: "eye",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::KEY_2],
        cli_name: "agent view",
        ..Action::DEFAULT
    },
];
