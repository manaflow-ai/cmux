// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentSideQuestionActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentSideQuestionActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agentPane.sideQuestion",
        group: GROUP,
        title: t("ActionCatalog", "action.agentPane.sideQuestion", "Ask a Side Question…"),
        keywords: &["agent", "chat", "btw", "side", "question", "aside", "ask", "session"],
        category: "agents",
        symbol: "questionmark.bubble",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-pane-side-question",
        ..Action::DEFAULT
    },
];
