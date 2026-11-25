// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `BrowserToolbarActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "BrowserToolbarActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "browser.media.show",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.media.show", "Show Media Controls…"),
        keywords: &["browser", "media", "music", "video", "now playing", "play", "pause", "toolbar"],
        category: "browser",
        symbol: "music.note",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser media",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.downloads.show",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.downloads.show", "Show Downloads…"),
        keywords: &["browser", "downloads", "files", "progress", "toolbar"],
        category: "browser",
        symbol: "arrow.down.circle",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser downloads",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.profile.choose",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.profile.choose", "Choose Browser Profile…"),
        keywords: &["browser", "profile", "person", "account", "switch", "toolbar"],
        category: "browser",
        symbol: "person.crop.circle",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser choose-profile",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.overflow.menu",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.overflow.menu", "More Browser Actions…"),
        keywords: &["browser", "more", "overflow", "menu", "toolbar", "ellipsis"],
        category: "browser",
        symbol: "ellipsis",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser more-actions",
        ..Action::DEFAULT
    },
];
