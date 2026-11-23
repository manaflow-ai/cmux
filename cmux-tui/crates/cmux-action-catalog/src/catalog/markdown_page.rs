// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `MarkdownPageActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "MarkdownPageActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "markdownSave",
        group: GROUP,
        title: t("ActionCatalog", "action.markdownSave", "Markdown: Save"),
        keywords: &["markdown", "save", "file"],
        default_shortcut: Some(Shortcut { key: "s", modifiers: CMD }),
        category: "browser",
        symbol: "square.and.arrow.down",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["markdownFocused"],
        targets: &["pane"],
        cli_name: "browser markdown-save",
        ..Action::DEFAULT
    },
    Action {
        id: "markdownLink",
        group: GROUP,
        title: t("ActionCatalog", "action.markdownLink", "Markdown: Insert Link"),
        keywords: &["markdown", "link", "url"],
        default_shortcut: Some(Shortcut { key: "k", modifiers: SHIFT | CMD }),
        category: "browser",
        symbol: "link",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["markdownFocused"],
        targets: &["pane"],
        cli_name: "browser markdown-link",
        ..Action::DEFAULT
    },
    Action {
        id: "markdownBack",
        group: GROUP,
        title: t("ActionCatalog", "action.markdownBack", "Markdown: Back"),
        keywords: &["markdown", "back", "history"],
        default_shortcut: Some(Shortcut { key: "[", modifiers: CMD }),
        category: "browser",
        symbol: "chevron.backward",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["markdownFocused"],
        targets: &["pane"],
        cli_name: "browser markdown-back",
        ..Action::DEFAULT
    },
    Action {
        id: "markdownForward",
        group: GROUP,
        title: t("ActionCatalog", "action.markdownForward", "Markdown: Forward"),
        keywords: &["markdown", "forward", "history"],
        default_shortcut: Some(Shortcut { key: "]", modifiers: CMD }),
        category: "browser",
        symbol: "chevron.forward",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["markdownFocused"],
        targets: &["pane"],
        cli_name: "browser markdown-forward",
        ..Action::DEFAULT
    },
    Action {
        id: "markdownReload",
        group: GROUP,
        title: t("ActionCatalog", "action.markdownReload", "Markdown: Reload"),
        keywords: &["markdown", "reload", "refresh", "disk"],
        default_shortcut: Some(Shortcut { key: "r", modifiers: CMD }),
        category: "browser",
        symbol: "arrow.clockwise",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["markdownFocused"],
        targets: &["pane"],
        cli_name: "browser markdown-reload",
        ..Action::DEFAULT
    },
    Action {
        id: "markdownResetTableWidths",
        group: GROUP,
        title: t("ActionCatalog", "action.markdownResetTableWidths", "Markdown: Reset Table Column Widths"),
        keywords: &["markdown", "table", "column", "width", "reset", "resize"],
        category: "browser",
        symbol: "tablecells",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["markdownFocused"],
        targets: &["pane"],
        cli_name: "browser markdown-reset-table-widths",
        ..Action::DEFAULT
    },
    Action {
        id: "markdownGoToTop",
        group: GROUP,
        title: t("ActionCatalog", "action.markdownGoToTop", "Markdown: Go to Top"),
        keywords: &["markdown", "vim", "top", "start"],
        category: "browser",
        symbol: "arrow.up.to.line.alt",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["markdownReadOnlyFocused"],
        targets: &["pane"],
        cli_name: "browser markdown-go-to-top",
        ..Action::DEFAULT
    },
];
