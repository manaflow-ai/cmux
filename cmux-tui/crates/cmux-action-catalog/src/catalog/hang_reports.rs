// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `HangReportsActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "HangReportsActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "diagnostics.viewHangReport",
        group: GROUP,
        title: t("HangReportsActions", "action.diagnostics.viewHangReport", "View Hang Report"),
        keywords: &["hang", "lag", "report", "diagnostics", "privacy", "telemetry", "what is sent", "metrickit"],
        category: "settings",
        symbol: "doc.text.magnifyingglass",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "settings view-hang-report",
        ..Action::DEFAULT
    },
];
