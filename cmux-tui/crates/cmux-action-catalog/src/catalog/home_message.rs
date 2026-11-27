// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `HomeMessageActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "HomeMessageActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "home.messageTo",
        group: GROUP,
        title: t("HomeActions", "action.home.messageTo", "Send Message To…"),
        keywords: &["home", "send", "message", "chat", "imessage", "chief", "agent", "dm", "to", "write"],
        category: "window",
        symbol: "paperplane",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::TO_2, args::TEXT_4.optional()],
        cli_name: "chat send",
        ..Action::DEFAULT
    },
    Action {
        id: "home.messageAbout",
        group: GROUP,
        title: t("HomeActions", "action.home.messageAbout", "Send Message…"),
        keywords: &["home", "send", "message", "chat", "imessage", "chief", "agent", "workspace", "tab", "about"],
        category: "window",
        symbol: "paperplane",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Exempt("familyMember")), context_menus: &[Placement::at("workspaceRow", "navigate", 50), Placement::at("tab", "navigate", 50), Placement::at("agentChat", "navigate", 50)], ..SurfacePlan::DEFAULT },
        targets: &["workspace", "tab"],
        cli_name: "action home-message-about",
        ..Action::DEFAULT
    },
    Action {
        id: "home.sendSelectionToChief",
        group: GROUP,
        title: t("HomeActions", "action.home.sendSelectionToChief", "Send to Chief"),
        keywords: &["home", "send", "chief", "selection", "quote", "message", "chat", "text"],
        category: "window",
        symbol: "paperplane",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { palette: Decision::Exempt("liveInput"), cli: Some(Decision::Exempt("familyMember")), context_menus: &[Placement::at("terminalSelection", "edit", 10), Placement::at("browserSelection", "edit", 10)], ..SurfacePlan::DEFAULT },
        arguments: &[args::TEXT_5.optional()],
        cli_name: "action home-send-selection-to-chief",
        ..Action::DEFAULT
    },
    Action {
        id: "home.sendSelectionTo",
        group: GROUP,
        title: t("HomeActions", "action.home.sendSelectionTo", "Send To…"),
        keywords: &["home", "send", "forward", "agent", "selection", "quote", "message", "chat", "text"],
        category: "window",
        symbol: "arrowshape.turn.up.right",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { palette: Decision::Exempt("liveInput"), cli: Some(Decision::Exempt("familyMember")), context_menus: &[Placement::at("terminalSelection", "edit", 11), Placement::at("browserSelection", "edit", 11)], ..SurfacePlan::DEFAULT },
        arguments: &[args::TEXT_5.optional(), args::TO_2],
        cli_name: "action home-send-selection-to",
        ..Action::DEFAULT
    },
];
