// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ViewerActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "ViewerActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "openDiffViewer",
        group: GROUP,
        title: t("ActionCatalog", "action.openDiffViewer", "Open Diff Viewer"),
        keywords: &["git", "diff", "changes"],
        default_shortcut: Some(Shortcut { key: "g", modifiers: CTRL | SHIFT | CMD }),
        category: "browser",
        symbol: "plusminus",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[args::PATH.optional()],
        targets: &["pane"],
        cli_name: "browser open-diff-viewer",
        main_menu: Some("file"),
        ..Action::DEFAULT
    },
    Action {
        id: "palette.openDirectoryDiffViewer",
        group: GROUP,
        title: t("ActionCatalog", "action.palette.openDirectoryDiffViewer", "Open Diff Viewer in Folder…"),
        keywords: &["git", "diff", "changes", "folder", "directory"],
        category: "browser",
        symbol: "plus.forwardslash.minus",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        targets: &["pane"],
        cli_name: "browser open-directory-diff-viewer",
        main_menu: Some("file"),
        ..Action::DEFAULT
    },
    Action {
        id: "openMarkdownFile",
        group: GROUP,
        title: t("ActionCatalog", "action.openMarkdownFile", "Open Markdown File…"),
        keywords: &["markdown", "md", "preview", "viewer", "file"],
        category: "browser",
        symbol: "doc.richtext",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[args::PATH.optional()],
        targets: &["pane"],
        cli_name: "browser open-markdown-file",
        main_menu: Some("file"),
        ..Action::DEFAULT
    },
    Action {
        id: "screenshots.open",
        group: GROUP,
        title: t("ActionCatalog", "action.screenshots.open", "Screenshots"),
        keywords: &["screenshots", "screen shot", "screen recording", "capture", "images", "videos", "cleanshot", "shottr", "drag"],
        category: "browser",
        symbol: "photo.on.rectangle",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "screenshots open",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
];
