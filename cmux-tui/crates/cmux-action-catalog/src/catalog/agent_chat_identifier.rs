// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentChatIdentifierActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentChatIdentifierActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agentChat.copyIdentifier",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyIdentifier", "Copy Agent Identifier"),
        keywords: &["agent", "chat", "session", "identifier", "id", "acpmux", "message", "copy"],
        category: "agents",
        symbol: "at",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menus: &[Placement::at("tab", "inspect", 506).folder("copy"), Placement::at("agentChat", "inspect", 1)], ..SurfacePlan::DEFAULT },
        targets: &["tab", "workspace"],
        cli_name: "action agent-chat-copy-identifier",
        ..Action::DEFAULT
    },
];
