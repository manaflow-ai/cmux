// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `PaletteKeyActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "PaletteKeyActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "paletteKey.firstItem",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.firstItem", "Palette: First Item"),
        keywords: &["palette"],
        category: "window",
        symbol: "arrow.up.to.line",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-first-item",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.lastItem",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.lastItem", "Palette: Last Item"),
        keywords: &["palette"],
        category: "window",
        symbol: "arrow.down.to.line",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-last-item",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.pageUp",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.pageUp", "Palette: Page Up"),
        keywords: &["palette"],
        category: "window",
        symbol: "chevron.up.2",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-page-up",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.pageDown",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.pageDown", "Palette: Page Down"),
        keywords: &["palette"],
        category: "window",
        symbol: "chevron.down.2",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-page-down",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.submit",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.submit", "Palette: Run Item"),
        keywords: &["palette"],
        category: "window",
        symbol: "return",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-submit",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.submitAlternate",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.submitAlternate", "Palette: Run Item's Other Command"),
        keywords: &["palette"],
        category: "window",
        symbol: "return",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-submit-alternate",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.openActions",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.openActions", "Palette: Show Actions"),
        keywords: &["palette"],
        category: "window",
        symbol: "list.bullet",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-open-actions",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.closeActions",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.closeActions", "Palette: Hide Actions"),
        keywords: &["palette"],
        category: "window",
        symbol: "list.bullet",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-close-actions",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.toggleActions",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.toggleActions", "Palette: Show/Hide Actions"),
        keywords: &["palette"],
        category: "window",
        symbol: "list.bullet",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-toggle-actions",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.escape",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.escape", "Palette: Clear or Close"),
        keywords: &["palette"],
        category: "window",
        symbol: "escape",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-escape",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.enterRow",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.enterRow", "Palette: Open Item"),
        keywords: &["palette"],
        category: "window",
        symbol: "chevron.right",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-enter-row",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.leaveLevel",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.leaveLevel", "Palette: Up One Level"),
        keywords: &["palette"],
        category: "window",
        symbol: "chevron.left",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-leave-level",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.back",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.back", "Palette: Back"),
        keywords: &["palette"],
        category: "window",
        symbol: "chevron.backward",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-back",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.filterDeleteBackward",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.filterDeleteBackward", "Palette: Delete Filter Character"),
        keywords: &["palette"],
        category: "window",
        symbol: "delete.left",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-filter-delete-backward",
        ..Action::DEFAULT
    },
    Action {
        id: "paletteKey.closeItem",
        group: GROUP,
        title: t("ActionCatalog", "action.paletteKey.closeItem", "Palette: Close Item's Object"),
        keywords: &["palette"],
        category: "window",
        symbol: "xmark",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("paletteInternal"), ..SurfacePlan::DEFAULT },
        requires: &["paletteOpen"],
        cli_name: "action palette-key-close-item",
        ..Action::DEFAULT
    },
];
