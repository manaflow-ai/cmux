// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `FilePageActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "FilePageActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "fileEditorGotoLine",
        group: GROUP,
        title: t("ActionCatalog", "action.fileEditorGotoLine", "Editor: Go to Line…"),
        keywords: &["editor", "line", "jump"],
        default_shortcut: Some(Shortcut { key: "g", modifiers: CTRL }),
        category: "browser",
        symbol: "arrow.right.to.line",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["codeEditorFocused"],
        targets: &["pane"],
        cli_name: "browser editor-go-to-line",
        ..Action::DEFAULT
    },
    Action {
        id: "fileEditorReplace",
        group: GROUP,
        title: t("ActionCatalog", "action.fileEditorReplace", "Editor: Replace…"),
        keywords: &["editor", "find", "replace"],
        category: "browser",
        symbol: "arrow.left.arrow.right",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["codeEditorFocused"],
        targets: &["pane"],
        cli_name: "browser editor-replace",
        ..Action::DEFAULT
    },
    Action {
        id: "fileEditorZoomIn",
        group: GROUP,
        title: t("ActionCatalog", "action.fileEditorZoomIn", "Editor: Zoom In"),
        keywords: &["editor", "zoom", "font"],
        default_shortcut: Some(Shortcut { key: "=", modifiers: CMD }),
        category: "browser",
        symbol: "plus.magnifyingglass",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("stepAdjust")), context_menu_exemption: Some("stepAdjust"), ..SurfacePlan::DEFAULT },
        requires: &["codeEditorFocused"],
        targets: &["pane"],
        cli_name: "browser editor-zoom-in",
        ..Action::DEFAULT
    },
    Action {
        id: "fileEditorZoomOut",
        group: GROUP,
        title: t("ActionCatalog", "action.fileEditorZoomOut", "Editor: Zoom Out"),
        keywords: &["editor", "zoom", "font"],
        default_shortcut: Some(Shortcut { key: "-", modifiers: CMD }),
        category: "browser",
        symbol: "minus.magnifyingglass",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("stepAdjust")), context_menu_exemption: Some("stepAdjust"), ..SurfacePlan::DEFAULT },
        requires: &["codeEditorFocused"],
        targets: &["pane"],
        cli_name: "browser editor-zoom-out",
        ..Action::DEFAULT
    },
    Action {
        id: "fileEditorZoomReset",
        group: GROUP,
        title: t("ActionCatalog", "action.fileEditorZoomReset", "Editor: Actual Size"),
        keywords: &["editor", "zoom", "reset"],
        default_shortcut: Some(Shortcut { key: "0", modifiers: CMD }),
        category: "browser",
        symbol: "1.magnifyingglass",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("stepAdjust")), context_menu_exemption: Some("stepAdjust"), ..SurfacePlan::DEFAULT },
        requires: &["codeEditorFocused"],
        targets: &["pane"],
        cli_name: "browser editor-actual-size",
        ..Action::DEFAULT
    },
    Action {
        id: "fileEditorAction",
        group: GROUP,
        title: t("ActionCatalog", "action.fileEditorAction", "Editor: Run Editor Action"),
        keywords: &["editor", "monaco", "command"],
        category: "browser",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["codeEditorFocused"],
        arguments: &[args::TEXT],
        targets: &["pane"],
        cli_name: "browser editor-action",
        ..Action::DEFAULT
    },
    Action {
        id: "fileEditor.importEditorSettings",
        group: GROUP,
        title: t("ActionCatalog", "action.fileEditor.importEditorSettings", "Copy Settings from VS Code or Zed"),
        keywords: &["editor", "import", "vscode", "zed", "cursor", "windsurf", "vscodium", "settings", "monaco"],
        category: "settings",
        symbol: "square.and.arrow.down",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "settings import-editor-settings",
        ..Action::DEFAULT
    },
    Action {
        id: "file.openRecoveredDraft",
        group: GROUP,
        title: t("ActionCatalog", "action.file.openRecoveredDraft", "Open Recovered Draft…"),
        keywords: &["file", "editor", "recover", "recovered", "draft", "unsaved", "crash", "restore"],
        category: "pane",
        symbol: "doc.badge.clock",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "file open-recovered-draft",
        ..Action::DEFAULT
    },
];
