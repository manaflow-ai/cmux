// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `FeedActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "FeedActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "feed.show",
        group: GROUP,
        title: t("ActionCatalog", "action.feed.show", "Feed"),
        keywords: &["feed", "updates", "inbox", "activity", "notifications", "agents", "approvals", "pull requests"],
        category: "window",
        symbol: "list.bullet.rectangle",
        surfaces: PALETTE,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action feed-show",
        ..Action::DEFAULT
    },
];
