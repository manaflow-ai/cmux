// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AutomationsActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "AutomationsActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "automations.show",
        group: GROUP,
        title: t("ActionCatalog", "action.automations.show", "Automations"),
        keywords: &["automations", "scheduled", "schedule", "cron", "jobs", "tasks", "recurring", "routines", "every morning"],
        category: "window",
        symbol: "clock.badge.checkmark",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "automation show-page",
        ..Action::DEFAULT
    },
];
