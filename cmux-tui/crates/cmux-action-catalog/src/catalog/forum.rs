// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ForumActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "ForumActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "forum.show",
        group: GROUP,
        title: t("ActionCatalog", "action.forum.show", "Forum"),
        keywords: &["forum", "threads", "questions", "findings", "team", "agents", "posts", "replies"],
        category: "window",
        symbol: "text.bubble",
        surfaces: PALETTE,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action forum-show",
        ..Action::DEFAULT
    },
];
