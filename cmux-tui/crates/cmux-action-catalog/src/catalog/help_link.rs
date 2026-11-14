// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `HelpLinkActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "HelpLinkActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "help.troubleshooting",
        group: GROUP,
        title: t("ActionCatalog", "action.help.troubleshooting", "Troubleshooting and Support"),
        keywords: &["help", "support", "problem", "bug", "contact", "email"],
        category: "settings",
        symbol: "lifepreserver",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action help-troubleshooting",
        main_menu: Some("help"),
        ..Action::DEFAULT
    },
    Action {
        id: "help.discord",
        group: GROUP,
        title: t("ActionCatalog", "action.help.discord", "Join the cmux Discord"),
        keywords: &["discord", "community", "chat", "server", "support", "slack"],
        category: "settings",
        symbol: "bubble.left.and.bubble.right",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action help-discord",
        main_menu: Some("help"),
        ..Action::DEFAULT
    },
    Action {
        id: "help.followOnX",
        group: GROUP,
        title: t("ActionCatalog", "action.help.followOnX", "Follow @cmux on X"),
        keywords: &["x", "twitter", "follow", "news", "updates", "social"],
        category: "settings",
        symbol: "at",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action help-follow-on-x",
        main_menu: Some("help"),
        ..Action::DEFAULT
    },
    Action {
        id: "help.github",
        group: GROUP,
        title: t("ActionCatalog", "action.help.github", "cmux on GitHub"),
        keywords: &["github", "source", "code", "repository", "issues", "star"],
        category: "settings",
        symbol: "chevron.left.forwardslash.chevron.right",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action help-github",
        main_menu: Some("help"),
        ..Action::DEFAULT
    },
    Action {
        id: "help.revealLogs",
        group: GROUP,
        title: t("ActionCatalog", "action.help.revealLogs", "Reveal Logs in Finder"),
        keywords: &["logs", "errors", "diagnostics", "finder", "folder", "debug"],
        category: "settings",
        symbol: "folder",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action help-reveal-logs",
        main_menu: Some("help"),
        ..Action::DEFAULT
    },
    Action {
        id: "help.copyLogs",
        group: GROUP,
        title: t("ActionCatalog", "action.help.copyLogs", "Copy Logs"),
        keywords: &["logs", "errors", "diagnostics", "copy", "clipboard", "bug report", "support"],
        category: "settings",
        symbol: "doc.on.clipboard",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action help-copy-logs",
        main_menu: Some("help"),
        ..Action::DEFAULT
    },
];
