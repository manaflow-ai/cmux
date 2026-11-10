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
    Action {
        id: "cloud.computerControl",
        group: GROUP,
        title: t("CloudSessionActions", "action.cloud.computerControl", "Chief Computer Control…"),
        description: Some("Who drives the Chief's computer on a Cloud machine (--machine <id>, the bare id): action status, request_human (with --reason: what the person should do), hand_back (ends your own ask) or take_over (the person only). Returns machine, holder (chief or human), since_ms and reason. While holder is human, send the computer no input."),
        keywords: &["vm", "cloud", "chief", "computer", "desktop", "control", "take over", "hand back", "human"],
        category: "cloud",
        symbol: "hand.raised.square",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        arguments: &[args::COMPUTER_CONTROL_MACHINE, args::COMPUTER_CONTROL_ACTION, args::COMPUTER_CONTROL_REASON],
        cli_name: "cloud computer-control",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.chiefComputer",
        group: GROUP,
        title: t("CloudSessionActions", "action.cloud.chiefComputer", "Use Chief’s Own Computer…"),
        description: Some("A Chief of this Mac uses its own Cloud computer (Set Up Computer in its profile; engine.json computer chief:<id>): --chief <id>, --op screenshot, windows, click, move, drag, scroll, type, key, open, control, request_human, hand_back or start, --args a JSON object of the op's fields (x, y, to_x, to_y, button, count, text, keys, direction, amount, url, reason, shot). Returns done, image (base64 PNG or JPEG), windows, screen and control; refused with computer.human_has_control while the person holds it."),
        keywords: &["cloud", "chief", "computer", "desktop", "screenshot", "click", "type"],
        category: "cloud",
        symbol: "desktopcomputer",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("pointerMenuTrim"), ..SurfacePlan::DEFAULT },
        arguments: &[args::CHIEF_COMPUTER_CHIEF, args::CHIEF_COMPUTER_OP, args::CHIEF_COMPUTER_ARGS],
        cli_name: "cloud chief-computer",
        waits_for_result: true,
        ..Action::DEFAULT
    },
];
