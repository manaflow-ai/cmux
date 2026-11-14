// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `PageInfoActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "PageInfoActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "browser.pageInfo",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo", "View Site Information"),
        keywords: &["site", "information", "security", "certificate", "permissions", "cookies", "lock"],
        default_shortcut: Some(Shortcut { key: "i", modifiers: CTRL | CMD }),
        category: "browser",
        symbol: "slider.horizontal.3",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("browserPage", "inspect", 200).style("submenu").folder("tools"), Placement::at("browserPage", "inspect", 0).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser page-info",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.connection",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.connection", "Show Connection Details"),
        keywords: &["site", "security", "https", "connection", "secure"],
        category: "browser",
        symbol: "lock",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("browserPage", "inspect", 1).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser page-info-connection",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.certificate",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.certificate", "Show Certificate"),
        keywords: &["site", "certificate", "tls", "ssl", "fingerprint"],
        category: "browser",
        symbol: "checkmark.seal",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("browserPage", "inspect", 2).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser page-info-certificate",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.reenableCertificateWarnings",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.reenableCertificateWarnings", "Turn On Certificate Warnings Again"),
        keywords: &["site", "certificate", "security", "warning", "interstitial", "tls", "ssl", "re-enable", "revoke"],
        category: "browser",
        symbol: "exclamationmark.shield",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("browserPage", "inspect", 3).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser reenable-certificate-warnings",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.cookies",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.cookies", "Show Cookies and Site Data"),
        keywords: &["site", "cookies", "storage", "data"],
        category: "browser",
        symbol: "cylinder.split.1x2",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("browserPage", "inspect", 200).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser page-info-cookies",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.manageSiteData",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.manageSiteData", "Manage On-Device Site Data"),
        keywords: &["site", "cookies", "storage", "data", "delete"],
        category: "browser",
        symbol: "tray.full",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("browserPage", "inspect", 201).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser manage-site-data",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.deleteSiteData",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.deleteSiteData", "Delete Site Data"),
        keywords: &["site", "cookies", "storage", "clear", "delete"],
        category: "browser",
        symbol: "trash",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("browserPage", "inspect", 202).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        arguments: &[args::DOMAIN_2.optional(), args::CONFIRM.optional()],
        targets: &["pane"],
        cli_name: "browser delete-site-data",
        is_destructive: true,
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.setPermission",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.setPermission", "Set Site Permission…"),
        keywords: &["site", "permission", "camera", "microphone", "location", "notifications", "javascript", "allow", "block"],
        category: "browser",
        symbol: "hand.raised",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("browserPage", "inspect", 100).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        arguments: &[args::PERMISSION, args::SETTING_2],
        targets: &["pane"],
        cli_name: "browser set-site-permission",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.resetPermissions",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.resetPermissions", "Reset Site Permissions"),
        keywords: &["site", "permission", "reset"],
        category: "browser",
        symbol: "arrow.counterclockwise",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("browserPage", "inspect", 101).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser reset-site-permissions",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.siteSettings",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.siteSettings", "Site Settings"),
        keywords: &["site", "settings", "permissions"],
        category: "browser",
        symbol: "gearshape",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("browserPage", "inspect", 300).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser site-settings",
        ..Action::DEFAULT
    },
    Action {
        id: "browser.pageInfo.aboutThisPage",
        group: GROUP,
        title: t("PageInfoActions", "action.pageInfo.aboutThisPage", "About This Page"),
        keywords: &["site", "about", "source"],
        category: "browser",
        symbol: "doc.text.magnifyingglass",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("browserPage", "inspect", 301).parent("browser.pageInfo")], ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "browser about-this-page",
        ..Action::DEFAULT
    },
];
