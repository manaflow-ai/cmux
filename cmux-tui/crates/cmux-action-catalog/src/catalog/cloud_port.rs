// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `CloudPortActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "CloudPortActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "cloudOpenBrowser",
        group: GROUP,
        title: t("CloudPortActions", "action.cloudOpenBrowser", "Open Machine Port in Browser…"),
        description: Some("Opens --port N (and --path, default /) of the machine (--target machine:<id>) in a Chromium tab and returns url and surface_id. New Cloud uses its private preview URL. On the classic Cloud link the tab opens in the machine's workspace (workspace_id) and its localhost is the machine's."),
        keywords: &["vm", "cloud", "browser", "port", "localhost", "preview", "web"],
        category: "cloud",
        symbol: "safari",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("cloudMachine", "connection", 211).folder("connection")], ..SurfacePlan::DEFAULT },
        arguments: &[args::PORT, args::PATH.optional()],
        targets: &["machine"],
        cli_name: "cloud open-browser",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloudPortList",
        group: GROUP,
        title: t("CloudPortActions", "action.cloudPortList", "List Forwarded Machine Ports"),
        description: Some("Lists the machine's (--target machine:<id>) ports forwarded to this Mac: forwards, each with port, local_port, url and state. Only machines on the Cloud app server link keep forwards; on the classic link use `cmux cloud open-browser --target machine:<id> --port <port>`."),
        keywords: &["vm", "cloud", "port", "forward", "list"],
        category: "cloud",
        symbol: "list.bullet",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("cloudMachine", "connection", 212).folder("connection")], ..SurfacePlan::DEFAULT },
        targets: &["machine"],
        cli_name: "cloud port-list",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloudPortForward",
        group: GROUP,
        title: t("CloudPortActions", "action.cloudPortForward", "Forward Machine Port…"),
        description: Some("Forwards --port N of the machine (--target machine:<id>) to a port on this Mac and returns local_port, url (http://127.0.0.1:<local_port>/) and state. Close it with `cmux cloud port-close --target machine:<id> --port <port>`. Cloud app server link only."),
        keywords: &["vm", "cloud", "port", "forward", "tunnel", "localhost"],
        category: "cloud",
        symbol: "arrow.left.arrow.right",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("cloudMachine", "connection", 213).folder("connection")], ..SurfacePlan::DEFAULT },
        arguments: &[args::PORT],
        targets: &["machine"],
        cli_name: "cloud port-forward",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloudPortClose",
        group: GROUP,
        title: t("CloudPortActions", "action.cloudPortClose", "Close Forwarded Machine Port…"),
        description: Some("Stops forwarding --port N of the machine (--target machine:<id>) to this Mac and returns closed: true; a port with no forward is refused. `cmux cloud port-list --target machine:<id>` lists the forwards."),
        keywords: &["vm", "cloud", "port", "forward", "close", "stop"],
        category: "cloud",
        symbol: "xmark.circle",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("cloudMachine", "connection", 214).folder("connection")], ..SurfacePlan::DEFAULT },
        arguments: &[args::PORT],
        targets: &["machine"],
        cli_name: "cloud port-close",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloudPreviewShare",
        group: GROUP,
        title: t("CloudPortActions", "action.cloudPreviewShare", "Share Machine Preview…"),
        description: Some("Creates a one-day anonymous link for --port N of the machine (--target machine:<id>), copies it to the clipboard and returns the URL and linkId. Revoke it with `cmux cloud preview-revoke --target machine:<id> --port <port> --link-id <id>`. Cloud app server link only."),
        keywords: &["vm", "cloud", "preview", "port", "share", "link"],
        category: "cloud",
        symbol: "square.and.arrow.up",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("cloudMachine", "connection", 215).folder("connection")], ..SurfacePlan::DEFAULT },
        arguments: &[args::PORT],
        targets: &["machine"],
        cli_name: "cloud preview-share",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloudPreviewRevoke",
        group: GROUP,
        title: t("CloudPortActions", "action.cloudPreviewRevoke", "Revoke Machine Preview Link…"),
        description: Some("Revokes --link-id for --port N of the machine (--target machine:<id>) and returns revoked: true. Cloud app server link only."),
        keywords: &["vm", "cloud", "preview", "port", "share", "link", "revoke"],
        category: "cloud",
        symbol: "link.badge.plus",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("cloudMachine", "connection", 216).folder("connection")], ..SurfacePlan::DEFAULT },
        arguments: &[args::PORT, args::LINK_ID],
        targets: &["machine"],
        cli_name: "cloud preview-revoke",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloudMachineLink",
        group: GROUP,
        title: t("CloudPortActions", "action.cloudMachineLink", "Get Machine Link…"),
        description: Some("Returns the machine's (--target machine:<id>) link instead of copying it: machine_id, target and its private address. With --port N, also private_url and the platform's expiring share link for that port: url, linkId and expiresAt. Revoke it with `cmux cloud preview-revoke --target machine:<id> --port <port> --link-id <id>`."),
        keywords: &["vm", "cloud", "link", "url", "port"],
        category: "cloud",
        symbol: "link",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("duplicateOfDefault"), ..SurfacePlan::DEFAULT },
        arguments: &[args::PORT.optional()],
        targets: &["machine"],
        cli_name: "cloud machine-link",
        waits_for_result: true,
        ..Action::DEFAULT
    },
];
