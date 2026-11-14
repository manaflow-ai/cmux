// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `JoinedMachineActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "JoinedMachineActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "machine.joined.check",
        group: GROUP,
        title: t("RemoteActions", "action.machine.joined.check", "Check Joined Machine"),
        keywords: &["machine", "joined", "join", "doctor", "health", "check", "mesh", "heartbeat"],
        category: "remote",
        symbol: "stethoscope",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { palette: Decision::Exempt("guiOnly"), cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("joinedMachine", "connection", 0).label(t("RemoteActions", "menu.machine.joined.check", "Check"))], ..SurfacePlan::DEFAULT },
        targets: &["machine"],
        cli_name: "action machine-joined-check",
        ..Action::DEFAULT
    },
    Action {
        id: "machine.joined.rotate",
        group: GROUP,
        title: t("RemoteActions", "action.machine.joined.rotate", "Rotate Joined Machine's Credential"),
        keywords: &["machine", "joined", "join", "credential", "rotate", "key", "token", "secret"],
        category: "remote",
        symbol: "key",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { palette: Decision::Exempt("guiOnly"), cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("joinedMachine", "connection", 1).label(t("RemoteActions", "menu.machine.joined.rotate", "Rotate Credential"))], ..SurfacePlan::DEFAULT },
        targets: &["machine"],
        cli_name: "action machine-joined-rotate",
        ..Action::DEFAULT
    },
    Action {
        id: "machine.joined.revoke",
        group: GROUP,
        title: t("RemoteActions", "action.machine.joined.revoke", "Revoke Joined Machine…"),
        keywords: &["machine", "joined", "join", "revoke", "remove", "disconnect", "access", "team"],
        category: "remote",
        symbol: "xmark.circle",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { palette: Decision::Exempt("guiOnly"), cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("joinedMachine", "close", 0).label(t("RemoteActions", "menu.machine.joined.revoke", "Revoke…"))], ..SurfacePlan::DEFAULT },
        targets: &["machine"],
        cli_name: "action machine-joined-revoke",
        ..Action::DEFAULT
    },
];
