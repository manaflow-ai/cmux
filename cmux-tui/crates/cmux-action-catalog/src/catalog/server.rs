// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ServerActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "ServerActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "server.makeThisMacAServer",
        group: GROUP,
        title: t("ServerActions", "action.server.makeThisMacAServer", "Make This Mac a Server"),
        keywords: &["server", "host", "self-host", "always on", "pair", "apps", "postgres"],
        category: "settings",
        symbol: "server.rack",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("devOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action server-make-this-mac-a-server",
        is_debug_only: true,
        ..Action::DEFAULT
    },
    Action {
        id: "server.stopServing",
        group: GROUP,
        title: t("ServerActions", "action.server.stopServing", "Stop Serving"),
        keywords: &["server", "stop", "disable", "host"],
        category: "settings",
        symbol: "stop.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("devOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action server-stop-serving",
        is_debug_only: true,
        ..Action::DEFAULT
    },
    Action {
        id: "server.addServer",
        group: GROUP,
        title: t("ServerActions", "action.server.addServer", "Add Server…"),
        keywords: &["server", "pair", "code", "approve", "add", "chief", "always on"],
        category: "settings",
        symbol: "plus.rectangle.on.rectangle",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::CODE.optional(), args::WORDS.optional(), args::NAME_9.optional(), args::CHIEF_4.optional()],
        cli_name: "servers add",
        main_menu: Some("server"),
        is_person_only: true,
        ..Action::DEFAULT
    },
    Action {
        id: "server.pairAnotherMachine",
        group: GROUP,
        title: t("ServerActions", "action.server.pairAnotherMachine", "Pair Another Machine…"),
        keywords: &["pair", "invite", "code", "qr", "machine", "server", "add", "connect", "link", "computer"],
        category: "settings",
        symbol: "qrcode",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action server-pair-another-machine",
        is_person_only: true,
        ..Action::DEFAULT
    },
    Action {
        id: "server.showPanel",
        group: GROUP,
        title: t("ServerActions", "action.server.showPanel", "Server Status"),
        keywords: &["server", "status", "menu bar", "terminals", "apps", "database", "chief"],
        category: "settings",
        symbol: "server.rack",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action server-show-panel",
        main_menu: Some("server"),
        ..Action::DEFAULT
    },
    Action {
        id: "server.showHealth",
        group: GROUP,
        title: t("ServerActions", "action.server.showHealth", "Server Health"),
        keywords: &["server", "health", "battery", "sleep", "disk", "lock", "internet"],
        category: "settings",
        symbol: "stethoscope",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("devOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action server-show-health",
        is_debug_only: true,
        ..Action::DEFAULT
    },
];
