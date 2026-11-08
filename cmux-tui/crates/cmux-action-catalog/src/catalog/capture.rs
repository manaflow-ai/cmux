// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `CaptureActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "CaptureActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "capture.open",
        group: GROUP,
        title: t("ActionCatalog", "action.capture.open", "Capture…"),
        keywords: &["screenshot", "screen recording", "record", "video", "capture", "share screen", "attach"],
        default_shortcut: Some(Shortcut { key: "5", modifiers: CTRL | SHIFT | CMD }),
        category: "agents",
        symbol: "camera.viewfinder",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        targets: &["pane"],
        cli_name: "action capture-open",
        main_menu: Some("view"),
        ..Action::DEFAULT
    },
];
