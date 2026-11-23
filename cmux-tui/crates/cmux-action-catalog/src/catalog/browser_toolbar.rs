// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `BrowserToolbarActionCatalog` actions.

use super::args;
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
        id: "browser.download.open",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.download.open", "Open Download"),
        keywords: &["browser", "download", "downloads", "open", "file", "launch"],
        category: "browser",
        symbol: "arrow.up.forward.app",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        arguments: &[args::DOWNLOAD],
        targets: &["pane"],
        cli_name: "action browser-download-open",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.download.reveal",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.download.reveal", "Show Download in Finder"),
        keywords: &["browser", "download", "downloads", "show in finder", "reveal", "finder", "folder", "file"],
        category: "browser",
        symbol: "folder",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        arguments: &[args::DOWNLOAD],
        targets: &["pane"],
        cli_name: "action browser-download-reveal",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.download.togglePause",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.download.togglePause", "Pause or Resume Download"),
        keywords: &["browser", "download", "downloads", "pause", "resume", "continue", "stop"],
        category: "browser",
        symbol: "pause.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        arguments: &[args::DOWNLOAD],
        targets: &["pane"],
        cli_name: "action browser-download-toggle-pause",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.download.retry",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.download.retry", "Retry Download"),
        keywords: &["browser", "download", "downloads", "retry", "again", "failed", "restart"],
        category: "browser",
        symbol: "arrow.clockwise",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        arguments: &[args::DOWNLOAD],
        targets: &["pane"],
        cli_name: "action browser-download-retry",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.download.cancel",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.download.cancel", "Cancel Download"),
        keywords: &["browser", "download", "downloads", "cancel", "stop", "abort"],
        category: "browser",
        symbol: "xmark.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        arguments: &[args::DOWNLOAD, args::CONFIRM.optional()],
        targets: &["pane"],
        cli_name: "action browser-download-cancel",
        is_destructive: true,
        ..Action::DEFAULT
    },
    Action {
        id: "browser.download.copyLink",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.download.copyLink", "Copy Download Link"),
        keywords: &["browser", "download", "downloads", "copy", "link", "url", "address"],
        category: "browser",
        symbol: "link",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        arguments: &[args::DOWNLOAD],
        targets: &["pane"],
        cli_name: "action browser-download-copy-link",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.toolbar.togglePin",
        group: GROUP,
        title: t("BrowserToolbarActions", "action.browser.toolbar.togglePin", "Pin or Unpin Browser Toolbar Button…"),
        keywords: &["browser", "toolbar", "button", "pin", "unpin", "show in toolbar", "hide", "more"],
        category: "browser",
        symbol: "pin",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        arguments: &[args::BROWSER_TOOLBAR_BUTTON],
        cli_name: "action browser-toolbar-toggle-pin",
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
