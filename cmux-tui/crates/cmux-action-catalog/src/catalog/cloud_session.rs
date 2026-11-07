// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `CloudSessionActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "CloudSessionActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "cloudStartSession",
        group: GROUP,
        title: t("CloudSessionActions", "action.cloudStartSession", "Start Agent Session on Cloud Machine…"),
        description: Some("Starts an agent session (--agent claude, codex, ...) in the Cloud machine's own acpmux and returns machine_id, session_id and host, plus the chat tab's workspace_id and surface_id. Name the machine with --target machine:<id>, or --name <name> to take or create it; --cwd is the folder there. --login pass|machine|none: your login, the machine's own, or none (default: the machine's login or your earlier choice). An agent's run asks no one (unless cloud.agentsStartWithoutAsking is off). A slow run answers pending: true; run it again for its session."),
        keywords: &["vm", "cloud", "agent", "session", "chat", "acp", "acpmux", "start", "claude", "codex"],
        category: "cloud",
        symbol: "sparkles",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("cloudMachine", "connection", 221).folder("connection")], ..SurfacePlan::DEFAULT },
        arguments: &[args::AGENT_3, args::NAME_6.optional(), args::CWD_3.optional(), args::LOGIN.optional()],
        targets: &["machine"],
        cli_name: "cloud start-session",
        waits_for_person: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloudRelayChat",
        group: GROUP,
        title: t("CloudSessionActions", "action.cloudRelayChat", "Chat on Cloud Machine via the Relay…"),
        description: Some("Sends --prompt to --agent (claude, codex, ...) on a Cloud machine (--target machine:<id>) over the machine's relay and answers when the turn ends. A machine with no link yet gets this Mac's link and its owner check first, then the person's harness login, then the send. The answer carries session_id (the machine's acpmux session), reply, stop_reason, first_text_ms and total_ms. A turn still running after 35 s answers what came so far with ended: false and goes on in that session while the app runs. delivered: false means the prompt never reached the machine (no machine took it, or the relay refused it). --cwd is the folder there; --prompt-id makes a resend run once."),
        keywords: &["vm", "cloud", "agent", "chat", "relay", "prompt", "claude", "codex"],
        category: "cloud",
        symbol: "bubble.left.and.text.bubble.right",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        arguments: &[args::AGENT_3, args::PROMPT, args::CWD_3.optional(), args::PROMPT_ID.optional()],
        targets: &["machine"],
        cli_name: "cloud relay-chat",
        waits_for_result: true,
        ..Action::DEFAULT
    },
];
