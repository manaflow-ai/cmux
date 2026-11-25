// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ProfileMenuActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "ProfileMenuActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "sidebar.profileMenu",
        group: GROUP,
        title: t("ProfileActions", "action.sidebar.profileMenu", "Show Profile Menu"),
        keywords: &["profile", "account", "avatar", "menu", "bookmarks", "downloads", "extensions", "history", "developer"],
        category: "sidebar",
        symbol: "person.crop.circle",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "sidebar profile-menu",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.downloads.showFolder",
        group: GROUP,
        title: t("ProfileActions", "action.browser.downloads.showFolder", "Open Downloads Folder"),
        keywords: &["downloads", "files", "finder", "browser"],
        category: "browser",
        symbol: "arrow.down.to.line",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "browser downloads-folder",
        ..Action::DEFAULT
    },
];
