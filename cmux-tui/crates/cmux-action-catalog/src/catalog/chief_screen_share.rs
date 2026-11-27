// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ChiefScreenShareActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "ChiefScreenShareActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "chief.screenShare.toggle",
        group: GROUP,
        title: t("ActionCatalog", "action.chief.screenShare.toggle", "Chief: Toggle Screen Sharing"),
        keywords: &["chief", "screen", "share", "sharing", "capture", "see", "memory", "record", "toggle"],
        category: "agents",
        symbol: "display",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "chief toggle-screen-share",
        is_person_only: true,
        ..Action::DEFAULT
    },
    Action {
        id: "chief.screenShare.start",
        group: GROUP,
        title: t("ActionCatalog", "action.chief.screenShare.start", "Share Screen with Chief"),
        keywords: &["chief", "screen", "share", "sharing", "capture", "see", "memory", "record", "start"],
        category: "agents",
        symbol: "display",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "chief share-screen",
        is_person_only: true,
        ..Action::DEFAULT
    },
    Action {
        id: "chief.screenShare.stop",
        group: GROUP,
        title: t("ActionCatalog", "action.chief.screenShare.stop", "Stop Sharing Screen with Chief"),
        keywords: &["chief", "screen", "share", "sharing", "capture", "see", "memory", "record", "stop", "end"],
        category: "agents",
        symbol: "stop.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "chief stop-sharing-screen",
        ..Action::DEFAULT
    },
    Action {
        id: "chief.screenShare.look",
        group: GROUP,
        title: t("ActionCatalog", "action.chief.screenShare.look", "Chief: Look at Screen Now"),
        keywords: &["chief", "screen", "share", "sharing", "capture", "see", "memory", "record", "look", "now", "screenshot"],
        category: "agents",
        symbol: "eye",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "chief look-at-screen",
        ..Action::DEFAULT
    },
];
