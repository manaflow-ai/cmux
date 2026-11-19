// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ComputerUseApprovalActionCatalog` actions: Settings > Computer Use > Saved Approvals.
//! Forget an app's remembered answer, or change it to Always Allow or Never. The person's own
//! choices: the Settings page and the CLI run them; the app sends them to cmux Remote's Computer
//! Use worker through the daemon (`computer-use-approvals`).

use crate::model::*;
use crate::text::t;

const GROUP: &str = "ComputerUseApprovalActionCatalog";

#[rustfmt::skip]
const APP_ID: Argument = Argument { name: "appId", title: t("ComputerUseActions", "argument.computerUse.approval.appID", "App"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
const DECISION: Argument = Argument { name: "decision", title: t("ComputerUseActions", "argument.computerUse.approval.decision", "Always or Never"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "computerUse.approval.forget",
        group: GROUP,
        title: t("ComputerUseActions", "action.computerUse.approval.forget", "Forget a Computer Use Approval"),
        keywords: &["computer use", "approval", "forget", "app", "agent"],
        category: "agents",
        symbol: "xmark.circle",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("noObject"), cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[APP_ID],
        cli_name: "agent forget-computer-use-approval",
        ..Action::DEFAULT
    },
    Action {
        id: "computerUse.approval.set",
        group: GROUP,
        title: t("ComputerUseActions", "action.computerUse.approval.set", "Change a Computer Use Approval"),
        keywords: &["computer use", "approval", "always", "never", "app", "agent"],
        category: "agents",
        symbol: "checkmark.circle",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("noObject"), cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[APP_ID, DECISION],
        cli_name: "agent set-computer-use-approval",
        ..Action::DEFAULT
    },
];
