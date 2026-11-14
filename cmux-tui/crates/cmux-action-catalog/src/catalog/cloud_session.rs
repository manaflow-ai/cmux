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
        description: Some("Starts an agent session (--agent claude, codex, ...) in the Cloud machine's own acpmux and returns machine_id, session_id and host, plus the chat tab's workspace_id and surface_id. Name the machine with --target machine:<id>, or --name <name> to take or create it; --cwd is the folder there, or --from-folder copies one from this Mac. --login pass|machine|none: your login, the machine's own, or none (default: the machine's login or your earlier choice). An agent's run asks no one (unless cloud.agentsStartWithoutAsking is off). A slow run answers pending: true; run it again for its session."),
        keywords: &["vm", "cloud", "agent", "session", "chat", "acp", "acpmux", "start", "claude", "codex"],
        category: "cloud",
        symbol: "sparkles",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("cloudMachine", "connection", 221).folder("connection")], ..SurfacePlan::DEFAULT },
        arguments: &[args::AGENT_3, args::NAME_6.optional(), args::CWD_3.optional(), args::FROM_FOLDER, args::LOGIN.optional(), args::MODEL.optional()],
        targets: &["machine"],
        cli_name: "cloud start-session",
        waits_for_person: true,
        ..Action::DEFAULT
    },
];
