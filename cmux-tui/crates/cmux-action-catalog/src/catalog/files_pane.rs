// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `FilesPaneActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "FilesPaneActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "files.open",
        group: GROUP,
        title: t("FilesPaneActions", "action.files.open", "Open Files"),
        keywords: &["files", "finder", "folder", "browse", "file manager", "explorer", "directory", "home"],
        category: "pane",
        symbol: "folder",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action files-open",
        ..Action::DEFAULT
    },
];
